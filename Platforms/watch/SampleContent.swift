import Foundation

/// Synthesizes the fictional marketing catalog into Documents so the watch
/// app is demonstrable on the Simulator: real-length tracks (a quiet looped
/// tone, so a screenshot taken during playback shows a believable mid-track
/// position) in `Artist/Album/NN - Title.wav` folders. Compiled only for the
/// Simulator (`#if targetEnvironment(simulator)`); real devices rely on
/// side-loaded music.
enum SampleContent {

    struct Album {
        let artist: String
        let title: String
        let tracks: [Track]
    }

    struct Track {
        let title: String
        let seconds: Int
    }

    static let heroArtist = "Meridian Wolde"
    static let heroAlbum = "Parallax Hours"
    static let heroTrack = "Slow Machine"

    static let catalog: [Album] = [
        Album(artist: heroArtist, title: heroAlbum, tracks: [
            Track(title: "Cirrus", seconds: 224),
            Track(title: heroTrack, seconds: 292),
            Track(title: "Ghost Harbor", seconds: 287),
            Track(title: "Slow Descent", seconds: 261),
            Track(title: "Undertow", seconds: 259),
            Track(title: "Parallax", seconds: 275),
        ]),
        Album(artist: "Kestrel Vale", title: "Aurorae", tracks: [
            Track(title: "Glass Horizon", seconds: 292),
            Track(title: "Polar Light", seconds: 268),
            Track(title: "Ice Cartography", seconds: 249),
            Track(title: "Slow Aurora", seconds: 233),
        ]),
        Album(artist: "Novaeu", title: "Paper Cities", tracks: [
            Track(title: "Neon Rain", seconds: 214),
            Track(title: "Tin Rooftops", seconds: 198),
            Track(title: "Paper Cities", seconds: 247),
            Track(title: "Streetlight Choir", seconds: 231),
        ]),
        Album(artist: "Marisol Vane", title: "Ember & Ash", tracks: [
            Track(title: "Ember", seconds: 241),
            Track(title: "Ash", seconds: 268),
            Track(title: "Copper Light", seconds: 224),
            Track(title: "Afterglow", seconds: 257),
        ]),
        Album(artist: "Cobalt Fields", title: "Signal Bloom", tracks: [
            Track(title: "Signal Bloom", seconds: 285),
            Track(title: "Static Garden", seconds: 278),
            Track(title: "Lowband", seconds: 246),
        ]),
        Album(artist: "Virelle", title: "Cassini", tracks: [
            Track(title: "Cassini", seconds: 258),
            Track(title: "Saturn Blue", seconds: 271),
            Track(title: "Ring Divide", seconds: 234),
            Track(title: "Slow Orbit", seconds: 246),
        ]),
        Album(artist: "Ashgrove", title: "Lantern Year", tracks: [
            Track(title: "Lantern Year", seconds: 223),
            Track(title: "Threshing Song", seconds: 254),
            Track(title: "Hollow Oak", seconds: 211),
        ]),
        Album(artist: heroArtist, title: "Field Lines", tracks: [
            Track(title: "Field Lines", seconds: 298),
            Track(title: "Magnet School", seconds: 271),
            Track(title: "Solenoid", seconds: 276),
            Track(title: "Iron Filings", seconds: 254),
        ]),
    ]

    private static let sampleRate = 8_000
    private static let loopSeconds = 4

    static func seedIfNeeded(in documentsDirectory: URL) async {
        let fileManager = FileManager.default
        let marker = documentsDirectory.appendingPathComponent(markerRelativePath)
        guard !fileManager.fileExists(atPath: marker.path) else { return }

        for entry in entriesMarkerLast() {
            write(entry, in: documentsDirectory, fileManager: fileManager)
        }
    }

    private struct Entry {
        let album: Album
        let track: Track
        let number: Int

        var relativePath: String {
            "\(album.artist)/\(album.title)/" + String(format: "%02d - %@.wav", number, track.title)
        }
    }

    private static var markerRelativePath: String {
        Entry(album: catalog[0], track: catalog[0].tracks[0], number: 1).relativePath
    }

    /// The idempotence marker is the very last file written, so a seed that was
    /// cut short is simply redone on the next launch instead of being mistaken
    /// for a finished library.
    private static func entriesMarkerLast() -> [Entry] {
        let all = catalog.flatMap { album in
            album.tracks.enumerated().map { Entry(album: album, track: $1, number: $0 + 1) }
        }
        return all.filter { $0.relativePath != markerRelativePath } + all.filter { $0.relativePath == markerRelativePath }
    }

    private static func write(_ entry: Entry, in documentsDirectory: URL, fileManager: FileManager) {
        let fileURL = documentsDirectory.appendingPathComponent(entry.relativePath)
        try? fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = makeWAV(seconds: entry.track.seconds, frequency: frequency(for: entry.track.title))
        try? data.write(to: fileURL)
    }

    /// A pitch in the A-minor pentatonic range, derived from the title so each
    /// track hums its own quiet note.
    private static func frequency(for title: String) -> Double {
        let notes: [Double] = [220.0, 246.94, 261.63, 293.66, 329.63, 392.0]
        let sum = title.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return notes[sum % notes.count]
    }

    /// One short loop of a soft, slowly breathing tone, repeated to the full
    /// length: minutes of audio cost one small buffer to compute.
    private static func makeWAV(seconds: Int, frequency: Double) -> Data {
        let loop = makeLoop(frequency: frequency)
        let loopBytes = loop.withUnsafeBytes { Data($0) }
        let totalBytes = seconds * sampleRate * 2
        var body = Data(capacity: totalBytes)
        while body.count + loopBytes.count <= totalBytes { body.append(loopBytes) }
        body.append(loopBytes.prefix(totalBytes - body.count))
        return header(dataByteCount: body.count) + body
    }

    private static func makeLoop(frequency: Double) -> [Int16] {
        let count = sampleRate * loopSeconds
        let cycles = (frequency * Double(loopSeconds)).rounded()
        let tuned = cycles / Double(loopSeconds)
        let amplitude = 0.05 * Double(Int16.max)
        return (0..<count).map { index in
            let time = Double(index) / Double(sampleRate)
            let breath = 0.65 + 0.35 * sin(2.0 * Double.pi * time / Double(loopSeconds))
            let fundamental = sin(2.0 * Double.pi * tuned * time)
            let fifth = 0.4 * sin(2.0 * Double.pi * tuned * 1.5 * time)
            return Int16(amplitude * breath * (fundamental + fifth) / 1.4)
        }
    }

    private static func header(dataByteCount: Int) -> Data {
        var wav = Data()
        func append(_ string: String) { wav.append(contentsOf: string.utf8) }
        func appendUInt32(_ value: UInt32) { var v = value.littleEndian; wav.append(Data(bytes: &v, count: 4)) }
        func appendUInt16(_ value: UInt16) { var v = value.littleEndian; wav.append(Data(bytes: &v, count: 2)) }

        append("RIFF")
        appendUInt32(UInt32(36 + dataByteCount))
        append("WAVE")
        append("fmt ")
        appendUInt32(16)
        appendUInt16(1)
        appendUInt16(1)
        appendUInt32(UInt32(sampleRate))
        appendUInt32(UInt32(sampleRate * 2))
        appendUInt16(2)
        appendUInt16(16)
        append("data")
        appendUInt32(UInt32(dataByteCount))
        return wav
    }
}
