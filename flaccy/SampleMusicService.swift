import Foundation

/// Downloads the CC0 sample album from the flaccy-api Worker into Documents,
/// where the normal library sync picks it up like any imported FLAC. Nothing
/// is bundled in the binary; the samples are fully deletable afterwards.
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

    private init() {}

    func downloadSamples() async -> Bool {
        guard !isDownloading else { return false }
        isDownloading = true
        defer {
            isDownloading = false
            postProgress("")
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: Self.baseURL)
            let manifest = try JSONDecoder().decode(Manifest.self, from: data)
            attribution = manifest.attribution
            let documents = LibraryPaths.root
            UserDefaults.standard.set(manifest.tracks.map(\.file), forKey: Self.fileNamesKey)

            for (index, track) in manifest.tracks.enumerated() {
                let destination = documents.appendingPathComponent(track.file)
                guard !FileManager.default.fileExists(atPath: destination.path) else { continue }
                postProgress(String(localized: "Downloading \(index + 1) of \(manifest.tracks.count)…"))
                let url = Self.baseURL.appendingPathComponent(track.file)
                let (temp, response) = try await URLSession.shared.download(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw URLError(.badServerResponse)
                }
                try FileManager.default.moveItem(at: temp, to: destination)
                AppLogger.info("Sample downloaded: \(track.file)", category: .content)
            }
            postProgress(String(localized: "Adding to library…"))
            await Library.shared.reload()
            AppLogger.info("Sample music installed (\(manifest.tracks.count) tracks)", category: .content)
            return true
        } catch {
            AppLogger.error("Sample download failed: \(error.localizedDescription)", category: .content)
            return false
        }
    }

    private func postProgress(_ text: String) {
        progressText = text
        NotificationCenter.default.post(name: Self.progressDidChange, object: nil)
    }
}
