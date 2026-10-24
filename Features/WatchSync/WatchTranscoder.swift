import AVFoundation
import MidgarCore
import CryptoKit
import FlaccyCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Turns a lossless source file into a small AAC-LC `.m4a` for the watch.
///
/// The output keeps the tags and a small cover and carries the encoder's
/// priming and remainder frames so consecutive tracks still play gaplessly.
/// Encodes run strictly one at a time whatever the number of callers, at
/// utility priority, and results are cached by the identity of the source
/// plus the target bit rate so a retry costs nothing.
actor WatchTranscoder {

    struct Prepared: Sendable {
        let url: URL
        let bytes: Int64
        let wasEncoded: Bool
        let destinationExtension: String
    }

    enum TranscodeError: Error {
        case unreadable
        case noAudioTrack
        case writerFailed(String)
        case cancelled
    }

    private let cacheDirectory: URL
    private var isEncoding = false
    private var waiters: [Waiter] = []
    private var activeSession: EncodeSession?
    private var activeSource: String?
    private var activePartial: URL?

    init(cacheDirectory: URL) {
        self.cacheDirectory = cacheDirectory
    }

    func prepare(source: URL, profile: WatchAudioProfile) async throws -> Prepared {
        guard let bitRate = profile.bitRate,
              profile.requiresEncoding(for: SyncStem.kind(ofExtension: source.pathExtension))
        else { return try passthrough(source) }
        let destination = try cacheURL(for: source, bitRate: bitRate)
        if let hit = cachedResult(at: destination) { return hit }

        let inspection = try await Self.inspect(source)
        guard profile.requiresEncoding(for: inspection.kind),
              !Self.isAlreadyLean(source, inspection: inspection, profileRate: bitRate)
        else { return try passthrough(source) }

        try await acquireTurn(for: source)
        defer { releaseTurn() }
        try checkNotCancelled()
        if let hit = cachedResult(at: destination) { return hit }

        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try await encode(source: source, inspection: inspection, bitRate: bitRate, destination: destination)
        let encoded = try encodedResult(at: destination)
        if let sourceBytes = Self.fileSize(of: source), encoded.bytes >= sourceBytes {
            try? FileManager.default.removeItem(at: destination)
            MidgarLog.info("Watch transcode of \(source.lastPathComponent) was not smaller than the source; sending it as is", category: .connectivity)
            return try passthrough(source)
        }
        return encoded
    }

    func cancel(source: URL) {
        let target = Self.identity(of: source)
        let matching = waiters.filter { $0.source == target }
        waiters.removeAll { $0.source == target }
        matching.forEach { $0.continuation.resume(throwing: TranscodeError.cancelled) }
        if activeSource == target { activeSession?.cancel() }
    }

    func purgeStale(keeping: Set<URL>, olderThan age: TimeInterval) {
        let kept = Set(keeping.map { Self.identity(of: $0) })
        let manager = FileManager.default
        let files = (try? manager.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        let cutoff = Date().addingTimeInterval(-age)
        for file in files {
            let identity = Self.identity(of: file)
            if kept.contains(identity) || identity == activePartial.map(Self.identity(of:)) { continue }
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard let modified, modified < cutoff else { continue }
            try? manager.removeItem(at: file)
        }
    }

    func release(_ prepared: Prepared) {
        guard prepared.wasEncoded, Self.isInside(prepared.url, directory: cacheDirectory) else { return }
        try? FileManager.default.removeItem(at: prepared.url)
    }
}

extension WatchTranscoder {

    private struct Waiter {
        let id: UUID
        let source: String
        let continuation: CheckedContinuation<Void, Error>
    }

    /// Waits for the single encode slot; queued callers are served in order.
    private func acquireTurn(for source: URL) async throws {
        try checkNotCancelled()
        guard isEncoding else {
            isEncoding = true
            return
        }
        let id = UUID()
        let identity = Self.identity(of: source)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: TranscodeError.cancelled)
                    return
                }
                waiters.append(Waiter(id: id, source: identity, continuation: continuation))
            }
        } onCancel: {
            Task { await self.dropWaiter(id) }
        }
    }

    private func dropWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: TranscodeError.cancelled)
    }

    private func releaseTurn() {
        if waiters.isEmpty {
            isEncoding = false
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }

    private func checkNotCancelled() throws {
        if Task.isCancelled { throw TranscodeError.cancelled }
    }

    private func passthrough(_ source: URL) throws -> Prepared {
        guard let size = Self.fileSize(of: source) else { throw TranscodeError.unreadable }
        return Prepared(url: source, bytes: size, wasEncoded: false, destinationExtension: source.pathExtension)
    }

    private func encodedResult(at url: URL) throws -> Prepared {
        guard let size = Self.fileSize(of: url) else { throw TranscodeError.writerFailed("missing output") }
        return Prepared(url: url, bytes: size, wasEncoded: true, destinationExtension: SyncStem.encodedExtension)
    }

    /// A finished cache entry, marked as used now so age-based purging
    /// measures idleness rather than the time of the first encode.
    private func cachedResult(at url: URL) -> Prepared? {
        guard let size = Self.fileSize(of: url), size > 0 else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return Prepared(url: url, bytes: size, wasEncoded: true, destinationExtension: SyncStem.encodedExtension)
    }

    /// Source path, size, modification time and target rate decide the file name.
    private func cacheURL(for source: URL, bitRate: Int) throws -> URL {
        let attributes = try? FileManager.default.attributesOfItem(atPath: source.path)
        guard let size = attributes?[.size] as? NSNumber,
              let modified = attributes?[.modificationDate] as? Date
        else { throw TranscodeError.unreadable }
        let milliseconds = Int64((modified.timeIntervalSince1970 * 1000).rounded())
        let fingerprint = "v1|\(Self.identity(of: source))|\(size.int64Value)|\(milliseconds)|\(bitRate)"
        let digest = SHA256.hash(data: Data(fingerprint.utf8)).map { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent(digest).appendingPathExtension(SyncStem.encodedExtension)
    }

    nonisolated private static func identity(of url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    nonisolated private static func isInside(_ url: URL, directory: URL) -> Bool {
        identity(of: url).hasPrefix(identity(of: directory) + "/")
    }

    nonisolated private static func fileSize(of url: URL) -> Int64? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value
    }
}

extension WatchTranscoder {

    fileprivate struct Inspection: Sendable {
        let kind: AudioSourceKind
        let sampleRate: Int
        let channels: Int
        let duration: TimeInterval
    }

    /// Decides what the file really is. The extension settles the common
    /// containers, but an `.m4a` is lossy or lossless depending on the codec
    /// inside, so the track's format description has the last word.
    nonisolated fileprivate static func inspect(_ source: URL) async throws -> Inspection {
        guard fileSize(of: source) != nil else { throw TranscodeError.unreadable }
        let byExtension = SyncStem.kind(ofExtension: source.pathExtension)
        let asset = AVURLAsset(url: source)
        let tracks: [AVAssetTrack]
        let duration: TimeInterval
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
            duration = CMTimeGetSeconds(try await asset.load(.duration))
        } catch {
            throw TranscodeError.unreadable
        }
        guard let track = tracks.first else { throw TranscodeError.noAudioTrack }
        let descriptions = (try? await track.load(.formatDescriptions)) ?? []
        let description = descriptions.first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }

        let kind = resolvedKind(byExtension: byExtension, formatID: description?.mFormatID)
        let format = AudioMetadataReader.readFormat(from: source)
        let rate = format.sampleRate ?? Int(description?.mSampleRate ?? 0)
        let channels = format.channels ?? Int(description?.mChannelsPerFrame ?? 0)
        guard rate > 0, channels > 0 else { throw TranscodeError.unreadable }
        return Inspection(kind: kind, sampleRate: rate, channels: channels, duration: duration.isFinite ? duration : 0)
    }

    nonisolated private static func resolvedKind(byExtension: AudioSourceKind, formatID: AudioFormatID?) -> AudioSourceKind {
        guard let formatID else { return byExtension }
        switch formatID {
        case kAudioFormatAppleLossless, kAudioFormatFLAC, kAudioFormatLinearPCM:
            return .lossless
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2, kAudioFormatMPEG4AAC_LD,
             kAudioFormatMPEG4AAC_ELD, kAudioFormatMPEGLayer3, kAudioFormatMPEGLayer2, kAudioFormatMPEGLayer1,
             kAudioFormatOpus, kAudioFormatAC3, kAudioFormatEnhancedAC3:
            return .lossy
        default:
            return byExtension
        }
    }

    /// A source whose average bit rate is within 15 % of what the encoder
    /// would spend gains nothing from re-encoding, and below it the output
    /// would come out larger than the original.
    nonisolated fileprivate static func isAlreadyLean(_ source: URL, inspection: Inspection, profileRate: Int) -> Bool {
        guard inspection.duration > 0, let bytes = fileSize(of: source) else { return false }
        let target = encoderBitRate(profileRate: profileRate, channels: min(inspection.channels, 2))
        return Double(bytes) * 8 / inspection.duration <= 1.15 * Double(target)
    }

    /// Source rate when it is a native AAC rate, otherwise the member of the
    /// same family: 44.1 kHz multiples fold to 44 100, everything else to 48 000.
    nonisolated static func outputSampleRate(forSource rate: Int) -> Int {
        switch rate {
        case 44_100, 48_000: rate
        case 88_200, 176_400, 352_800: 44_100
        default: 48_000
        }
    }
}

