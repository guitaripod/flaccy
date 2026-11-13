import FlaccyCore
import FlaccyEngine
import Foundation

/// The account of the song playing now that the iPhone's Sound page and the Mac's Sound pane
/// both draw: the file, what Flaccy does to it, where it goes, and the one-line verdict, each read
/// from the player, the equalizer, the song's own volume and the audio output.
nonisolated struct SignalPathSummary: Hashable {
    let source: String
    let sourceDetail: String
    let processing: String
    let processingDetail: String?
    let output: String
    let outputDetail: String?
    let verdict: SignalPathVerdict
    let outputKind: SignalOutputKind?

    var isUntouched: Bool { processingDetail == nil }

    /// The path of the song playing now.
    @MainActor static func current() -> SignalPathSummary {
        let track = AudioPlayer.shared.currentTrack
        let engine = EqualizerEngine.shared
        let running = engine.runningProfile
        let tenths = track.map { SongVolumeStore.shared.level(for: $0) } ?? 0
        let output = engine.output
        let outputKind = output.map { SignalOutputKind(rawValue: $0.kind.rawValue) ?? .other }
        let verdict = SignalPathVerdict.of(
            sourceIsLossless: track.map(\.isLossless),
            processed: running != nil || tenths != 0,
            output: outputKind
        )
        return SignalPathSummary(
            source: track.map { $0.qualityBadge ?? $0.title } ?? String(localized: "Nothing playing"),
            sourceDetail: track.map(sourceDetail(of:)) ?? String(localized: "Play a song to see how it reaches you."),
            processing: running == nil && tenths == 0 ? String(localized: "Untouched") : String(localized: "Shaped"),
            processingDetail: processingDetail(profile: running, tenths: tenths),
            output: output?.name ?? String(localized: "This device"),
            outputDetail: outputDetail(kind: outputKind, hertz: EqualizerOutputWatcher.outputSampleRate()),
            verdict: verdict,
            outputKind: outputKind
        )
    }

    static func sourceDetail(of track: Track) -> String {
        let hiRes = (track.bitDepth ?? 0) > 16 || (track.sampleRate ?? 0) > 48_000
        let quality = track.isLossless
            ? (hiRes ? String(localized: "Lossless, hi-res") : String(localized: "Lossless"))
            : String(localized: "Lossy")
        return "\(track.title) · \(quality)"
    }

    @MainActor static func processingDetail(profile: EqualizerProfile?, tenths: Int) -> String? {
        var parts: [String] = []
        if let profile {
            parts.append(String(localized: "Equalizer: \(EqualizerCopy.name(of: profile))"))
        }
        if tenths != 0 {
            parts.append(String(localized: "Song volume \(SongGain.label(tenths))"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The kind of output and the rate it runs at, such as "Bluetooth · 48 kHz".
    static func outputDetail(kind: SignalOutputKind?, hertz: Double?) -> String? {
        let name: String? = switch kind {
        case .speaker: String(localized: "Built-in speaker")
        case .headphones: String(localized: "Wired headphones")
        case .bluetooth: String(localized: "Bluetooth")
        case .airPlay: String(localized: "AirPlay")
        case .usb: String(localized: "USB audio")
        case .display: String(localized: "Display")
        case .car: String(localized: "CarPlay")
        case .other, nil: nil
        }
        let rate = hertz.map { "\(($0 / 1000).formatted(.number.precision(.fractionLength(0...1)))) kHz" }
        let parts = [name, rate].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func sentence(for verdict: SignalPathVerdict) -> String {
        switch verdict {
        case .idle: String(localized: "Play a song to see how it reaches you.")
        case .untouched: String(localized: "Flaccy passes every sample through untouched.")
        case .shaped: String(localized: "Your equalizer or song volume shapes the sound before it plays.")
        case .reencodedForBluetooth: String(localized: "Bluetooth re-encodes the sound to AAC on its way to your headphones.")
        case .lossySource: String(localized: "This file is lossy. Flaccy plays it as it is.")
        }
    }

    static func symbolName(for kind: SignalOutputKind?) -> String {
        switch kind {
        case .speaker: "speaker.wave.2.fill"
        case .headphones: "headphones"
        case .bluetooth: "airpods"
        case .airPlay: "airplayaudio"
        case .usb: "cable.connector"
        case .display: "tv"
        case .car: "car.fill"
        case .other, nil: "hifispeaker.fill"
        }
    }

    /// The Listening Guide cards worth reading for this output, as indices into
    /// `ListeningGuideContent.cards` with their titles and symbols.
    @MainActor static func guideCards(for kind: SignalOutputKind?) -> [(index: Int, card: ListeningGuideCard)] {
        let cards = ListeningGuideContent.cards
        return SignalPathVerdict.guideCards(for: kind).compactMap { index in
            cards.indices.contains(index) ? (index, cards[index]) : nil
        }
    }
}

/// The library by the numbers for the top of the Library settings on the iPhone and the Mac.
nonisolated struct LibraryOverviewSummary: Hashable {
    let songs: Int
    let albums: Int
    let artists: Int
    let hours: Int
    let losslessPercent: Int
    let hiRes: Int
    let musicBytes: Int64
    let serverSongs: Int
    let formats: [Format]

    nonisolated struct Format: Hashable {
        let codec: String
        let songs: Int
    }

    static let empty = LibraryOverviewSummary(
        songs: 0, albums: 0, artists: 0, hours: 0, losslessPercent: 0, hiRes: 0, musicBytes: 0, serverSongs: 0, formats: []
    )

    /// Reads the overview off the main thread; nil when the database cannot be read.
    static func load(albums: [Album]) async -> LibraryOverviewSummary? {
        await Task.detached(priority: .utility) {
            guard let totals = try? DatabaseManager.shared.libraryOverview() else { return nil }
            let artists = artistCount(in: albums)
            return LibraryOverviewSummary(
                songs: totals.tracks,
                albums: albums.count,
                artists: artists,
                hours: Int((totals.seconds / 3600).rounded()),
                losslessPercent: Int((totals.losslessShare * 100).rounded()),
                hiRes: totals.hiRes,
                musicBytes: totals.localBytes,
                serverSongs: totals.serverTracks,
                formats: totals.codecs.map { Format(codec: $0.codec, songs: $0.tracks) }
            )
        }.value
    }

    /// Every artist the Artists tab lists: each album's credit and every performer on its songs,
    /// folded the way artist pages fold names, as Linux counts them.
    static func artistCount(in albums: [Album]) -> Int {
        var keys = Set<String>()
        for album in albums {
            keys.insert(LibraryHygiene.artistKey(album.artist))
            for track in album.tracks {
                keys.insert(LibraryHygiene.artistKey(track.artist))
            }
        }
        return keys.count
    }

    /// The four biggest formats and the rest folded into one, each as a fraction of the library.
    var formatShares: [(codec: String, fraction: Double)] {
        guard songs > 0 else { return [] }
        let sorted = formats.sorted { $0.songs > $1.songs }
        var shares = sorted.prefix(4).map { (codec: $0.codec, fraction: Double($0.songs) / Double(songs)) }
        let rest = sorted.dropFirst(4).reduce(0) { $0 + $1.songs }
        if rest > 0 { shares.append((codec: String(localized: "Other"), fraction: Double(rest) / Double(songs))) }
        return shares
    }

    var accessibilitySummary: String {
        let shares = formatShares.map { "\($0.codec) \($0.fraction.formatted(.percent.precision(.fractionLength(0))))" }
        return ([
            String(localized: "\(songs) songs"), String(localized: "\(albums) albums"),
            String(localized: "\(losslessPercent)% lossless"),
        ] + shares).joined(separator: ", ")
    }
}
