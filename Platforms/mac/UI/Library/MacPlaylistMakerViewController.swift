import AppKit
import FlaccyCore
import MidgarCore

/// Make a Playlist on the Mac: a sentence, then the playlist made from the person's own library, to play, save as
/// an ordinary playlist or change with another sentence. Shown as a sheet on the main window.
final class MacPlaylistMakerViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {

    private enum Phase {
        case asking
        case working(PlaylistMakerStep)
        case made(PlaylistDraft)
        case failed(PlaylistMakerFailure)
    }

    private static let contentWidth: CGFloat = 520
    private static let padding: CGFloat = 20
    private static let listHeight: CGFloat = 280
    private static let titleColumn = NSUserInterfaceItemIdentifier("title")
    private static let artistColumn = NSUserInterfaceItemIdentifier("artist")
    private static let timeColumn = NSUserInterfaceItemIdentifier("time")

    private let service: PlaylistMakerService
    private let stack = NSStackView()
    private let field = NSTextField()
    private let makeButton = NSButton(title: PlaylistMakerCopy.make, target: nil, action: nil)
    private let examples = NSStackView()
    private let explanationLabel = NSTextField(wrappingLabelWithString: PlaylistMakerCopy.explanation)
    private let statusRow = NSStackView()
    private let spinner = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")
    private let failureLabel = NSTextField(wrappingLabelWithString: "")
    private let failureButton = NSButton(title: "", target: nil, action: nil)
    private let nameLabel = NSTextField(labelWithString: "")
    private let summaryLabel = NSTextField(labelWithString: "")
    private let noteLabel = NSTextField(wrappingLabelWithString: "")
    private let table = NSTableView()
    private let scrollView = NSScrollView()
    private let playButton = NSButton(title: PlaylistMakerCopy.play, target: nil, action: nil)
    private let saveButton = NSButton(title: PlaylistMakerCopy.save, target: nil, action: nil)
    private let changeButton = NSButton(title: PlaylistMakerCopy.changeIt, target: nil, action: nil)
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