/// The cancellation state of one encode. Every field is read and written under `lock`.
nonisolated private final class EncodeSession: @unchecked Sendable {

    private let lock = NSLock()
    private var cancelledFlag = false
    private var reader: AVAssetReader?
    private var wake: (() -> Void)?

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelledFlag
    }

    func attach(reader: AVAssetReader) {
        lock.lock()
        self.reader = reader
        lock.unlock()
    }

    func setWake(_ wake: @escaping () -> Void) {
        lock.lock()
        self.wake = wake
        let alreadyCancelled = cancelledFlag
        lock.unlock()
        if alreadyCancelled { wake() }
    }

    func cancel() {
        lock.lock()
        cancelledFlag = true
        let reader = reader
        let wake = wake
        lock.unlock()
        reader?.cancelReading()
        wake?()
    }
}

/// Resumes a continuation at most once. `continuation` is read and cleared under `lock`.
nonisolated private final class OnceResumer: @unchecked Sendable {

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func resume() {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume()
    }
}

/// The reader and writer of one encode, handed to the pump queue that alone drives them; the session is thread-safe.
nonisolated private struct Pipeline: @unchecked Sendable {
    let reader: AVAssetReader
    let output: AVAssetReaderTrackOutput
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    let session: EncodeSession
}

extension WatchTranscoder {

