import FlaccyCore
import FlaccyEngine
import MidgarCore
import UIKit

/// Make a Playlist on iPhone and iPad: a sentence, then the playlist made from the person's own library, to play,
/// save as an ordinary playlist or change with another sentence.
final class PlaylistMakerViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UITextViewDelegate {

    private enum Phase {
        case asking
        case working(PlaylistMakerStep)
        case made(PlaylistDraft)
        case failed(PlaylistMakerFailure)
    }

    private static let padding: CGFloat = 20
    private static let fieldInset: CGFloat = 12
    private static let artworkSize = CGSize(width: 44, height: 44)
    private static let cell = "song"

    private let service: PlaylistMakerService
    private let feedback = UIImpactFeedbackGenerator(style: .light)
    private let table = UITableView(frame: .zero, style: .plain)
    private let header = UIStackView()
    private let inputBox = UIView()
    private let field = UITextView()
    private let placeholderLabel = UILabel()
    private lazy var makeButton = button(PlaylistMakerCopy.make, filled: true) { [weak self] in self?.makeTapped() }
    private let explanationLabel = UILabel()
    private let examples = UIStackView()
    private let statusRow = UIStackView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let statusLabel = UILabel()
    private let failureLabel = UILabel()
    private lazy var failureButton = button("", filled: false) { [weak self] in self?.failureAction?() }
    private let nameLabel = UILabel()
    private let summaryLabel = UILabel()
    private let noteLabel = UILabel()
    private let actions = UIStackView()
    private lazy var playButton = button(PlaylistMakerCopy.play, filled: true) { [weak self] in self?.playTapped() }
    private lazy var saveButton = button(PlaylistMakerCopy.save, filled: false) { [weak self] in self?.saveTapped() }
    private lazy var changeButton = button(PlaylistMakerCopy.changeIt, filled: false) { [weak self] in self?.changeTapped() }
    private var failureAction: (() -> Void)?
    private var work: Task<Void, Never>?
    private var isSaved = false
    private var phase: Phase = .asking {
        didSet { render() }
    }

