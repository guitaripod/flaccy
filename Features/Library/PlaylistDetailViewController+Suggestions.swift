import FlaccyCore
import MidgarCore
import UIKit

extension PlaylistDetailViewController {

    var showsSuggestions: Bool {
        PlaylistSuggestionsSetting.isShown && query.isEmpty && !isEditing && !rows.isEmpty
    }

    /// Builds the shelf again when the playlist's songs changed, so an added
    /// suggestion makes room for the next one and a removed song can come
    /// back as one.
    func reloadSuggestionsIfPlaylistChanged() {
        let basis = Set(rows.map(\.file))
        guard showsSuggestions else {
            if !suggestions.isEmpty {
                suggestions = []
                applySnapshot(animated: true)
            }
            return
        }
        guard basis != suggestionsBasis || suggestions.isEmpty else { return }
        suggestionsBasis = basis
        loadSuggestions()
    }

    func refreshSuggestions() {
        selectionFeedback.selectionChanged()
        suggestionsPage += 1
        loadSuggestions()
    }

    func hideSuggestions() {
        impactLight.impactOccurred()
        PlaylistSuggestionsSetting.setShown(false)
        ToastView.showAction(
            PlaylistCopy.hideSuggestions, actionTitle: PlaylistCopy.undo, in: view, style: .info
        ) {
            PlaylistSuggestionsSetting.setShown(true)
        }
    }

    @objc func suggestionsSettingChanged() {
        suggestionsBasis = []
        reloadSuggestionsIfPlaylistChanged()
    }

    private func loadSuggestions() {
        suggestionsTask?.cancel()
        let playlist = rows.compactMap(\.track)
        let library = Library.shared.allTracks
        let page = suggestionsPage
        suggestionsTask = Task { [weak self] in
            for cachedOnly in [true, false] {
                let found = await Task.detached(priority: .utility) {
                    await PlaylistSuggestionLoader.suggestions(for: playlist, library: library, page: page, cachedOnly: cachedOnly)
                }.value
                guard !Task.isCancelled, let self, self.showsSuggestions else { return }
                guard found.map(\.fileURL) != self.suggestions.map(\.fileURL) else { continue }
                self.suggestions = found
                self.applySnapshot(animated: self.hasLoadedOnce)
            }
        }
    }

    /// Adds a suggestion to the end of the playlist; the observation brings it
    /// into the list and the shelf fills the gap.
    func addSuggestion(_ track: Track) {
        suggestions.removeAll { $0.fileURL == track.fileURL }
        applySnapshot(animated: true)
        PlaylistWriter.add([track], toPlaylist: playlistId, named: playlistName, in: view)
    }
}

/// The Suggested Songs shelf's heading: what it is, where the songs come
/// from, and buttons to show different ones or hide the shelf.
final class PlaylistSuggestionsHeaderView: UITableViewHeaderFooterView {

    static let reuseID = "PlaylistSuggestionsHeaderView"

    var onRefresh: (() -> Void)?
    var onHide: (() -> Void)?

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        var background = UIBackgroundConfiguration.clear()
        background.backgroundColor = .flaccyBackground
        backgroundConfiguration = background

        let title = UILabel()
        title.text = PlaylistCopy.suggestedTitle
        title.font = UIFontMetrics(forTextStyle: .title3).scaledFont(for: .systemFont(ofSize: 20, weight: .bold))
        title.adjustsFontForContentSizeCategory = true
        title.accessibilityTraits = .header

        let subtitle = UILabel()
        subtitle.text = PlaylistCopy.suggestedSubtitle
        subtitle.font = .preferredFont(forTextStyle: .footnote)
        subtitle.adjustsFontForContentSizeCategory = true
        subtitle.textColor = .flaccySecondaryLabel
        subtitle.numberOfLines = 0

        let text = UIStackView(arrangedSubviews: [title, subtitle])
        text.axis = .vertical
        text.spacing = 2

        let refresh = Self.button(symbol: "arrow.clockwise", label: PlaylistCopy.refresh) { [weak self] in self?.onRefresh?() }
        refresh.accessibilityIdentifier = "playlist.suggestions.refresh"
        let hide = Self.button(symbol: "eye.slash", label: PlaylistCopy.hideSuggestions) { [weak self] in self?.onHide?() }

        let row = UIStackView(arrangedSubviews: [text, refresh, hide])
        row.alignment = .center
        row.spacing = 4
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 28),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            row.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static func button(symbol: String, label: String, action: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold))
        let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
        button.accessibilityLabel = label
        button.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        return button
    }
}

/// What a playlist page shows under its header when there is nothing to list:
/// a playlist with no songs offers Add Songs, a search with no match says so.
final class PlaylistEmptyFooterView: UIView {

    var onAddSongs: (() -> Void)?

    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let addButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0
        messageLabel.font = .preferredFont(forTextStyle: .subheadline)
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.textColor = .flaccySecondaryLabel
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0

        var add = UIButton.Configuration.borderedProminent()
        add.title = PlaylistCopy.addSongs
        add.image = UIImage(systemName: "plus")
        add.imagePadding = 6
        add.cornerStyle = .capsule
        addButton.configuration = add
        addButton.addAction(UIAction { [weak self] _ in self?.onAddSongs?() }, for: .touchUpInside)
        addButton.accessibilityIdentifier = "playlist.empty.addSongs"

        let stack = UIStackView(arrangedSubviews: [titleLabel, messageLabel, addButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        stack.setCustomSpacing(16, after: messageLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 32),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -32),
            stack.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor, constant: -16),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(title: String, message: String, offersAdd: Bool) {
        titleLabel.text = title
        messageLabel.text = message
        addButton.isHidden = !offersAdd
    }
}