    private func encode(
        source: URL,
        inspection: Inspection,
        bitRate: Int,
        destination: URL
    ) async throws {
        let partial = destination.appendingPathExtension("partial")
        let session = EncodeSession()
        activeSession = session
        activeSource = Self.identity(of: source)
        activePartial = partial
        defer {
            activeSession = nil
            activeSource = nil
            activePartial = nil
        }
        try? FileManager.default.removeItem(at: partial)
        let started = Date()
        do {
            try await withTaskCancellationHandler {
                try await Self.transcode(source: source, inspection: inspection, bitRate: bitRate, partial: partial, session: session)
            } onCancel: {
                session.cancel()
            }
            try Self.commit(partial, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            if !(error is TranscodeError) || Self.isFailure(error) {
                MidgarLog.notice("Watch transcode failed for \(source.lastPathComponent): \(error)", category: .connectivity)
            }
            throw error
        }
        let elapsed = Date().timeIntervalSince(started)
        MidgarLog.info(
            "Watch transcode \(source.lastPathComponent) at \(bitRate / 1000) kbps in \(String(format: "%.2f", elapsed)) s",
            category: .connectivity
        )
    }

    nonisolated private static func isFailure(_ error: Error) -> Bool {
        if case TranscodeError.cancelled = error { return false }
        return true
    }

    /// Renames in one atomic step so a reader sees the whole file or none.
    nonisolated private static func commit(_ partial: URL, to destination: URL) throws {
        guard rename(partial.path, destination.path) == 0 else {
            throw TranscodeError.writerFailed("rename failed: \(String(cString: strerror(errno)))")
        }
    }

    nonisolated private static func transcode(
        source: URL,
        inspection: Inspection,
        bitRate: Int,
        partial: URL,
        session: EncodeSession
    ) async throws {
        let asset = AVURLAsset(url: source)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else { throw TranscodeError.noAudioTrack }
        let tags = await TrackTags.read(from: source, asset: asset)

        let rate = outputSampleRate(forSource: inspection.sampleRate)
        let channels = min(inspection.channels, 2)
        let layout = channelLayoutData(channels: channels)

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = try await trimmedRange(of: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: decodeSettings(rate: rate, channels: channels, layout: layout))
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw TranscodeError.writerFailed("reader rejected output") }
        reader.add(output)
        session.attach(reader: reader)

        let writer = try AVAssetWriter(outputURL: partial, fileType: .m4a)
        let settings = encodeSettings(rate: rate, channels: channels, layout: layout, bitRate: bitRate)
        guard writer.canApply(outputSettings: settings, forMediaType: .audio) else {
            throw TranscodeError.writerFailed("writer rejected the encoder settings")
        }
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw TranscodeError.writerFailed("writer rejected input") }
        writer.add(input)
        writer.metadata = tags.metadataItems()

