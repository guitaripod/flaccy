import FlaccyCore
import Foundation

/// Answers `ImportPlan`'s two audio questions from the files themselves: the
/// audio fingerprint from `AudioFingerprinter`, and the song key from the title
/// and artist tags, normalized the way enrichment keys are. A file whose tags
/// do not say both has no song key, because a name guessed from the filename
/// would let two different songs pass for versions of each other.
nonisolated struct LibraryImportInspector: ImportInspector {

    func audioFingerprint(of url: URL) -> String? {
        AudioFingerprinter.fingerprint(of: url)
    }

    func songKey(of url: URL) -> String? {
        let tags = Self.tags(of: url)
        guard let title = Self.normalized(tags.title), let artist = Self.normalized(tags.artist) else { return nil }
        return title + "|" + artist
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let key = EnrichmentKey.normalize(value)
        return key.isEmpty ? nil : key
    }

    /// `ImportPlan` asks synchronously, from the import's own background task;
    /// the tag reader is asynchronous, so this waits for it on a separate task.
    private static func tags(of url: URL) -> (title: String?, artist: String?) {
        let result = TagResult()
        let finished = DispatchSemaphore(value: 0)
        Task.detached {
            let read = await AudioMetadataReader.read(from: url)
            result.store(title: read.title, artist: read.artist)
            finished.signal()
        }
        finished.wait()
        return result.value
    }

    private final class TagResult: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: (title: String?, artist: String?) = (nil, nil)

        var value: (title: String?, artist: String?) {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        func store(title: String?, artist: String?) {
            lock.lock()
            stored = (title, artist)
            lock.unlock()
        }
    }
}
