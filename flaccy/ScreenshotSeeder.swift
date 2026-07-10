#if targetEnvironment(simulator) || (os(macOS) && DEBUG)
import CoreGraphics
import Foundation

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Populates the Simulator with an entirely fictional demo library — invented
/// artists, albums, tracks, and original procedurally-generated cover art — so
/// App Store screenshots never depict third-party copyrighted material.
/// Activated only when the app is launched with `--seed-screenshots`, and only
/// on the Simulator. Real devices and store builds are never touched.
enum ScreenshotSeeder {

    static let launchArgument = "--seed-screenshots"

    static func seedIfRequested() {
        guard CommandLine.arguments.contains(launchArgument) else { return }
        seed()
    }

    private static func seed() {
        let db = DatabaseManager.shared
        guard (try? db.fetchAllTrackRelativePaths())?.isEmpty ?? true else { return }

        let documents = LibraryPaths.root
        writeAudioFiles(for: catalog, in: documents)
        insertTracks(for: catalog, db: db)
        insertAlbumInfo(for: catalog, db: db)
        insertScrobbles(for: catalog, db: db)
        insertLyrics(db: db)
        AppLogger.info("Screenshot seed complete: \(catalog.count) albums", category: .content)
    }

    struct DemoTrack {
        let number: Int
        let title: String
        let duration: Double
        let loved: Bool
    }

    struct DemoAlbum {
        let artist: String
        let title: String
        let year: String
        let genre: String
        let bitDepth: Int
        let sampleRate: Int
        let top: CGColor
        let bottom: CGColor
        let accent: CGColor
        let motif: Int
        let tracks: [DemoTrack]
    }

    static func rgb(_ hex: UInt32) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    static func track(_ n: Int, _ t: String, _ d: Double, loved: Bool = false) -> DemoTrack {
        DemoTrack(number: n, title: t, duration: d, loved: loved)
    }

    static let heroArtist = "Meridian Wolde"
    static let heroAlbum = "Parallax Hours"
    static let heroTrack = "Slow Machine"