        let pipeline = Pipeline(reader: reader, output: output, writer: writer, input: input, session: session)
        guard !session.isCancelled else { throw TranscodeError.cancelled }
        guard reader.startReading() else {
            throw TranscodeError.writerFailed("read: \(reader.error?.localizedDescription ?? "unknown")")
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw TranscodeError.writerFailed("write: \(writer.error?.localizedDescription ?? "unknown")")
        }
        writer.startSession(atSourceTime: .zero)
        try await finish(pipeline)
    }

    /// The span the container reports. Some decoders hand back their last
    /// packet padded to a whole block, which would otherwise reach the encoder
    /// as audible-length silence on a very short track.
    nonisolated private static func trimmedRange(of asset: AVURLAsset) async throws -> CMTimeRange {
        let duration = try await asset.load(.duration)
        guard duration.isNumeric, duration > .zero else {
            return CMTimeRange(start: .zero, duration: .positiveInfinity)
        }
        return CMTimeRange(start: .zero, duration: duration)
    }

    nonisolated private static func finish(_ pipeline: Pipeline) async throws {
        let queue = DispatchQueue(label: "cc.midgarcorp.flaccy.watch-transcode", qos: .utility)
        await pump(pipeline, on: queue)
        await drain(queue)
        if pipeline.session.isCancelled {
            pipeline.reader.cancelReading()
            pipeline.writer.cancelWriting()
            throw TranscodeError.cancelled
        }
        if pipeline.reader.status == .failed {
            pipeline.writer.cancelWriting()
            throw TranscodeError.writerFailed("read: \(pipeline.reader.error?.localizedDescription ?? "unknown")")
        }
        await pipeline.writer.finishWriting()
        guard pipeline.writer.status == .completed else {
            throw TranscodeError.writerFailed("write: \(pipeline.writer.error?.localizedDescription ?? "unknown")")
        }
    }

    /// Feeds decoded buffers to the encoder until the source ends, the writer
    /// refuses a buffer, or the session is cancelled.
    nonisolated private static func pump(_ pipeline: Pipeline, on queue: DispatchQueue) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumer = OnceResumer(continuation)
            pipeline.session.setWake { resumer.resume() }
            pipeline.input.requestMediaDataWhenReady(on: queue) {
                while pipeline.input.isReadyForMoreMediaData {
                    if pipeline.session.isCancelled { return }
                    guard let buffer = pipeline.output.copyNextSampleBuffer() else {
                        pipeline.input.markAsFinished()
                        resumer.resume()
                        return
                    }
                    if !pipeline.input.append(buffer) {
                        pipeline.input.markAsFinished()
                        resumer.resume()
                        return
                    }
                }
            }
        }
    }

    /// Returns once any block already running on `queue` has left it.
    nonisolated private static func drain(_ queue: DispatchQueue) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { continuation.resume() }
        }
    }

    nonisolated private static func channelLayoutData(channels: Int) -> Data {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
        return withUnsafeBytes(of: &layout) { Data($0) }
    }

    nonisolated private static func decodeSettings(rate: Int, channels: Int, layout: Data) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: channels,
            AVChannelLayoutKey: layout,
        ]
    }

    /// The profile's rate is per channel pair, so a mono stream gets half.
    nonisolated static func encoderBitRate(profileRate: Int, channels: Int) -> Int {
        channels == 1 ? profileRate / 2 : profileRate
    }

    nonisolated static func encodeSettings(rate: Int, channels: Int, layout: Data, bitRate: Int) -> [String: Any] {
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: channels,
            AVChannelLayoutKey: layout,
            AVEncoderBitRateKey: encoderBitRate(profileRate: bitRate, channels: channels),
        ]
        settings[AVEncoderBitRateStrategyKey] = AVAudioBitRateStrategy_Constant
        return settings
    }
}

