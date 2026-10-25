import AVFoundation
import FlaccyCore
import Foundation

/// Answers AVFoundation's requests for the bytes of a song on a server.
///
/// An asset whose URL has the `flaccy-remote` scheme asks this delegate for everything it
/// reads. The delegate describes the file from the library row, then hands out bytes from the
/// cache file as they arrive, asking the cache to fetch what is missing. A request AVFoundation
/// cancels stops only the fetch nobody else needs.
nonisolated final class RemoteResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {

    static let shared = RemoteResourceLoader()

    private static let chunkBytes = 256 * 1_024

    private let queue = DispatchQueue(label: "cc.midgarcorp.flaccy.remote-loader", qos: .userInitiated)
    private let lock = NSLock()
    private var running: [ObjectIdentifier: Task<Void, Never>] = [:]
    private let cache: RemoteStreamCache

    init(cache: RemoteStreamCache = .shared) {
        self.cache = cache
    }

    /// An asset for a song on a server that reads through this loader.
    func makeAsset(for song: RemoteTrackPath) -> AVURLAsset {
        let asset = AVURLAsset(url: song.assetURL)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard let url = loadingRequest.request.url, let song = RemoteTrackPath(assetURL: url) else { return false }
        let box = LoadingRequestBox(loadingRequest)
        let key = ObjectIdentifier(loadingRequest)
        let task = Task { [weak self] in
            await self?.serve(box, song: song)
            self?.forget(key)
        }
        lock.withLock { running[key] = task }
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        let task = lock.withLock { running.removeValue(forKey: ObjectIdentifier(loadingRequest)) }
        task?.cancel()
    }

    private func forget(_ key: ObjectIdentifier) {
        lock.withLock { running[key] = nil }
    }

    private func serve(_ box: LoadingRequestBox, song: RemoteTrackPath) async {
        let request = box.request
        do {
            if let information = request.contentInformationRequest {
                information.contentType = RemoteAudioType.identifier(forSuffix: cache.suffix(of: song))
                information.contentLength = try await cache.totalBytes(of: song)
                information.isByteRangeAccessSupported = true
            }
            if let dataRequest = request.dataRequest {
                try await deliver(dataRequest, song: song)
            }
            request.finishLoading()
        } catch is CancellationError {
            return
        } catch {
            RemoteLog.error("Loading \(song.path) failed: \(error.localizedDescription)")
            request.finishLoading(with: error)
        }
    }

    private func deliver(_ dataRequest: AVAssetResourceLoadingDataRequest, song: RemoteTrackPath) async throws {
        let total = try await cache.totalBytes(of: song)
        var offset = dataRequest.requestedOffset
        let end = dataRequest.requestsAllDataToEndOfResource
            ? total
            : min(total, dataRequest.requestedOffset + Int64(dataRequest.requestedLength))
        guard offset < end else { return }
        let demand = try await cache.beginDemand(song, range: offset..<end)
        do {
            while offset < end {
                let data = try await cache.read(song, from: offset, upTo: end, maxLength: Self.chunkBytes)
                dataRequest.respond(with: data)
                offset += Int64(data.count)
            }
        } catch {
            await cache.endDemand(song, demand)
            throw error
        }
        await cache.endDemand(song, demand)
    }
}

/// Carries a loading request into the task that serves it. AVFoundation allows the request to
/// be answered from any queue, and nothing else touches it while the task runs.
nonisolated private struct LoadingRequestBox: @unchecked Sendable {
    let request: AVAssetResourceLoadingRequest

    init(_ request: AVAssetResourceLoadingRequest) {
        self.request = request
    }
}
