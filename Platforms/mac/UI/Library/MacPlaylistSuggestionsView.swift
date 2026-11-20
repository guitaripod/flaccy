import AppKit
import FlaccyCore
import MidgarCore

/// The Suggested Songs shelf under a playlist's songs on the Mac: songs from
/// the person's own library that fit the playlist, each with a button that
/// adds it. Nothing is added on its own; Refresh shows the next ones and the
/// eye hides the shelf on every playlist, as on the iPhone.
final class MacPlaylistSuggestionsView: NSView {

    var onAdd: ((Track) -> Void)?
    var onRefresh: (() -> Void)?
    var onHide: (() -> Void)?

    private let rows = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let title = NSTextField(labelWithString: PlaylistCopy.suggestedTitle)
        title.font = .systemFont(ofSize: 17, weight: .bold)
        title.textColor = MacColors.primaryLabel
        let subtitle = NSTextField(labelWithString: PlaylistCopy.suggestedSubtitle)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = MacColors.secondaryLabel
        let text = NSStackView(views: [title, subtitle])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        let refresh = Self.iconButton(symbol: "arrow.clockwise", label: PlaylistCopy.refresh) { [weak self] in self?.onRefresh?() }
        let hide = Self.iconButton(symbol: "eye.slash", label: PlaylistCopy.hideSuggestions) { [weak self] in self?.onHide?() }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [text, spacer, refresh, hide])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6

        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 0

        let column = NSStackView(views: [header, rows])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.edgeInsets = NSEdgeInsets(top: 24, left: 0, bottom: 16, right: 0)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            header.widthAnchor.constraint(equalTo: column.widthAnchor),
            rows.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(PlaylistCopy.suggestedTitle)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ tracks: [Track]) {
        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for track in tracks {
            let row = MacSuggestionRow(track: track) { [weak self] in self?.onAdd?(track) }
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
        isHidden = tracks.isEmpty
    }

    private static func iconButton(symbol: String, label: String, action: @escaping () -> Void) -> NSButton {
        let button = ShelfButton(action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.contentTintColor = .controlAccentColor
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return button
    }
}

/// One suggestion: the album's cover, title and artist, and the add button.
/// A right click offers the usual song menu.
private final class MacSuggestionRow: NSView {

    private let track: Track
    private let cover = NSImageView()
    private var artworkKey = ""

    init(track: Track, onAdd: @escaping () -> Void) {
        self.track = track
        super.init(frame: .zero)
        cover.imageScaling = .scaleProportionallyUpOrDown
        cover.wantsLayer = true
        cover.layer?.cornerRadius = 4
        cover.layer?.masksToBounds = true
        cover.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)
        cover.contentTintColor = MacColors.tertiaryLabel
        cover.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: track.title)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        let album = track.albumTitle.trimmingCharacters(in: .whitespaces)
        let detail = NSTextField(labelWithString: album.isEmpty ? track.artist : "\(track.artist) · \(album)")
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = MacColors.secondaryLabel
        detail.lineBreakMode = .byTruncatingTail
        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let add = ShelfButton(action: onAdd)
        add.image = NSImage(systemSymbolName: "plus.circle", accessibilityDescription: PlaylistCopy.addSuggestion(track.title))
        add.isBordered = false
        add.bezelStyle = .regularSquare
        add.contentTintColor = .controlAccentColor
        add.toolTip = PlaylistCopy.addSuggestion(track.title)
        add.setAccessibilityLabel(PlaylistCopy.addSuggestion(track.title))

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [cover, text, spacer, add])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            cover.widthAnchor.constraint(equalToConstant: 32),
            cover.heightAnchor.constraint(equalToConstant: 32),
            add.widthAnchor.constraint(equalToConstant: 28),
            add.heightAnchor.constraint(equalToConstant: 28),
            heightAnchor.constraint(equalToConstant: 44),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        loadArtwork()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func menu(for event: NSEvent) -> NSMenu? {
        MacTrackMenuFactory.menu(for: track, anchor: self)
    }

    private func loadArtwork() {
        let key = track.albumTitle + "\u{0}" + track.artist
        artworkKey = key
        AlbumArtworkCache.shared.loadThumbnail(forAlbum: track.albumTitle, artist: track.artist) { [weak self] image in
            guard let self, self.artworkKey == key, let image else { return }
            self.cover.contentTintColor = nil
            self.cover.image = image
        }
    }
}

/// A borderless button that runs a closure.
private final class ShelfButton: NSButton {

    private let handler: () -> Void

    init(action: @escaping () -> Void) {
        handler = action
        super.init(frame: .zero)
        target = self
        self.action = #selector(run)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func run() { handler() }
}