nonisolated private struct TrackTags {

    var title: String?
    var artist: String?
    var album: String?
    var albumArtist: String?
    var composer: String?
    var genre: String?
    var date: String?
    var trackNumber: Int?
    var discNumber: Int?
    var discTotal: Int?
    var artwork: Data?

    static let coverLimitPixels = 400
    static let coverByteBudget = 60_000
    static let coverQualities: [Double] = [0.8, 0.7, 0.6, 0.5]

    static func read(from source: URL, asset: AVURLAsset) async -> TrackTags {
        var tags = TrackTags()
        for item in await allItems(of: asset) { await tags.absorb(item) }
        let reader = await AudioMetadataReader.read(from: source)
        tags.fillMissing(from: reader)
        return tags
    }

    private static func allItems(of asset: AVURLAsset) async -> [AVMetadataItem] {
        var items = (try? await asset.load(.metadata)) ?? []
        let formats = (try? await asset.load(.availableMetadataFormats)) ?? []
        for format in formats {
            items += (try? await asset.loadMetadata(for: format)) ?? []
        }
        return items
    }

    private mutating func fillMissing(from reader: AudioMetadataReader.Result) {
        if title == nil { title = Self.nonEmpty(reader.title) }
        if artist == nil { artist = Self.nonEmpty(reader.artist) }
        if album == nil { album = Self.nonEmpty(reader.albumTitle) }
        if albumArtist == nil { albumArtist = Self.nonEmpty(reader.albumArtist) }
        if trackNumber == nil, reader.trackNumber > 0 { trackNumber = reader.trackNumber }
        if artwork == nil { artwork = reader.artworkData }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private enum Field {
        case title, artist, album, albumArtist, composer, genre, date, track, disc, artwork
    }

    private static let identifierFields: [AVMetadataIdentifier: Field] = [
        .commonIdentifierTitle: .title,
        .commonIdentifierArtist: .artist,
        .commonIdentifierAlbumName: .album,
        .commonIdentifierCreationDate: .date,
        .commonIdentifierArtwork: .artwork,
        .iTunesMetadataSongName: .title,
        .iTunesMetadataArtist: .artist,
        .iTunesMetadataAlbum: .album,
        .iTunesMetadataAlbumArtist: .albumArtist,
        .iTunesMetadataComposer: .composer,
        .iTunesMetadataUserGenre: .genre,
        .iTunesMetadataReleaseDate: .date,
        .iTunesMetadataTrackNumber: .track,
        .iTunesMetadataDiscNumber: .disc,
        .iTunesMetadataCoverArt: .artwork,
        .id3MetadataTitleDescription: .title,
        .id3MetadataLeadPerformer: .artist,
        .id3MetadataAlbumTitle: .album,
        .id3MetadataBand: .albumArtist,
        .id3MetadataComposer: .composer,
        .id3MetadataContentType: .genre,
        .id3MetadataYear: .date,
        .id3MetadataRecordingTime: .date,
        .id3MetadataTrackNumber: .track,
        .id3MetadataPartOfASet: .disc,
        .id3MetadataAttachedPicture: .artwork,
    ]

    private static let vorbisFields: [String: Field] = [
        "TITLE": .title,
        "ARTIST": .artist,
        "ALBUM": .album,
        "ALBUMARTIST": .albumArtist,
        "ALBUM ARTIST": .albumArtist,
        "ALBUM_ARTIST": .albumArtist,
        "COMPOSER": .composer,
        "GENRE": .genre,
        "DATE": .date,
        "YEAR": .date,
        "TRACKNUMBER": .track,
        "TRACK": .track,
        "DISCNUMBER": .disc,
        "DISC": .disc,
    ]

    private static func field(for item: AVMetadataItem) -> Field? {
        if let identifier = item.identifier, let field = identifierFields[identifier] { return field }
        guard let key = item.key as? String else { return nil }
        return vorbisFields[key.uppercased()]
    }

    private mutating func absorb(_ item: AVMetadataItem) async {
        if let key = (item.key as? String)?.uppercased(), Self.discTotalKeys.contains(key) {
            if discTotal == nil { discTotal = await Self.integerValue(of: item) }
            return
        }
        guard let field = Self.field(for: item) else { return }
        switch field {
        case .artwork:
            if artwork == nil, let data = try? await item.load(.dataValue), !data.isEmpty { artwork = data }
        case .track, .disc:
            await absorbPosition(item, field: field)
        default:
            guard let text = Self.nonEmpty(try? await item.load(.stringValue)) else { return }
            setText(text, for: field)
        }
    }

    private static let discTotalKeys: Set<String> = ["DISCTOTAL", "TOTALDISCS"]

    private static func integerValue(of item: AVMetadataItem) async -> Int? {
        if let text = try? await item.load(.stringValue), let value = Int(text.trimmingCharacters(in: .whitespaces)) { return value }
        return (try? await item.load(.numberValue))?.intValue
    }

    private mutating func setText(_ text: String, for field: Field) {
        switch field {
        case .title: if title == nil { title = text }
        case .artist: if artist == nil { artist = text }
        case .album: if album == nil { album = text }
        case .albumArtist: if albumArtist == nil { albumArtist = text }
        case .composer: if composer == nil { composer = text }
        case .genre: if genre == nil { genre = text }
        case .date: if date == nil { date = text }
        case .track, .disc, .artwork: break
        }
    }

    private mutating func absorbPosition(_ item: AVMetadataItem, field: Field) async {
        guard let position = await Self.position(of: item) else { return }
        if field == .track {
            if trackNumber == nil { trackNumber = position.number }
        } else {
            if discNumber == nil { discNumber = position.number }
            if discTotal == nil { discTotal = position.total }
        }
    }

    /// "3", "3/12" and the MP4 `trkn` / `disk` binary layout all read as a
    /// number with an optional total.
    private static func position(of item: AVMetadataItem) async -> (number: Int, total: Int?)? {
        if item.dataType == (kCMMetadataBaseDataType_RawData as String),
           let data = try? await item.load(.dataValue), data.count >= 6, let parsed = binaryPosition(data) {
            return parsed
        }
        if let text = try? await item.load(.stringValue) {
            let parts = text.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let first = parts.first, let number = Int(first) else { return nil }
            return (number, parts.count > 1 ? Int(parts[1]) : nil)
        }
        if let number = try? await item.load(.numberValue) { return (number.intValue, nil) }
        return nil
    }

    private static func binaryPosition(_ data: Data) -> (number: Int, total: Int?)? {
        let bytes = [UInt8](data)
        let number = Int(bytes[2]) << 8 | Int(bytes[3])
        let total = Int(bytes[4]) << 8 | Int(bytes[5])
        guard number > 0 else { return nil }
        return (number, total > 0 ? total : nil)
    }

    /// The track number goes in as an integer rather than the MP4 raw layout
    /// because `AudioMetadataReader` reads it through `numberValue`, which is
    /// nil for the raw layout and would report every encoded track as 0.
    func metadataItems() -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []
        func add(_ identifier: AVMetadataIdentifier, text: String?) {
            guard let text else { return }
            items.append(Self.item(identifier, value: text as NSString, dataType: kCMMetadataBaseDataType_UTF8))
        }
        add(.iTunesMetadataSongName, text: title)
        add(.iTunesMetadataArtist, text: artist)
        add(.iTunesMetadataAlbum, text: album)
        add(.iTunesMetadataAlbumArtist, text: albumArtist)
        add(.iTunesMetadataComposer, text: composer)
        add(.iTunesMetadataUserGenre, text: genre)
        add(.iTunesMetadataReleaseDate, text: date)
        if let trackNumber {
            items.append(Self.item(.iTunesMetadataTrackNumber, value: NSNumber(value: trackNumber), dataType: kCMMetadataBaseDataType_SInt32))
        }
        if let discNumber {
            items.append(Self.item(.iTunesMetadataDiscNumber, value: Self.discData(discNumber, discTotal) as NSData, dataType: kCMMetadataBaseDataType_RawData))
        }
        if let cover = artwork.flatMap(Self.coverJPEG) {
            items.append(Self.item(.iTunesMetadataCoverArt, value: cover as NSData, dataType: kCMMetadataBaseDataType_JPEG))
        }
        return items
    }

    private static func item(_ identifier: AVMetadataIdentifier, value: NSCopying & NSObjectProtocol, dataType: CFString) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value
        item.dataType = dataType as String
        item.extendedLanguageTag = "und"
        return item
    }

    /// The MP4 `disk` layout: two reserved bytes, disc, total.
    private static func discData(_ number: Int, _ total: Int?) -> Data {
        let total = total ?? 0
        return Data([0, 0, UInt8((number >> 8) & 0xFF), UInt8(number & 0xFF), UInt8((total >> 8) & 0xFF), UInt8(total & 0xFF)])
    }

    /// A JPEG no larger than 400 px on its long side, stepping the quality
    /// down from 0.8 only when the result would still be heavy.
    static func coverJPEG(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: coverLimitPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        var best: Data?
        for quality in coverQualities {
            guard let encoded = jpeg(image, quality: quality) else { continue }
            best = encoded
            if encoded.count <= coverByteBudget { break }
        }
        return best
    }

    private static func jpeg(_ image: CGImage, quality: Double) -> Data? {
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(buffer, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        let properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return buffer as Data
    }
}
