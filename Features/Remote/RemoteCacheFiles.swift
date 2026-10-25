import FlaccyCore
import FlaccyEngine
import Foundation
import UniformTypeIdentifiers

/// What the cache remembers about one song's file beside the file itself: which bytes are
/// there, how long the whole file is, the validator the server gave it, and when it was last used.
nonisolated struct RemoteCacheSidecar: Codable, Equatable, Sendable {
    var file: String
    var total: Int64?
    var validator: String?
    var ranges: ByteRangeSet
    var lastUsed: Double

    init(file: String, total: Int64?, validator: String? = nil, ranges: ByteRangeSet = ByteRangeSet(), lastUsed: Date) {
        self.file = file
        self.total = total
        self.validator = validator
        self.ranges = ranges
        self.lastUsed = lastUsed.timeIntervalSince1970
    }

    var lastUsedDate: Date {
        get { Date(timeIntervalSince1970: lastUsed) }
        set { lastUsed = newValue.timeIntervalSince1970 }
    }

    var isComplete: Bool {
        guard let total else { return false }
        return ranges.isComplete(fileSize: total)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> RemoteCacheSidecar {
        try JSONDecoder().decode(RemoteCacheSidecar.self, from: data)
    }
}

/// Where a remote song's bytes live: `Library/Caches/Remote/<server>/<song>.<suffix>` while the
/// system may reclaim them, `Application Support/Remote/<server>/` once the person keeps them.
nonisolated enum RemoteCacheLayout {

    static let sidecarSuffix = ".ranges.json"

    static func cachesRoot(base: URL? = nil) -> URL {
        (base ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0])
            .appendingPathComponent("Remote", isDirectory: true)
    }

    static func pinnedRoot(base: URL? = nil) -> URL {
        (base ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
            .appendingPathComponent("Remote", isDirectory: true)
    }

    static func directory(in root: URL, song: RemoteTrackPath) -> URL {
        root.appendingPathComponent(song.escapedServerID, isDirectory: true)
    }

    static func audioFileName(for song: RemoteTrackPath, suffix: String?) -> String {
        let cleaned = (suffix ?? "").lowercased().filter { $0.isLetter || $0.isNumber }
        return song.escapedSongID + "." + (cleaned.isEmpty ? "audio" : cleaned)
    }

    static func sidecarFileName(for song: RemoteTrackPath) -> String {
        song.escapedSongID + sidecarSuffix
    }

    static func audioURL(in root: URL, song: RemoteTrackPath, suffix: String?) -> URL {
        directory(in: root, song: song).appendingPathComponent(audioFileName(for: song, suffix: suffix))
    }

    static func sidecarURL(in root: URL, song: RemoteTrackPath) -> URL {
        directory(in: root, song: song).appendingPathComponent(sidecarFileName(for: song))
    }

    /// The key eviction and protection name an entry by: `<server>/<song>`, both as written in the file names.
    static func key(for song: RemoteTrackPath) -> String {
        song.escapedServerID + "/" + song.escapedSongID
    }
}

/// The type AVFoundation is told a remote song's bytes are, from the suffix the server reports.
nonisolated enum RemoteAudioType {

    static func identifier(forSuffix suffix: String?) -> String {
        switch (suffix ?? "").lowercased() {
        case "flac": "org.xiph.flac"
        case "mp3": "public.mp3"
        case "m4a", "alac", "mp4": "com.apple.m4a-audio"
        case "aac": "public.aac-audio"
        case "wav", "wave": "com.microsoft.waveform-audio"
        case "aif", "aiff": "public.aiff-audio"
        case "caf": "com.apple.coreaudio-format"
        default: "public.audio"
        }
    }
}

/// How a song on a server reaches the player: from a complete file on disk, or through the resource loader.
nonisolated enum RemoteAssetRoute: Equatable, Sendable {
    case file(URL)
    case stream(URL)

    /// A song whose file is whole on disk plays from that file; every other song streams through its `flaccy-remote` URL.
    static func route(for song: RemoteTrackPath, completeFile: URL?) -> RemoteAssetRoute {
        if let completeFile { return .file(completeFile) }
        return .stream(song.assetURL)
    }
}

/// Facts about a remote song a screen or the player needs without waiting for the cache: its
/// suffix and size from the library row, remembered so a list of songs costs one query each.
nonisolated final class RemoteSongDirectory: @unchecked Sendable {

    static let shared = RemoteSongDirectory()

    private let lock = NSLock()
    private var sources: [String: RemoteSongSource] = [:]

    func source(for song: RemoteTrackPath) -> RemoteSongSource? {
        if let known = lock.withLock({ sources[song.path] }) { return known }
        guard let fetched = try? DatabaseManager.shared.fetchRemoteSongSource(path: song.path) else { return nil }
        lock.withLock { sources[song.path] = fetched }
        return fetched
    }

    func invalidate(paths: [String]) {
        lock.withLock { for path in paths { sources[path] = nil } }
    }

    func invalidateAll() {
        lock.withLock { sources.removeAll() }
    }
}

extension Track {

    /// The song this track is on a server, or nil for a file in the library folder.
    nonisolated var remoteSong: RemoteTrackPath? {
        RemoteTrackPath(assetURL: fileURL)
    }

    /// The extension of the track's audio: the server's suffix for a remote song, the file's own otherwise.
    nonisolated var audioExtension: String {
        guard let song = remoteSong else { return fileURL.pathExtension }
        return RemoteSongDirectory.shared.source(for: song)?.suffix ?? ""
    }
}