    init(service: PlaylistMakerService = .shared) {
        self.service = service
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    /// Presents Make a Playlist as a sheet. With `request` it starts making that playlist at once.
    @discardableResult
    static func present(from presenter: UIViewController, request: String? = nil) -> PlaylistMakerViewController {
        let maker = PlaylistMakerViewController()
        let navigation = UINavigationController(rootViewController: maker)
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        presenter.present(navigation, animated: true) {
            guard let request else { return }
            maker.ask(request)
        }
        return maker
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = PlaylistMakerCopy.title
        view.backgroundColor = .systemBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .close,
            primaryAction: UIAction { [weak self] _ in
                self?.feedback.impactOccurred()
                self?.dismiss(animated: true)
            }
        )
        buildHeader()
        buildTable()
        render()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if case .asking = phase, field.text.isEmpty { field.becomeFirstResponder() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || navigationController?.isBeingDismissed == true { work?.cancel() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        fitHeader()
    }

    private func buildTable() {
        table.translatesAutoresizingMaskIntoConstraints = false
        table.dataSource = self
        table.delegate = self
        table.register(UITableViewCell.self, forCellReuseIdentifier: Self.cell)
        table.keyboardDismissMode = .onDrag
        table.tableHeaderView = header
        view.addSubview(table)
        NSLayoutConstraint.activate([
            table.topAnchor.constraint(equalTo: view.topAnchor),
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            table.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
    }

    private func buildHeader() {
        header.axis = .vertical
        header.spacing = 14
        header.alignment = .fill
        header.isLayoutMarginsRelativeArrangement = true
        header.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: Self.padding, bottom: 12, trailing: Self.padding)

        buildField()
        header.addArrangedSubview(inputBox)
        header.addArrangedSubview(row(makeButton))

        spinner.startAnimating()
        configure(statusLabel, style: .subheadline, color: .secondaryLabel)
        statusRow.axis = .horizontal
        statusRow.spacing = 10
        statusRow.alignment = .center
        statusRow.addArrangedSubview(spinner)
        statusRow.addArrangedSubview(statusLabel)
        header.addArrangedSubview(statusRow)

        configure(failureLabel, style: .callout, color: .label)
        header.addArrangedSubview(failureLabel)
        header.addArrangedSubview(row(failureButton))

        examples.axis = .vertical
        examples.spacing = 8
        examples.alignment = .leading
        for example in PlaylistMakerCopy.examples {
            examples.addArrangedSubview(button(example, filled: false) { [weak self] in self?.ask(example) })
        }
        header.addArrangedSubview(examples)
        configure(explanationLabel, style: .footnote, color: .secondaryLabel)
        explanationLabel.text = PlaylistMakerCopy.explanation
        header.addArrangedSubview(explanationLabel)

        configure(nameLabel, style: .title2, color: .label, weight: .bold)
        nameLabel.accessibilityTraits = .header
        header.addArrangedSubview(nameLabel)
        header.setCustomSpacing(2, after: nameLabel)
        configure(summaryLabel, style: .subheadline, color: .secondaryLabel)
        header.addArrangedSubview(summaryLabel)
        configure(noteLabel, style: .footnote, color: .secondaryLabel)
        header.addArrangedSubview(noteLabel)
        actions.axis = .horizontal
        actions.spacing = 10
        actions.alignment = .center
        [playButton, saveButton, changeButton, UIView()].forEach(actions.addArrangedSubview)
        header.addArrangedSubview(actions)
    }

    /// The sentence field: it grows with what is typed, and its hint wraps instead of being cut off in the
    /// languages where it runs long. The hint sits beside the text view, not inside it, so it can hold the box
    /// open to its own height.
    private func buildField() {
        inputBox.backgroundColor = .secondarySystemBackground
        inputBox.layer.cornerRadius = 12
        inputBox.layer.cornerCurve = .continuous

        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.backgroundColor = .clear
        field.isScrollEnabled = false
        field.textContainerInset = UIEdgeInsets(top: Self.fieldInset, left: Self.fieldInset, bottom: Self.fieldInset, right: Self.fieldInset)
        field.textContainer.lineFragmentPadding = 0
        field.returnKeyType = .go
        field.enablesReturnKeyAutomatically = true
        field.delegate = self
        field.accessibilityLabel = PlaylistMakerCopy.title
        field.accessibilityHint = PlaylistMakerCopy.placeholder

        configure(placeholderLabel, style: .body, color: .placeholderText)
        placeholderLabel.text = PlaylistMakerCopy.placeholder
        placeholderLabel.isAccessibilityElement = false

        for view in [placeholderLabel, field] {
            view.translatesAutoresizingMaskIntoConstraints = false
            inputBox.addSubview(view)
        }
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: inputBox.topAnchor),
            field.leadingAnchor.constraint(equalTo: inputBox.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: inputBox.trailingAnchor),
            field.bottomAnchor.constraint(equalTo: inputBox.bottomAnchor),
            placeholderLabel.topAnchor.constraint(equalTo: inputBox.topAnchor, constant: Self.fieldInset),
            placeholderLabel.leadingAnchor.constraint(equalTo: inputBox.leadingAnchor, constant: Self.fieldInset),
            placeholderLabel.trailingAnchor.constraint(equalTo: inputBox.trailingAnchor, constant: -Self.fieldInset),
            placeholderLabel.bottomAnchor.constraint(lessThanOrEqualTo: inputBox.bottomAnchor, constant: -Self.fieldInset),
        ])
    }

    /// Puts `request` in the field and makes its playlist.
    private func ask(_ request: String) {
        field.text = request
        requestChanged()
        makeTapped()
    }

    /// Shows the hint only while nothing is typed, and lets the header follow the field's new height.
    private func requestChanged() {
        placeholderLabel.isHidden = !field.text.isEmpty
        updateMakeButton()
        view.setNeedsLayout()
    }