    static let catalog: [DemoAlbum] = [
        DemoAlbum(artist: heroArtist, title: heroAlbum, year: "2023", genre: "Progressive",
                  bitDepth: 24, sampleRate: 96000, top: rgb(0x2B1A46), bottom: rgb(0x0C0714), accent: rgb(0xFF6B9D), motif: 0,
                  tracks: [track(1, "Cirrus", 224), track(2, heroTrack, 372, loved: true), track(3, "Ghost Harbor", 287),
                           track(4, "The Long Way Down", 341), track(5, "Undertow", 259, loved: true), track(6, "Parallax", 405)]),
        DemoAlbum(artist: "Kestrel Vale", title: "Aurorae", year: "2024", genre: "Ambient",
                  bitDepth: 24, sampleRate: 48000, top: rgb(0x0E3B4A), bottom: rgb(0x061318), accent: rgb(0x6FE3C8), motif: 4,
                  tracks: [track(1, "Glass Horizon", 312, loved: true), track(2, "Polar Light", 268), track(3, "Ice Cartography", 349),
                           track(4, "Northern Hush", 401), track(5, "Slow Aurora", 233)]),
        DemoAlbum(artist: "Novaeu", title: "Paper Cities", year: "2022", genre: "Indie",
                  bitDepth: 16, sampleRate: 44100, top: rgb(0x4A2C12), bottom: rgb(0x140A05), accent: rgb(0xFFB24A), motif: 1,
                  tracks: [track(1, "Neon Rain", 214), track(2, "Tin Rooftops", 198, loved: true), track(3, "Paper Cities", 247),
                           track(4, "Streetlight Choir", 231), track(5, "Low Tide", 262)]),
        DemoAlbum(artist: "The Hollowmen", title: "Ravine", year: "2021", genre: "Post-Rock",
                  bitDepth: 24, sampleRate: 96000, top: rgb(0x1F2C2E), bottom: rgb(0x080D0E), accent: rgb(0x9AE6B4), motif: 3,
                  tracks: [track(1, "Undertow", 386), track(2, "Ravine", 452, loved: true), track(3, "Scree", 298),
                           track(4, "Cairn", 371)]),
        DemoAlbum(artist: "Marisol Vane", title: "Ember & Ash", year: "2020", genre: "Soul",
                  bitDepth: 16, sampleRate: 44100, top: rgb(0x45162A), bottom: rgb(0x14060C), accent: rgb(0xFF8FA3), motif: 5,
                  tracks: [track(1, "Ember", 241, loved: true), track(2, "Ash", 268), track(3, "Copper Light", 224),
                           track(4, "Slow Burn", 292), track(5, "Afterglow", 257)]),
        DemoAlbum(artist: "Cobalt Fields", title: "Signal Bloom", year: "2024", genre: "Electronic",
                  bitDepth: 24, sampleRate: 48000, top: rgb(0x14235C), bottom: rgb(0x060A18), accent: rgb(0x5FA8FF), motif: 2,
                  tracks: [track(1, "Signal Bloom", 305), track(2, "Static Garden", 278, loved: true), track(3, "Lowband", 246),
                           track(4, "Nightshift", 331), track(5, "Carrier", 289)]),
        DemoAlbum(artist: "Ashgrove", title: "Lantern Year", year: "2019", genre: "Folk",
                  bitDepth: 16, sampleRate: 44100, top: rgb(0x3A2E14), bottom: rgb(0x110D06), accent: rgb(0xE6C36F), motif: 7,
                  tracks: [track(1, "Lantern Year", 223), track(2, "Threshing Song", 254, loved: true), track(3, "Hollow Oak", 211),
                           track(4, "Winterfold", 276)]),
        DemoAlbum(artist: "Virelle", title: "Cassini", year: "2023", genre: "Dream Pop",
                  bitDepth: 24, sampleRate: 48000, top: rgb(0x2E1550), bottom: rgb(0x0B0518), accent: rgb(0xC79BFF), motif: 6,
                  tracks: [track(1, "Cassini", 258), track(2, "Saturn Blue", 271, loved: true), track(3, "Ring Divide", 234),
                           track(4, "Titan", 299), track(5, "Slow Orbit", 246)]),
        DemoAlbum(artist: "Monsoon Atlas", title: "Tradewinds", year: "2022", genre: "Jazz",
                  bitDepth: 24, sampleRate: 96000, top: rgb(0x123A2E), bottom: rgb(0x05120D), accent: rgb(0x8FE6C0), motif: 8,
                  tracks: [track(1, "Tradewinds", 364, loved: true), track(2, "Harbor Master", 298), track(3, "Doldrums", 412),
                           track(4, "Monsoon", 337)]),
        DemoAlbum(artist: "Solveig", title: "Midnatt", year: "2024", genre: "Nordic",
                  bitDepth: 24, sampleRate: 48000, top: rgb(0x1A2740), bottom: rgb(0x070A12), accent: rgb(0x7FB8FF), motif: 9,
                  tracks: [track(1, "Midnatt", 287, loved: true), track(2, "Fjord", 246), track(3, "Snødrift", 268),
                           track(4, "Nordlys", 321), track(5, "Stilla", 234)]),
    ]

    private static func relativePath(album: DemoAlbum, track: DemoTrack) -> String {
        let name = String(format: "%02d - %@", track.number, track.title)
        return "\(album.artist)/\(album.title)/\(name).wav"
    }

    private static func writeAudioFiles(for albums: [DemoAlbum], in documents: URL) {
        let fm = FileManager.default
        var frequencyStep = 0
        for album in albums {
            for track in album.tracks {
                let fileURL = documents.appendingPathComponent(relativePath(album: album, track: track))
                try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let frequency = 196.0 * pow(2.0, Double(frequencyStep % 12) / 12.0)
                frequencyStep += 1
                let data = makeWAV(frequency: frequency, seconds: track.duration)
                try? data.write(to: fileURL)
            }
        }
    }

