import Foundation

/// Downloads the CC0 sample album from the flaccy-api Worker into Documents,
/// where the normal library sync picks it up like any imported FLAC. Nothing
/// is bundled in the binary; the samples are fully deletable afterwards.
///
/// The album starts playing the moment its first file lands and the rest join
/// the queue as they arrive, because the whole point of the sample is to be
/// heard: a person who tapped it and then waited for 135 MB, read a toast and
/// still had to find the album and press play mostly never pressed play.
final class SampleMusicService {

    static let shared = SampleMusicService()

    static let progressDidChange = Notification.Name("SampleMusicProgressDidChange")

    private(set) var isDownloading = false
    private(set) var progressText = ""
    private(set) var attribution: String?

    private static let baseURL = URL(string: "https://flaccy-api.midgarcorp.cc/v1/samples")!
    private static let fileNamesKey = "flaccy.samples.fileNames"

    /// The sample album's files, remembered as they are downloaded so the trial
    /// and the funnel can tell the free album from the person's own music.
    static var sampleFileNames: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: fileNamesKey) ?? [])
    }

    static func isSample(_ url: URL, among names: Set<String> = sampleFileNames) -> Bool {
        guard names.contains(url.lastPathComponent) else { return false }
        return url.deletingLastPathComponent().standardizedFileURL.path == LibraryPaths.root.standardizedFileURL.path
    }

    private struct Manifest: Decodable {
        struct SampleTrack: Decodable {
            let file: String
            let title: String
            let artist: String
            let album: String
        }
        let attribution: String
        let tracks: [SampleTrack]
    }

    private struct PlannedFile {
        let name: String
        let url: URL
        let destination: URL
        let bytes: Int64
    }

    private init() {}

    func downloadSamples() async -> Bool {
        guard !isDownloading else { return false }
        isDownloading = true
        PurchaseFunnel.noteSampleDownload(.started)
        defer {
            isDownloading = false
            postProgress("")
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: Self.baseURL)
            let manifest = try JSONDecoder().decode(Manifest.self, from: data)
            attribution = manifest.attribution
            let albumOrder = manifest.tracks.map(\.file)
            UserDefaults.standard.set(albumOrder, forKey: Self.fileNamesKey)

            let files = await plannedFiles(albumOrder)
            let totalBytes = max(files.reduce(0) { $0 + $1.bytes }, 1)
            var landedBytes: Int64 = 0
            var startedPlayback = false
            for file in files {
                if !FileManager.default.fileExists(atPath: file.destination.path) {
                    let baseline = landedBytes
                    try await download(file) { [weak self] received in
                        self?.postDownloadProgress(Double(baseline + received) / Double(totalBytes))
                    }
                    AppLogger.info("Sample downloaded: \(file.name)", category: .content)
                }
                landedBytes += file.bytes
                postDownloadProgress(Double(landedBytes) / Double(totalBytes))
                await Library.shared.reload()
                if startedPlayback {
                    appendArrivalsToQueue(albumOrder: albumOrder)
                } else {
                    startedPlayback = playSampleAlbum(albumOrder: albumOrder)
                }
            }
            AppLogger.info("Sample music installed (\(manifest.tracks.count) tracks)", category: .content)
            PurchaseFunnel.noteSampleDownload(.finished)
            return true
        } catch {
            AppLogger.error("Sample download failed: \(error.localizedDescription)", category: .content)
            PurchaseFunnel.noteSampleDownload(.failed)
            return false
        }
    }

    /// Smallest file first, so the first sound arrives after about 20 MB
    /// rather than the Aria's 80. The Worker answers HEAD without a length and
    /// ignores Range, so each size is read off a GET's headers and the body is
    /// abandoned unread; a file whose size cannot be read goes last.
    private func plannedFiles(_ names: [String]) async -> [PlannedFile] {
        var planned: [PlannedFile] = []
        for name in names {
            let url = Self.baseURL.appendingPathComponent(name)
            planned.append(PlannedFile(
                name: name,
                url: url,
                destination: LibraryPaths.root.appendingPathComponent(name),
                bytes: await Self.contentLength(of: url)
            ))
        }
        let known = planned.filter { $0.bytes > 0 }.sorted { $0.bytes < $1.bytes }
        return known + planned.filter { $0.bytes <= 0 }
    }

    private static func contentLength(of url: URL) async -> Int64 {
        guard let (bytes, response) = try? await URLSession.shared.bytes(from: url) else { return 0 }
        bytes.task.cancel()
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return 0 }
        return max(response.expectedContentLength, 0)
    }

    /// The async download API never calls the progress delegate methods, so
    /// the task is captured as it is created and its byte count read on a
    /// short timer instead.
    private func download(_ file: PlannedFile, received: @escaping (Int64) -> Void) async throws {
        let capture = DownloadTaskCapture()
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                if let task = capture.task {
                    received(task.countOfBytesReceived)
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { ticker.cancel() }
        let (temp, response) = try await URLSession.shared.download(from: file.url, delegate: capture)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        try FileManager.default.moveItem(at: temp, to: file.destination)
    }

    private func sampleTracks(albumOrder: [String]) -> [Track] {
        let names = Set(albumOrder)
        return Library.shared.allTracks
            .filter { Self.isSample($0.fileURL, among: names) }
            .sorted {
                (albumOrder.firstIndex(of: $0.fileURL.lastPathComponent) ?? .max)
                    < (albumOrder.firstIndex(of: $1.fileURL.lastPathComponent) ?? .max)
            }
    }

    /// Plays whatever of the album has landed. A person already listening to
    /// something else is left alone; the album still lands in the library.
    private func playSampleAlbum(albumOrder: [String]) -> Bool {
        let tracks = sampleTracks(albumOrder: albumOrder)
        guard !tracks.isEmpty else { return false }
        guard !AudioPlayer.shared.isPlaying else { return true }
        AppLogger.info("Sample: playing with \(tracks.count) of \(albumOrder.count) tracks landed", category: .content)
        AudioPlayer.shared.play(tracks, startingAt: 0)
        if AudioPlayer.shared.currentTrack != nil {
            PurchaseFunnel.noteSampleDownload(.playing)
        }
        return true
    }

    /// Adds newly arrived files only while the queue is still the sample album
    /// this service started, so a person who has since picked their own music
    /// never finds Bach appended to it.
    private func appendArrivalsToQueue(albumOrder: [String]) {
        let queue = AudioPlayer.shared.queue
        let names = Set(albumOrder)
        guard !queue.isEmpty, queue.allSatisfy({ Self.isSample($0.fileURL, among: names) }) else { return }
        let queued = Set(queue.map(\.fileURL.standardizedFileURL))
        for track in sampleTracks(albumOrder: albumOrder) where !queued.contains(track.fileURL.standardizedFileURL) {
            AudioPlayer.shared.addToQueue(track)
        }
    }

    private func postDownloadProgress(_ fraction: Double) {
        let percent = min(max(fraction, 0), 1).formatted(.percent.precision(.fractionLength(0)))
        postProgress(String(localized: "Downloading sample album… \(percent)"))
    }

    private func postProgress(_ text: String) {
        progressText = text
        NotificationCenter.default.post(name: Self.progressDidChange, object: nil)
    }
}

private nonisolated final class DownloadTaskCapture: NSObject, URLSessionTaskDelegate, @unchecked Sendable {

    private let lock = NSLock()
    private var captured: URLSessionTask?

    var task: URLSessionTask? {
        lock.withLock { captured }
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        lock.withLock { captured = task }
    }
}
