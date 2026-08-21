import AppKit
import FlaccyCore

/// Act III. What the reader just watched being built, stated as facts, with the
/// one paid capability that produced some of them named rather than implied.
///
/// The primary action is the whole point of the card: it takes the reader into
/// the library, and the secondary one is grey, optional and never in the way.
final class MacDebutSummaryCard: NSView {

    var onDismiss: (() -> Void)?
    var onSeeWhatsIncluded: (() -> Void)?

    private let summary: LibraryDebutSummary

    /// `aiSkippedForEntitlement` turns the card's grey paywall footnote into the
    /// one line an expired trial has earned the right to read: the tag cleanup
    /// did not run, and the secondary button is what runs it.
    init(summary: LibraryDebutSummary, aiSkippedForEntitlement: Bool) {
        self.summary = summary
        super.init(frame: .zero)

        let title = NSTextField(labelWithString: LibraryDebutCopy.cardTitle)
        title.font = .systemFont(ofSize: 24, weight: .bold)
        title.textColor = MacColors.primaryLabel

        let stats = NSGridView(views: [
            [
                stat(LibraryLoadPhaseCopy.number(summary.trackCount), LibraryDebutCopy.statLabel(.tracks)),
                stat(LibraryLoadPhaseCopy.number(summary.albumCount), LibraryDebutCopy.statLabel(.albums)),
            ],
            [
                stat(LibraryLoadPhaseCopy.number(summary.artistCount), LibraryDebutCopy.statLabel(.artists)),
                stat(Self.duration(summary.totalDurationSeconds), LibraryDebutCopy.statLabel(.duration)),
            ],
        ])
        stats.rowSpacing = 14
        stats.columnSpacing = 44
        stats.column(at: 0).xPlacement = .leading
        stats.column(at: 1).xPlacement = .leading

        var factLines = [
            line(LibraryDebutCopy.coversLine(
                coversResolved: summary.coversResolved, albumsDated: summary.albumsDated
            ))
        ]
        if summary.aiCleanedTracks > 0 {
            factLines.append(line(LibraryDebutCopy.aiLine(cleanedTracks: summary.aiCleanedTracks)))
        }
        factLines.append(line(LibraryDebutCopy.qualityLine(
            losslessPercent: Self.losslessPercent(summary), averageBitrate: summary.averageBitrate
        )))

        let lines = NSStackView(views: factLines)
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = 5

        let rule = NSBox()
        rule.boxType = .separator

        let paywall = NSTextField(
            wrappingLabelWithString: aiSkippedForEntitlement
                ? LibraryDebutCopy.aiSkippedHeadline
                : LibraryDebutCopy.paywallLine
        )
        paywall.font = aiSkippedForEntitlement
            ? .systemFont(ofSize: 13, weight: .medium)
            : .systemFont(ofSize: 11)
        paywall.textColor = aiSkippedForEntitlement
            ? MacColors.primaryLabel
            : MacColors.tertiaryLabel
        paywall.preferredMaxLayoutWidth = 460

        let primary = GlassCapsuleButton(
            title: LibraryDebutCopy.primaryAction, symbolName: "music.note.house", prominent: true
        )
        primary.onClick = { [weak self] in self?.onDismiss?() }

        let secondary = NSButton(
            title: aiSkippedForEntitlement
                ? LibraryDebutCopy.aiSkippedAction
                : LibraryDebutCopy.secondaryAction,
            target: self,
            action: #selector(seeWhatsIncluded)
        )
        secondary.bezelStyle = .accessoryBarAction
        secondary.isBordered = false
        secondary.contentTintColor = MacColors.secondaryLabel

        let actions = NSStackView(views: [primary, secondary])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 18

        let content = NSStackView(views: [title, stats, lines, rule, paywall, actions])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 16
        content.setCustomSpacing(20, after: title)
        content.setCustomSpacing(18, after: lines)
        content.setCustomSpacing(12, after: rule)
        content.setCustomSpacing(22, after: paywall)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        NSLayoutConstraint.activate([
            rule.widthAnchor.constraint(equalTo: content.widthAnchor),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 36),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 44),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -44),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -32),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(LibraryDebutCopy.cardTitle)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func seeWhatsIncluded() {
        onSeeWhatsIncluded?()
    }

    private func stat(_ value: String, _ caption: String) -> NSView {
        let valueLabel = NSTextField(labelWithString: value)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 21, weight: .semibold)
        valueLabel.textColor = MacColors.primaryLabel
        let captionLabel = NSTextField(labelWithString: caption.uppercased())
        captionLabel.font = .systemFont(ofSize: 9.5, weight: .semibold)
        captionLabel.textColor = MacColors.tertiaryLabel
        let stack = NSStackView(views: [valueLabel, captionLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        return stack
    }

    private func line(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12.5)
        label.textColor = MacColors.secondaryLabel
        return label
    }

    private static func losslessPercent(_ summary: LibraryDebutSummary) -> Int {
        guard summary.trackCount > 0 else { return 0 }
        return Int((Double(summary.losslessTrackCount) / Double(summary.trackCount) * 100).rounded())
    }

    private static func duration(_ seconds: Double) -> String {
        Duration.seconds(max(0, seconds))
            .formatted(.units(allowed: [.days, .hours], width: .wide, maximumUnitCount: 2))
    }
}