    private static func insertTracks(for albums: [DemoAlbum], db: DatabaseManager) {
        let now = Date()
        for album in albums {
            for track in album.tracks {
                let path = relativePath(album: album, track: track)
                let plays = playCount(album: album, track: track)
                let record = TrackRecord(
                    fileURL: path,
                    title: track.title,
                    artist: album.artist,
                    albumTitle: album.title,
                    trackNumber: track.number,
                    duration: track.duration,
                    artworkData: nil,
                    lastFMArtworkURL: nil,
                    musicBrainzID: nil,
                    albumMusicBrainzID: nil,
                    dateAdded: now.addingTimeInterval(-Double(album.year.hashValue % 3600)),
                    lastPlayed: plays > 0 ? now.addingTimeInterval(-Double((track.title.count * 3600))) : nil,
                    playCount: plays,
                    aiAnalyzed: true,
                    analysisAttemptedAt: now,
                    codec: "FLAC",
                    bitDepth: album.bitDepth,
                    sampleRate: album.sampleRate,
                    channels: 2,
                    loved: track.loved,
                    lovedPendingOp: nil
                )
                try? db.insertTrack(record)
            }
        }
    }

    private static func insertAlbumInfo(for albums: [DemoAlbum], db: DatabaseManager) {
        let now = Date()
        for album in albums {
            let art = CoverArtRenderer.render(album)
            do {
                var info = try db.fetchOrCreateAlbumInfo(title: album.title, artist: album.artist)
                info.coverArtData = art
                info.year = album.year
                info.genre = album.genre
                info.lastFetched = now
                try db.updateAlbumInfo(info)
            } catch {
                AppLogger.error("Seed album info failed: \(error.localizedDescription)", category: .database)
            }
        }
    }

    /// Deterministic per-track play weight so top lists and the persona read as a
    /// real listening year without any randomness (unavailable on a fresh sim run).
    private static func playCount(album: DemoAlbum, track: DemoTrack) -> Int {
        var weight = (abs(track.title.hashValue) % 9) + 1
        if album.artist == heroArtist { weight += 14 }
        if track.title == heroTrack { weight += 22 }
        if track.loved { weight += 6 }
        return weight
    }