    override func loadView() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: Self.padding, left: Self.padding, bottom: Self.padding, right: Self.padding)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        buildContent()
        render()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(field)
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        work?.cancel()
    }

    private var textWidth: CGFloat { Self.contentWidth - 2 * Self.padding }

    private func buildContent() {
        let title = NSTextField(labelWithString: PlaylistMakerCopy.title)
        title.font = .systemFont(ofSize: 17, weight: .bold)
        stack.addArrangedSubview(title)

        field.placeholderString = PlaylistMakerCopy.placeholder
        field.font = .systemFont(ofSize: 13.5)
        field.delegate = self
        field.target = self
        field.action = #selector(makeTapped)
        field.setAccessibilityLabel(PlaylistMakerCopy.title)
        makeButton.bezelStyle = .push
        makeButton.keyEquivalent = "\r"
        makeButton.target = self
        makeButton.action = #selector(makeTapped)
        makeButton.setContentHuggingPriority(.required, for: .horizontal)
        let ask = NSStackView(views: [field, makeButton])
        ask.orientation = .horizontal
        ask.spacing = 8
        stack.addArrangedSubview(ask)
        ask.widthAnchor.constraint(equalToConstant: textWidth).isActive = true

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        statusLabel.font = .systemFont(ofSize: 12.5)
        statusLabel.textColor = .secondaryLabelColor
        statusRow.orientation = .horizontal
        statusRow.spacing = 8
        statusRow.addArrangedSubview(spinner)
        statusRow.addArrangedSubview(statusLabel)
        stack.addArrangedSubview(statusRow)

        style(failureLabel, size: 12.5, color: .labelColor)
        stack.addArrangedSubview(failureLabel)
        failureButton.bezelStyle = .push
        failureButton.target = self
        failureButton.action = #selector(runFailureAction)
        stack.addArrangedSubview(failureButton)

        examples.orientation = .vertical
        examples.alignment = .leading
        examples.spacing = 6
        for example in PlaylistMakerCopy.examples {
            let button = ClosureButton(title: example) { [weak self] in
                self?.field.stringValue = example
                self?.makeTapped()
            }
            button.isBordered = false
            button.attributedTitle = NSAttributedString(
                string: example, attributes: [.foregroundColor: NSColor.linkColor, .font: NSFont.systemFont(ofSize: 12.5)])
            examples.addArrangedSubview(button)
        }
        stack.addArrangedSubview(examples)
        style(explanationLabel, size: 11.5, color: .secondaryLabelColor)
        stack.addArrangedSubview(explanationLabel)

        nameLabel.font = .systemFont(ofSize: 20, weight: .bold)
        nameLabel.lineBreakMode = .byTruncatingTail
        stack.addArrangedSubview(nameLabel)
        stack.setCustomSpacing(2, after: nameLabel)
        summaryLabel.font = .systemFont(ofSize: 12.5)
        summaryLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(summaryLabel)
        style(noteLabel, size: 11.5, color: .secondaryLabelColor)
        stack.addArrangedSubview(noteLabel)
        buildTable()

        for (button, action) in [(playButton, #selector(playTapped)), (saveButton, #selector(saveTapped)), (changeButton, #selector(changeTapped))] {
            button.bezelStyle = .push
            button.target = self
            button.action = action
        }
        let close = NSButton(title: String(localized: "Close"), target: self, action: #selector(closeTapped))
        close.bezelStyle = .push
        close.keyEquivalent = "\u{1b}"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let footer = NSStackView(views: [spacer, close, changeButton, saveButton, playButton])
        footer.orientation = .horizontal
        footer.spacing = 8
        stack.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalToConstant: textWidth).isActive = true
    }

    private func buildTable() {
        for (identifier, width) in [(Self.titleColumn, 230.0), (Self.artistColumn, 160.0), (Self.timeColumn, 48.0)] {
            let column = NSTableColumn(identifier: identifier)
            column.width = width
            column.minWidth = identifier == Self.titleColumn ? 120 : width
            column.resizingMask = identifier == Self.titleColumn ? .autoresizingMask : []
            table.addTableColumn(column)
        }
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.headerView = nil
        table.rowHeight = 24
        table.usesAlternatingRowBackgroundColors = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(rowDoubleClicked)
        table.setAccessibilityLabel(PlaylistMakerCopy.title)
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.widthAnchor.constraint(equalToConstant: textWidth),
            scrollView.heightAnchor.constraint(equalToConstant: Self.listHeight),
        ])
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
        statusLabel.stringValue = step.map(PlaylistMakerCopy.step) ?? ""
        field.isEnabled = step == nil
        makeButton.isEnabled = step == nil && !request.isEmpty
        failureLabel.isHidden = failure == nil
        failureLabel.stringValue = failure.map(PlaylistMakerCopy.failure) ?? ""
        showAction(for: failure)
        for shown in [nameLabel, summaryLabel, scrollView, playButton, saveButton, changeButton] as [NSView] { shown.isHidden = draft == nil }
        nameLabel.stringValue = draft?.title ?? ""
        summaryLabel.stringValue = draft.map { PlaylistMakerCopy.summary(songs: $0.tracks.count, seconds: $0.seconds) } ?? ""
        noteLabel.stringValue = draft?.note ?? ""
        noteLabel.isHidden = draft?.note.isEmpty ?? true
        saveButton.title = isSaved ? PlaylistMakerCopy.saved : PlaylistMakerCopy.save
        saveButton.isEnabled = !isSaved
        makeButton.keyEquivalent = draft == nil ? "\r" : ""
        playButton.keyEquivalent = draft == nil ? "" : "\r"
        table.reloadData()
        fitSheet()
    }

    /// A sheet grows with its content by itself but never shrinks, so its size is set to what is shown each time.
    private func fitSheet() {
        view.layoutSubtreeIfNeeded()
        preferredContentSize = view.fittingSize
    }

    private func showAction(for failure: PlaylistMakerFailure?) {
        switch failure {
        case .needsEntitlement:
            failureButton.title = PlaylistMakerCopy.seePlans
            failureAction = { [weak self] in
                self?.closeTapped()
                (NSApp.delegate as? MacAppDelegate)?.presentPaywall()
            }
        case .unreachable, .unavailable:
            failureButton.title = PlaylistMakerCopy.tryAgain
            failureAction = { [weak self] in self?.makeTapped() }
        case .emptyLibrary, .quotaReached, .nothingFits, .declined, nil:
            failureAction = nil
        }
        failureButton.isHidden = failureAction == nil
    }

    private var request: String {
        String(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).prefix(PlaylistMakerService.longestRequest))
    }

    func controlTextDidChange(_ notification: Notification) {
        if case .working = phase { return }
        makeButton.isEnabled = !request.isEmpty
    }

    /// Makes the playlist for `request`, as typing it and pressing Make would.
    func make(_ request: String) {
        field.stringValue = request
        makeTapped()
    }

    /// Whether a playlist or a reason for none is on screen, which the DEBUG capture waits for.
    var hasSettled: Bool {
        switch phase {
        case .made, .failed: true
        case .asking, .working: false
        }
    }

    @objc private func makeTapped() {
        let request = request
        guard !request.isEmpty else { return }
        if case .working = phase { return }
        isSaved = false
        run { service, progress in await service.make(request, progress: progress) }
    }

    @objc private func changeTapped() {
        guard case .made(let draft) = phase, let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = PlaylistMakerCopy.changeIt
        alert.addButton(withTitle: PlaylistMakerCopy.change)
        alert.addButton(withTitle: PlaylistMakerCopy.cancel)
        let instruction = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        instruction.placeholderString = PlaylistMakerCopy.changePlaceholder
        alert.accessoryView = instruction
        alert.window.initialFirstResponder = instruction
        alert.beginSheetModal(for: window) { [weak self] response in
            let asked = instruction.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let self, response == .alertFirstButtonReturn, !asked.isEmpty else { return }
            isSaved = false
            run { service, progress in await service.change(draft, to: asked, progress: progress) }
        }
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
            case .success(let draft): phase = .made(draft)
            case .failure(let failure): phase = .failed(failure)
            }
        }
    }

    private var tracks: [Track] {
        if case .made(let draft) = phase { return draft.tracks }
        return []
    }

    @objc private func playTapped() {
        guard !tracks.isEmpty else { return }
        AudioPlayer.shared.play(tracks, startingAt: 0)
        closeTapped()
    }

    @objc private func rowDoubleClicked() {
        guard tracks.indices.contains(table.clickedRow) else { return }
        AudioPlayer.shared.play(tracks, startingAt: table.clickedRow)
        closeTapped()
    }

    @objc private func saveTapped() {
        guard case .made(let draft) = phase, !isSaved else { return }
        do {
            let playlist = try service.save(draft) { LibraryPathResolver.relativePath(for: $0.fileURL) }
            isSaved = true
            NotificationCenter.default.post(name: .flaccyPlaylistsDidChange, object: nil)
            MidgarLog.info("Saved a made playlist as \(playlist.name)", category: .database)
            render()
        } catch {
            MidgarLog.error("Saving a made playlist failed: \(error.localizedDescription)", category: .database)
            failureLabel.stringValue = PlaylistMakerCopy.saveFailed
            failureLabel.isHidden = false
        }
    }

    @objc private func runFailureAction() {
        failureAction?()
    }

    @objc private func closeTapped() {
        if let presenter = presentingViewController {
            presenter.dismiss(self)
        } else {
            view.window?.close()
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        tracks.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, tracks.indices.contains(row) else { return nil }
        let track = tracks[row]
        let cell = (tableView.makeView(withIdentifier: tableColumn.identifier, owner: self) as? NSTextField) ?? {
            let label = NSTextField(labelWithString: "")
            label.identifier = tableColumn.identifier
            label.lineBreakMode = .byTruncatingTail
            label.font = .systemFont(ofSize: 12.5)
            return label
        }()
        switch tableColumn.identifier {
        case Self.titleColumn:
            cell.stringValue = track.title
            cell.textColor = .labelColor
        case Self.artistColumn:
            cell.stringValue = track.artist
            cell.textColor = .secondaryLabelColor
        default:
            let seconds = Int(track.duration.rounded())
            cell.stringValue = "\(seconds / 60):" + String(format: "%02d", seconds % 60)
            cell.textColor = .secondaryLabelColor
            cell.alignment = .right
        }
        return cell
    }

    private func style(_ label: NSTextField, size: CGFloat, color: NSColor) {
        label.font = .systemFont(ofSize: size)
        label.textColor = color
        label.preferredMaxLayoutWidth = textWidth
        label.isSelectable = false
    }
}

/// A button that runs a closure, for rows of buttons built in a loop.
private final class ClosureButton: NSButton {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        self.title = title
        target = self
        action = #selector(run)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    @objc private func run() {
        handler()
    }
}