/// Builds the figures the card states, from the library that was just built.
///
/// It reads the database rather than trusting what the scan left in memory: the
/// in-memory `Album` never carries its cover on this client, so "covers found"
/// has to be asked of `albumInfo`. The work happens off the main thread because
/// the same numbers are written to `libraryDebut` and read back in Settings
/// forever after, and a wrong-but-fast answer would be wrong forever.
enum MacDebutSummaryBuilder {

    @MainActor
    static func build() async -> LibraryDebutSummary {
        let albums = Library.shared.albums.map { (title: $0.title, artist: $0.artist, year: $0.year) }
        return await Task.detached(priority: .userInitiated) {
            snapshot(of: albums)
        }.value
    }

    private static func snapshot(
        of albums: [(title: String, artist: String, year: String?)]
    ) -> LibraryDebutSummary {
        let records = (try? DatabaseManager.shared.fetchAllTracks()) ?? []
        let bitrates = records.compactMap(bitrate(of:))
        let covers = albums.count { album in
            ((try? DatabaseManager.shared.fetchAlbumInfoStatus(
                title: album.title, artist: album.artist
            ))?.hasCover ?? false)
        }

        return LibraryDebutSummary(
            trackCount: records.count,
            albumCount: albums.count,
            artistCount: Set(albums.map(\.artist)).count,
            coversResolved: covers,
            albumsDated: albums.count { $0.year != nil },
            aiCleanedTracks: records.count { $0.aiAnalyzed },
            losslessTrackCount: records.count { isLossless($0) },
            averageBitrate: bitrates.isEmpty ? 0 : bitrates.reduce(0, +) / bitrates.count,
            totalDurationSeconds: records.reduce(0) { $0 + $1.duration },
            completedAt: Date()
        )
    }

    private static let losslessCodecs: Set<String> = ["FLAC", "ALAC", "WAV", "AIFF"]

    private static func isLossless(_ record: TrackRecord) -> Bool {
        guard let codec = record.codec else { return false }
        return losslessCodecs.contains(codec.uppercased())
    }

    /// Uncompressed PCM rate in kbps. Lossy files carry no bit depth, so they are
    /// left out of the average rather than counted as zero — an average that
    /// includes a made-up number is worse than one that names a smaller set.
    private static func bitrate(of record: TrackRecord) -> Int? {
        guard let bitDepth = record.bitDepth, let sampleRate = record.sampleRate else { return nil }
        let channels = record.channels ?? 2
        return bitDepth * sampleRate * channels / 1000
    }
}