    private static func insertScrobbles(for albums: [DemoAlbum], db: DatabaseManager) {
        let calendar = Calendar(identifier: .gregorian)
        guard let yearStart = calendar.date(from: DateComponents(year: 2025, month: 1, day: 1)) else { return }

        var records: [(album: DemoAlbum, track: DemoTrack)] = []
        for album in albums {
            for track in album.tracks {
                for _ in 0..<playCount(album: album, track: track) { records.append((album, track)) }
            }
        }

        var index = 0
        for entry in records {
            let dayOffset = (index * 149) % 540
            let lateNight = index % 4 == 0
            let hour = lateNight ? (index % 6) : (9 + (index % 13))
            let minute = (index * 17) % 60
            let base = calendar.date(byAdding: .day, value: dayOffset, to: yearStart) ?? yearStart
            let timestamp = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: base) ?? base
            index += 1
            let scrobble = ScrobbleRecord(
                trackTitle: entry.track.title,
                artist: entry.album.artist,
                albumTitle: entry.album.title,
                timestamp: timestamp,
                duration: Int(entry.track.duration),
                submitted: true
            )
            try? db.insertScrobble(scrobble)
        }
    }

    private static func insertLyrics(db: DatabaseManager) {
        let synced = """
        [00:11.40]Headlights bleed across the ceiling
        [00:15.90]I count the seconds like they owe me
        [00:20.60]A slow machine that keeps on turning
        [00:25.30]Warm hum of everything you told me
        [00:33.10]So let it idle, let it wander
        [00:37.80]The engine of a quiet morning
        [00:42.50]We are the miles we never squandered
        [00:47.20]The long road learning how to hold me
        [00:55.00]Slow machine, keep the light on
        [00:59.70]Slow machine, don't let go
        [01:04.40]Every ending is a corner
        [01:09.10]Every corner, somewhere warmer
        """
        let record = LyricsRecord(
            trackTitle: heroTrack,
            artist: heroArtist,
            syncedLyrics: synced,
            plainLyrics: nil,
            instrumental: false
        )
        try? db.saveLyrics(record)
    }

    private static func makeWAV(frequency: Double, seconds: Double, sampleRate: Double = 8_000) -> Data {
        let frameCount = Int(seconds * sampleRate)
        var samples = [Int16](repeating: 0, count: frameCount)
        let amplitude = 0.2 * Double(Int16.max)
        let fade = Int(sampleRate * 0.05)
        for i in 0..<frameCount {
            let theta = 2.0 * Double.pi * frequency * Double(i) / sampleRate
            var value = sin(theta) * amplitude
            if i < fade { value *= Double(i) / Double(fade) }
            if i > frameCount - fade { value *= Double(frameCount - i) / Double(fade) }
            samples[i] = Int16(value)
        }
        let byteRate = Int(sampleRate) * 2
        let dataBytes = samples.withUnsafeBytes { Data($0) }
        var wav = Data()
        func append(_ s: String) { wav.append(contentsOf: s.utf8) }
        func u32(_ v: UInt32) { var x = v.littleEndian; wav.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; wav.append(Data(bytes: &x, count: 2)) }
        append("RIFF"); u32(UInt32(36 + dataBytes.count)); append("WAVE")
        append("fmt "); u32(16); u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(byteRate)); u16(2); u16(16)
        append("data"); u32(UInt32(dataBytes.count)); wav.append(dataBytes)
        return wav
    }
}

/// Renders original, abstract album covers from a palette + motif index. Nothing
/// here reproduces or references any real-world artwork.
private enum CoverArtRenderer {

