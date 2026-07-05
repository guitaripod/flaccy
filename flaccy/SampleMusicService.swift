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
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

            for (index, track) in manifest.tracks.enumerated() {
                let destination = documents.appendingPathComponent(track.file)
                guard !FileManager.default.fileExists(atPath: destination.path) else { continue }
                postProgress("Downloading \(index + 1) of \(manifest.tracks.count)…")
                let url = Self.baseURL.appendingPathComponent(track.file)
                let (temp, response) = try await URLSession.shared.download(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw URLError(.badServerResponse)
                }
                try FileManager.default.moveItem(at: temp, to: destination)
                AppLogger.info("Sample downloaded: \(track.file)", category: .content)
            }
            postProgress("Adding to library…")
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