    /// A table header is not laid out by Auto Layout, so its height is measured for the table's width each time
    /// the content or the width changes.
    private func fitHeader() {
        let width = table.bounds.width
        guard width > 0 else { return }
        let height = header.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        ).height
        guard abs(header.frame.height - height) > 0.5 || abs(header.frame.width - width) > 0.5 else { return }
        header.frame = CGRect(x: 0, y: 0, width: width, height: height)
        table.tableHeaderView = header
    }

    private func render() {
        guard isViewLoaded else { return }
        var isAsking = false
        var step: PlaylistMakerStep?
        var draft: PlaylistDraft?
        var failure: PlaylistMakerFailure?
        switch phase {
        case .asking: isAsking = true
        case .working(let current): step = current
        case .made(let made): draft = made
        case .failed(let reason): failure = reason
        }
        examples.isHidden = !(isAsking || failure?.invitesAnotherRequest == true)
        explanationLabel.isHidden = draft != nil
        statusRow.isHidden = step == nil
        statusLabel.text = step.map(PlaylistMakerCopy.step)
        field.isEditable = step == nil
        failureLabel.isHidden = failure == nil
        failureLabel.text = failure.map(PlaylistMakerCopy.failure)
        showAction(for: failure)
        [nameLabel, summaryLabel, actions].forEach { $0.isHidden = draft == nil }
        nameLabel.text = draft?.title
        summaryLabel.text = draft.map { PlaylistMakerCopy.summary(songs: $0.tracks.count, seconds: $0.seconds) }
        noteLabel.text = draft?.note
        noteLabel.isHidden = draft?.note.isEmpty ?? true
        saveButton.configuration?.title = isSaved ? PlaylistMakerCopy.saved : PlaylistMakerCopy.save
        saveButton.isEnabled = !isSaved
        style(makeButton, filled: draft == nil)
        updateMakeButton()
        table.reloadData()
        view.setNeedsLayout()
        if let draft {
            UIAccessibility.post(notification: .screenChanged, argument: nameLabel)
            MidgarLog.info("Showing a made playlist of \(draft.tracks.count) songs", category: .ui)
        } else if failure != nil {
            UIAccessibility.post(notification: .layoutChanged, argument: failureLabel)
        }
    }

    private func showAction(for failure: PlaylistMakerFailure?) {
        switch failure {
        case .needsEntitlement:
            failureButton.configuration?.title = PlaylistMakerCopy.seePlans
            failureAction = { [weak self] in
                guard let self else { return }
                PaywallViewController.presentSheet(from: self)
            }
        case .unreachable, .unavailable:
            failureButton.configuration?.title = PlaylistMakerCopy.tryAgain
            failureAction = { [weak self] in self?.makeTapped() }
        case .emptyLibrary, .quotaReached, .nothingFits, .declined, nil:
            failureAction = nil
        }
        failureButton.superview?.isHidden = failureAction == nil
    }

    private func updateMakeButton() {
        var isWorking = false
        if case .working = phase { isWorking = true }
        makeButton.isEnabled = !isWorking && !request.isEmpty
    }

    private var request: String {
        String((field.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(PlaylistMakerService.longestRequest))
    }

    private func makeTapped() {
        let request = request
        guard !request.isEmpty else { return }
        feedback.impactOccurred()
        field.resignFirstResponder()
        isSaved = false
        run { service, progress in await service.make(request, progress: progress) }
    }

    private func changeTapped() {
        guard case .made(let draft) = phase else { return }
        feedback.impactOccurred()
        let alert = UIAlertController(title: PlaylistMakerCopy.changeIt, message: nil, preferredStyle: .alert)
        alert.addTextField { $0.placeholder = PlaylistMakerCopy.changePlaceholder }
        alert.addAction(UIAlertAction(title: PlaylistMakerCopy.cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: PlaylistMakerCopy.change, style: .default) { [weak self, weak alert] _ in
            let instruction = (alert?.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let self, !instruction.isEmpty else { return }
            isSaved = false
            run { service, progress in await service.change(draft, to: instruction, progress: progress) }
        })
        present(alert, animated: true)
    }

    /// Runs one making or changing of a playlist, showing each step, and shows what came back.
    private func run(
        _ job: @escaping @Sendable (PlaylistMakerService, @escaping @Sendable (PlaylistMakerStep) -> Void) async -> Result<PlaylistDraft, PlaylistMakerFailure>
    ) {
        work?.cancel()
        phase = .working(.readingLibrary)
        let service = service
        let progress: @Sendable (PlaylistMakerStep) -> Void = { [weak self] step in
            Task { @MainActor [weak self] in
                guard let self, case .working = self.phase else { return }
                self.phase = .working(step)
            }
        }
        work = Task { [weak self] in
            let result = await job(service, progress)
            guard !Task.isCancelled, let self else { return }
            switch result {
            case .success(let draft):
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                phase = .made(draft)
            case .failure(let failure):
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                phase = .failed(failure)
            }
        }
    }

    private func playTapped() {
        guard case .made(let draft) = phase else { return }
        feedback.impactOccurred()
        AudioPlayer.shared.play(draft.tracks, startingAt: 0)
        dismiss(animated: true)
    }

    private func saveTapped() {
        guard case .made(let draft) = phase, !isSaved else { return }
        do {
            let playlist = try service.save(draft, path: TrackContextMenu.relativePath(for:))
            isSaved = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            NotificationCenter.default.post(name: Self.didSave, object: nil)
            ToastView.show(PlaylistMakerCopy.savedAs(playlist.name), in: view, style: .success)
            render()
        } catch {
            MidgarLog.error("Saving a made playlist failed: \(error.localizedDescription)", category: .database)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            ToastView.show(PlaylistMakerCopy.saveFailed, in: view, style: .error)
        }
    }

    /// Posted when a made playlist was saved, so lists of playlists read the database again.
    static let didSave = Notification.Name("PlaylistMakerDidSave")

    func textViewDidChange(_ textView: UITextView) {
        requestChanged()
    }

    /// Return makes the playlist: a request is one sentence, never several lines.
    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard text == "\n" else { return true }
        makeTapped()
        return false
    }

    private var tracks: [Track] {
        if case .made(let draft) = phase { return draft.tracks }
        return []
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        tracks.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: Self.cell, for: indexPath)
        let track = tracks[indexPath.row]
        var content = UIListContentConfiguration.subtitleCell()
        content.text = track.title
        content.secondaryText = "\(track.artist) · \(Self.clock(track.duration))"
        content.secondaryTextProperties.color = .secondaryLabel
        content.imageProperties.maximumSize = Self.artworkSize
        content.imageProperties.reservedLayoutSize = Self.artworkSize
        content.imageProperties.cornerRadius = 6
        content.directionalLayoutMargins.leading = Self.padding
        content.directionalLayoutMargins.trailing = Self.padding
        if let cached = AlbumArtworkCache.shared.thumbnail(forAlbum: track.albumTitle, artist: track.artist) {
            content.image = cached
        } else {
            content.image = UIImage(systemName: "music.note")
            content.imageProperties.tintColor = .tertiaryLabel
            loadArtwork(of: track, into: tableView)
        }
        cell.contentConfiguration = content
        cell.selectionStyle = .default
        return cell
    }

    /// Fetches a row's album cover and, when it arrives, shows it on whichever row holds that song by then.
    private func loadArtwork(of track: Track, into tableView: UITableView) {
        AlbumArtworkCache.shared.loadThumbnail(forAlbum: track.albumTitle, artist: track.artist) { [weak self, weak tableView] image in
            guard let self, let tableView, let image,
                  let row = tracks.firstIndex(where: { $0.fileURL == track.fileURL }),
                  let cell = tableView.cellForRow(at: IndexPath(row: row, section: 0)),
                  var content = cell.contentConfiguration as? UIListContentConfiguration else { return }
            content.image = image
            content.imageProperties.tintColor = nil
            cell.contentConfiguration = content
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        feedback.impactOccurred()
        AudioPlayer.shared.play(tracks, startingAt: indexPath.row)
        dismiss(animated: true)
    }

    private static func clock(_ duration: TimeInterval) -> String {
        let seconds = Int(duration.rounded())
        return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
    }

    private func row(_ button: UIButton) -> UIStackView {
        let row = UIStackView(arrangedSubviews: [button, UIView()])
        row.axis = .horizontal
        return row
    }

    private func button(_ title: String, filled: Bool, action: @escaping () -> Void) -> UIButton {
        let button = UIButton(configuration: .plain(), primaryAction: UIAction { _ in action() })
        button.configuration?.title = title
        style(button, filled: filled)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        return button
    }

    /// Gives a button the filled look of the one thing to do next, or the quiet look of the rest, keeping its words.
    private func style(_ button: UIButton, filled: Bool) {
        var config = filled ? UIButton.Configuration.filled() : UIButton.Configuration.bordered()
        config.cornerStyle = .capsule
        config.title = button.configuration?.title
        button.configuration = config
    }

    private func configure(_ label: UILabel, style: UIFont.TextStyle, color: UIColor, weight: UIFont.Weight? = nil) {
        if let weight {
            let base = UIFont.preferredFont(forTextStyle: style)
            label.font = UIFontMetrics(forTextStyle: style).scaledFont(for: .systemFont(ofSize: base.pointSize, weight: weight))
        } else {
            label.font = .preferredFont(forTextStyle: style)
        }
        label.adjustsFontForContentSizeCategory = true
        label.textColor = color
        label.numberOfLines = 0
    }
}
