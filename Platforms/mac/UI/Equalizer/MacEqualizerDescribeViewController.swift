import AppKit
import FlaccyCore
import MidgarCore

/// Describe the Sound on the Mac: a sentence about how the music should sound, then the curve made for it, heard on
/// what is playing before anything is kept, with what each band is for. Another sentence changes the curve on
/// screen. Shown as a sheet on the equalizer window.
final class MacEqualizerDescribeViewController: NSViewController, NSTextFieldDelegate {

    private enum Phase {
        case asking
        case shaping
        case made
        case failed(EqualizerDescriptionFailure)
    }

    private static let contentWidth: CGFloat = 520
    private static let padding: CGFloat = 22
    private static let dotSize: CGFloat = 8

    var onFinish: (() -> Void)?

    private let engine = EqualizerEngine.shared
    private let service: EqualizerDescriptionService
    private let accent: NSColor
    private let stack = NSStackView()
    private let field = NSTextField()
    private let shapeButton = NSButton(title: EqualizerDescribeCopy.shape, target: nil, action: nil)
    private let statusRow = NSStackView()
    private let spinner = NSProgressIndicator()
    private let failureLabel = NSTextField(wrappingLabelWithString: "")
    private let failureButton = NSButton(title: "", target: nil, action: nil)
    private let examples = NSStackView()
    private let explanationLabel = NSTextField(wrappingLabelWithString: EqualizerDescribeCopy.explanation)
    private let nameLabel = NSTextField(labelWithString: "")
    private let noteLabel = NSTextField(wrappingLabelWithString: "")
    private let preview = MacCurveThumbnailView()
    private let hearCheckbox = NSButton(checkboxWithTitle: EqualizerDescribeCopy.hearIt, target: nil, action: nil)
    private let hearingLabel = NSTextField(wrappingLabelWithString: "")
    private let reasons = NSStackView()
    private let addButton = NSButton(title: EqualizerDescribeCopy.addToPresets, target: nil, action: nil)
    private let useButton = NSButton(title: EqualizerDescribeCopy.addAndUse, target: nil, action: nil)

    private var failureAction: (() -> Void)?
    private var work: Task<Void, Never>?
    private var shown: DescribedEqualizer?
    private var isHearing = false
    private var phase: Phase = .asking {
        didSet { render() }
    }