    static func render(_ album: ScreenshotSeeder.DemoAlbum) -> Data? {
        let size = 1000
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let s = CGFloat(size)
        let bg = CGGradient(colorsSpace: nil, colors: [album.top, album.bottom] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])
        drawMotif(album.motif, in: ctx, size: s, accent: album.accent)
        drawVignette(in: ctx, size: s)
        guard let image = ctx.makeImage() else { return nil }
        return PlatformImage(cgImage: image).jpegData(compressionQuality: 0.9)
    }

    private static func drawMotif(_ motif: Int, in ctx: CGContext, size s: CGFloat, accent: CGColor) {
        ctx.saveGState()
        ctx.setStrokeColor(accent)
        ctx.setFillColor(accent)
        switch motif {
        case 0:
            ctx.setLineWidth(6)
            for i in 0..<9 {
                let r = s * 0.09 * CGFloat(i + 1)
                ctx.setAlpha(0.8 - CGFloat(i) * 0.07)
                ctx.strokeEllipse(in: CGRect(x: s * 0.62 - r, y: s * 0.7 - r, width: r * 2, height: r * 2))
            }
        case 1:
            ctx.setLineWidth(s * 0.045)
            for i in 0..<7 {
                ctx.setAlpha(0.5 - CGFloat(i) * 0.05)
                let offset = CGFloat(i) * s * 0.14 - s * 0.2
                ctx.move(to: CGPoint(x: offset, y: 0)); ctx.addLine(to: CGPoint(x: offset + s, y: s)); ctx.strokePath()
            }
        case 2:
            for r in 0..<10 {
                for c in 0..<10 {
                    ctx.setAlpha(0.15 + CGFloat((r + c) % 5) * 0.14)
                    let d = s * 0.05
                    ctx.fillEllipse(in: CGRect(x: s * 0.08 + CGFloat(c) * s * 0.086, y: s * 0.08 + CGFloat(r) * s * 0.086, width: d, height: d))
                }
            }
        case 3:
            ctx.setAlpha(0.85)
            ctx.move(to: CGPoint(x: 0, y: s * 0.28))
            ctx.addLine(to: CGPoint(x: s * 0.34, y: s * 0.62))
            ctx.addLine(to: CGPoint(x: s * 0.6, y: s * 0.4))
            ctx.addLine(to: CGPoint(x: s, y: s * 0.78))
            ctx.addLine(to: CGPoint(x: s, y: 0)); ctx.addLine(to: CGPoint(x: 0, y: 0)); ctx.fillPath()
        case 4:
            ctx.setLineWidth(7)
            for band in 0..<5 {
                ctx.setAlpha(0.7 - CGFloat(band) * 0.1)
                let yBase = s * (0.35 + CGFloat(band) * 0.11)
                ctx.move(to: CGPoint(x: 0, y: yBase))
                for x in stride(from: 0.0, through: Double(s), by: 8) {
                    let y = yBase + sin(x / 70 + Double(band)) * Double(s) * 0.05
                    ctx.addLine(to: CGPoint(x: CGFloat(x), y: CGFloat(y)))
                }
                ctx.strokePath()
            }
        case 5:
            ctx.setAlpha(0.9)
            ctx.fillEllipse(in: CGRect(x: s * 0.42, y: s * 0.46, width: s * 0.62, height: s * 0.62))
            ctx.setBlendMode(.softLight)
            ctx.fillEllipse(in: CGRect(x: s * 0.1, y: s * 0.08, width: s * 0.3, height: s * 0.3))
        case 6:
            for i in 0..<6 {
                ctx.setAlpha(0.5 - CGFloat(i) * 0.06)
                ctx.setLineWidth(5)
                let inset = s * 0.1 + CGFloat(i) * s * 0.06
                ctx.stroke(CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2))
            }
        case 7:
            ctx.setLineWidth(4)
            let center = CGPoint(x: s * 0.5, y: s * 0.42)
            for i in 0..<24 {
                ctx.setAlpha(0.5)
                let a = Double(i) / 24 * 2 * .pi
                ctx.move(to: center)
                ctx.addLine(to: CGPoint(x: center.x + CGFloat(cos(a)) * s, y: center.y + CGFloat(sin(a)) * s))
                ctx.strokePath()
            }
        case 8:
            ctx.setAlpha(0.85)
            for i in 0..<5 {
                let inset = s * 0.14 + CGFloat(i) * s * 0.07
                ctx.setAlpha(0.7 - CGFloat(i) * 0.12)
                let path = CGPath(roundedRect: CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2),
                                  cornerWidth: s * 0.08, cornerHeight: s * 0.08, transform: nil)
                ctx.addPath(path); ctx.setLineWidth(6); ctx.strokePath()
            }
        default:
            for r in 0..<14 {
                for c in 0..<14 {
                    let d = s * 0.02 * CGFloat(r) / 6
                    ctx.setAlpha(0.5)
                    ctx.fillEllipse(in: CGRect(x: s * 0.05 + CGFloat(c) * s * 0.066, y: s * 0.05 + CGFloat(r) * s * 0.066, width: d, height: d))
                }
            }
        }
        ctx.restoreGState()
    }

    private static func drawVignette(in ctx: CGContext, size s: CGFloat) {
        let grad = CGGradient(colorsSpace: nil, colors: [
            CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0),
            CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.45),
        ] as CFArray, locations: [0.55, 1])!
        ctx.drawRadialGradient(grad, startCenter: CGPoint(x: s / 2, y: s / 2), startRadius: 0,
                               endCenter: CGPoint(x: s / 2, y: s / 2), endRadius: s * 0.75, options: [])
    }

}
#endif