    init(accent: NSColor, service: EqualizerDescriptionService = .shared) {
        self.accent = accent
        self.service = service
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

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
        NotificationCenter.default.addObserver(self, selector: #selector(playbackChanged), name: AudioPlayer.playbackStateDidChange, object: nil)
        render()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(field)
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        work?.cancel()
        stopHearing()
    }

    /// Shapes the curve for `sentence`, as typing it and pressing Shape It would.
    func ask(_ sentence: String) {
        loadViewIfNeeded()
        field.stringValue = sentence
        shapeTapped()
    }

    /// Whether a curve or a reason for none is on screen, which the DEBUG capture waits for.
    var hasSettled: Bool {
        switch phase {
        case .made, .failed: true
        case .asking, .shaping: false
        }
    }

    private var textWidth: CGFloat { Self.contentWidth - 2 * Self.padding }

    // MARK: Layout

    private func buildContent() {
        let title = NSTextField(labelWithString: EqualizerDescribeCopy.title)
        title.font = .systemFont(ofSize: 17, weight: .bold)
        stack.addArrangedSubview(title)

        field.placeholderString = EqualizerDescribeCopy.placeholder
        field.font = .systemFont(ofSize: 13.5)
        field.delegate = self
        field.target = self
        field.action = #selector(shapeTapped)
        field.setAccessibilityLabel(EqualizerDescribeCopy.title)
        shapeButton.bezelStyle = .push
        shapeButton.keyEquivalent = "\r"
        shapeButton.target = self
        shapeButton.action = #selector(shapeTapped)
        shapeButton.setContentHuggingPriority(.required, for: .horizontal)
        let ask = NSStackView(views: [field, shapeButton])
        ask.orientation = .horizontal
        ask.spacing = 8
        stack.addArrangedSubview(ask)
        ask.widthAnchor.constraint(equalToConstant: textWidth).isActive = true

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        let statusLabel = NSTextField(labelWithString: EqualizerDescribeCopy.shaping)
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

        buildResult()

        examples.orientation = .vertical
        examples.alignment = .leading
        examples.spacing = 6
        for (index, example) in EqualizerDescribeCopy.examples.enumerated() {
            let button = NSButton(title: example, target: self, action: #selector(exampleTapped(_:)))
            button.tag = index
            button.isBordered = false
            button.attributedTitle = NSAttributedString(
                string: example, attributes: [.foregroundColor: NSColor.linkColor, .font: NSFont.systemFont(ofSize: 12.5)])
            examples.addArrangedSubview(button)
        }
        stack.addArrangedSubview(examples)
        style(explanationLabel, size: 11.5, color: .secondaryLabelColor)
        stack.addArrangedSubview(explanationLabel)

        for (button, action) in [(addButton, #selector(addOnly)), (useButton, #selector(addAndUse))] {
            button.bezelStyle = .push
            button.target = self
            button.action = action
        }
        let close = NSButton(title: String(localized: "Close"), target: self, action: #selector(closeTapped))
        close.bezelStyle = .push
        close.keyEquivalent = "\u{1b}"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let footer = NSStackView(views: [close, spacer, addButton, useButton])
        footer.orientation = .horizontal
        footer.spacing = 8
        stack.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalToConstant: textWidth).isActive = true
    }

    private func buildResult() {
        nameLabel.font = .systemFont(ofSize: 20, weight: .bold)
        nameLabel.lineBreakMode = .byTruncatingTail
        stack.addArrangedSubview(nameLabel)
        stack.setCustomSpacing(4, after: nameLabel)
        style(noteLabel, size: 11.5, color: EqualizerTheme.caution)
        stack.addArrangedSubview(noteLabel)

        preview.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(preview)
        NSLayoutConstraint.activate([
            preview.widthAnchor.constraint(equalToConstant: textWidth),
            preview.heightAnchor.constraint(equalToConstant: 96),
        ])

        hearCheckbox.target = self
        hearCheckbox.action = #selector(hearToggled)
        stack.addArrangedSubview(hearCheckbox)
        stack.setCustomSpacing(2, after: hearCheckbox)
        style(hearingLabel, size: 11.5, color: .secondaryLabelColor)
        stack.addArrangedSubview(hearingLabel)

        reasons.orientation = .vertical
        reasons.alignment = .leading
        reasons.spacing = 9
        stack.addArrangedSubview(reasons)
    }

    /// One band of the made curve: a dot in the band's colour, what the band is and what it is for.
    private func reasonRow(band: EqualizerBand, reason: String, index: Int) -> NSView {
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = EqualizerTheme.bandColor(index).cgColor
        dot.layer?.cornerRadius = Self.dotSize / 2
        dot.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: EqualizerDescribeCopy.bandTitle(band))
        title.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        let body = NSTextField(wrappingLabelWithString: reason)
        style(body, size: 12.5, color: .secondaryLabelColor, width: textWidth - Self.dotSize - 10)
        body.isHidden = reason.isEmpty
        let texts = NSStackView(views: [title, body])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 1
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        texts.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(dot)
        row.addSubview(texts)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: Self.dotSize),
            dot.heightAnchor.constraint(equalToConstant: Self.dotSize),
            dot.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            dot.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            texts.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 10),
            texts.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            texts.topAnchor.constraint(equalTo: row.topAnchor),
            texts.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            row.widthAnchor.constraint(equalToConstant: textWidth),
        ])
        row.setAccessibilityElement(true)
        row.setAccessibilityRole(.staticText)
        row.setAccessibilityLabel([title.stringValue, reason].filter { !$0.isEmpty }.joined(separator: ". "))
        return row
    }

    // MARK: State

    private func render() {
        guard isViewLoaded else { return }
        var isAsking = false
        var isShaping = false
        var failure: EqualizerDescriptionFailure?
        switch phase {
        case .asking: isAsking = true
        case .shaping: isShaping = true
        case .made: break
        case .failed(let reason): failure = reason
        }
        field.placeholderString = shown == nil ? EqualizerDescribeCopy.placeholder : EqualizerDescribeCopy.changePlaceholder
        field.isEnabled = !isShaping
        shapeButton.isEnabled = !isShaping && !sentence.isEmpty
        statusRow.isHidden = !isShaping
        failureLabel.isHidden = failure == nil
        failureLabel.stringValue = failure.map(EqualizerDescribeCopy.failure) ?? ""
        showAction(for: failure)
        examples.isHidden = !(isAsking || failure?.invitesAnotherSentence == true) || shown != nil
        explanationLabel.isHidden = shown != nil
        for view in [nameLabel, preview, hearCheckbox, hearingLabel, reasons, addButton, useButton] as [NSView] { view.isHidden = shown == nil }
        noteLabel.isHidden = shown?.note.isEmpty ?? true
        shapeButton.keyEquivalent = shown == nil || !sentence.isEmpty ? "\r" : ""
        useButton.keyEquivalent = shown != nil && sentence.isEmpty ? "\r" : ""
        renderHearing()
        fitSheet()
    }

    private func show(_ described: DescribedEqualizer) {
        shown = described
        nameLabel.stringValue = described.profile.name
        noteLabel.stringValue = described.note
        preview.set(bands: described.profile.resolvedBands(), accent: accent, isEnabled: true)
        reasons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, band) in described.profile.bands.enumerated() {
            let reason = index < described.reasons.count ? described.reasons[index] : ""
            reasons.addArrangedSubview(reasonRow(band: band, reason: reason, index: index))
        }
    }

    private func renderHearing() {
        hearCheckbox.state = isHearing ? .on : .off
        hearingLabel.stringValue = EqualizerDescribeCopy.hearing(isPlaying: AudioPlayer.shared.isPlaying, isHearing: isHearing)
    }

    /// A sheet grows with its content by itself but never shrinks, so its size is set to what is shown each time.
    private func fitSheet() {
        view.layoutSubtreeIfNeeded()
        preferredContentSize = view.fittingSize
    }

    private func showAction(for failure: EqualizerDescriptionFailure?) {
        switch failure {
        case .needsEntitlement:
            failureButton.title = PlaylistMakerCopy.seePlans
            failureAction = { [weak self] in
                self?.closeTapped()
                (NSApp.delegate as? MacAppDelegate)?.presentPaywall()
            }
        case .unreachable, .unavailable:
            failureButton.title = PlaylistMakerCopy.tryAgain
            failureAction = { [weak self] in self?.shapeTapped() }
        case .quotaReached, .nothingToShape, nil:
            failureAction = nil
        }
        failureButton.isHidden = failureAction == nil
    }

    private var sentence: String {
        String(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).prefix(EqualizerDescription.longestRequest))
    }

    func controlTextDidChange(_ notification: Notification) {
        if case .shaping = phase { return }
        render()
    }

    // MARK: Actions

    @objc private func shapeTapped() {
        let sentence = sentence
        guard !sentence.isEmpty else { return }
        if case .shaping = phase { return }
        work?.cancel()
        let starting = shown?.profile ?? engine.profileInForce
        let output = engine.outputKind
        let service = service
        phase = .shaping
        work = Task { [weak self] in
            let result = await service.curve(for: sentence, output: output, inForce: starting)
            guard !Task.isCancelled, let self else { return }
            switch result {
            case .success(let described):
                field.stringValue = ""
                show(described)
                startHearing()
                phase = .made
                MidgarLog.info("Showing a described curve of \(described.profile.bands.count) bands", category: .ui)
            case .failure(let failure):
                phase = .failed(failure)
            }
        }
    }

    @objc private func exampleTapped(_ sender: NSButton) {
        let examples = EqualizerDescribeCopy.examples
        guard examples.indices.contains(sender.tag) else { return }
        ask(examples[sender.tag])
    }

    @objc private func hearToggled() {
        hearCheckbox.state == .on ? startHearing() : stopHearing()
        renderHearing()
    }

    private func startHearing() {
        guard let shown else { return }
        isHearing = true
        engine.beginAudition(shown.profile)
    }

    private func stopHearing() {
        guard isHearing else { return }
        isHearing = false
        engine.endAudition()
    }

    @objc private func addOnly() {
        keep(use: false)
    }

    @objc private func addAndUse() {
        keep(use: true)
    }

    private func keep(use: Bool) {
        guard let shown else { return }
        stopHearing()
        let kept = engine.keep(shown.profile, use: use)
        MidgarLog.info("Kept a described curve as \"\(kept.name)\", in use: \(use)", category: .ui)
        let window = presentingViewController?.view.window
        onFinish?()
        dismiss(nil)
        if let window { MacToast.show(EqualizerDescribeCopy.added(kept.name), in: window) }
    }

    @objc private func runFailureAction() {
        failureAction?()
    }

    @objc private func closeTapped() {
        dismiss(nil)
    }

    @objc private func playbackChanged() {
        guard isViewLoaded else { return }
        renderHearing()
    }

    private func style(_ label: NSTextField, size: CGFloat, color: NSColor, width: CGFloat? = nil) {
        label.font = .systemFont(ofSize: size)
        label.textColor = color
        label.preferredMaxLayoutWidth = width ?? textWidth
    }
}
