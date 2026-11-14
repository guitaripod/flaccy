import FlaccyCore
import MidgarCore
import UIKit

/// Describe the Sound on iPhone and iPad: a sentence about how the music should sound, then the curve made for
/// it, heard on what is playing before anything is kept, with what each band is for. Another sentence changes the
/// curve on screen.
final class EqualizerDescribeViewController: UIViewController, UITextViewDelegate {

    private enum Phase {
        case asking
        case shaping
        case made(DescribedEqualizer)
        case failed(EqualizerDescriptionFailure)
    }

    private static let fieldInset: CGFloat = 14
    private static let dotSize: CGFloat = 8
    private static let gentleSpan = 6.0
    private static let curveInset: CGFloat = 10

    private let engine = EqualizerEngine.shared
    private let service: EqualizerDescriptionService
    private let auditioner = EqualizerAuditioner()
    private let accent: UIColor
    private let feedback = UIImpactFeedbackGenerator(style: .light)

    private let backdrop = AmbientPaletteBackdropView()
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private let inputBox = UIView()
    private let field = UITextView()
    private let placeholderLabel = UILabel()
    private let shapeButton = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let statusLabel = UILabel()
    private let examples = UIStackView()
    private let explanationLabel = UILabel()
    private let failureLabel = UILabel()
    private let failureButton = UIButton(type: .system)
    private let card = UIView()
    private let nameLabel = UILabel()
    private let noteLabel = UILabel()
    private let curveView = UIView()
    private let curveLine = CAShapeLayer()
    private let curveFill = CAShapeLayer()
    private let curveZero = CAShapeLayer()
    private let curveTopLabel = UILabel()
    private let curveBottomLabel = UILabel()
    private let hearSwitch = UISwitch()
    private let hearingLabel = UILabel()
    private let reasons = UIStackView()
    private let addButton = UIButton(type: .system)
    private let useButton = UIButton(type: .system)

    private var failureAction: (() -> Void)?
    private var work: Task<Void, Never>?
    private var phase: Phase = .asking {
        didSet { render() }
    }

    init(accent: UIColor, service: EqualizerDescriptionService = .shared) {
        self.accent = accent
        self.service = service
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        overrideUserInterfaceStyle = .dark
        buildLayout()
        auditioner.didChange = { [weak self] _ in self?.renderHearing() }
        NotificationCenter.default.addObserver(self, selector: #selector(playbackChanged), name: AudioPlayer.playbackStateDidChange, object: nil)
        render()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if case .asking = phase, field.text.isEmpty { field.becomeFirstResponder() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        auditioner.end()
        if isMovingFromParent || isBeingDismissed || navigationController?.isBeingDismissed == true { work?.cancel() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        drawCurve()
    }

    /// Puts `sentence` in the field and shapes its curve, as a tap on an example does.
    func ask(_ sentence: String) {
        loadViewIfNeeded()
        field.text = sentence
        sentenceChanged()
        shapeTapped()
    }

    // MARK: Layout

    private func buildLayout() {
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(backdrop)

        let back = UIButton(type: .system)
        var backConfiguration = UIButton.Configuration.plain()
        backConfiguration.image = UIImage(systemName: "chevron.left", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold))
        backConfiguration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 8)
        back.configuration = backConfiguration
        back.tintColor = accent
        back.accessibilityLabel = String(localized: "Back")
        back.addAction(UIAction { [weak self] _ in self?.navigationController?.popViewController(animated: true) }, for: .touchUpInside)
        let title = UILabel()
        title.text = EqualizerDescribeCopy.title
        title.font = .equalizerRounded(.title1, size: 28, weight: .bold)
        title.adjustsFontForContentSizeCategory = true
        title.adjustsFontSizeToFitWidth = true
        title.minimumScaleFactor = 0.7
        title.textColor = .white
        title.accessibilityTraits = .header
        let header = UIStackView(arrangedSubviews: [back, title])
        header.alignment = .center
        header.spacing = 4
        header.translatesAutoresizingMaskIntoConstraints = false

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
        scroll.keyboardDismissMode = .interactive
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        view.addSubview(header)
        view.addSubview(scroll)

        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: view.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            backdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 30),
            header.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 14),
            header.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -40),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -20),
        ])

        buildField()
        stack.addArrangedSubview(inputBox)
        stack.addArrangedSubview(makeShapeRow())
        configure(failureLabel, style: .callout, size: 15, color: .white)
        stack.addArrangedSubview(failureLabel)
        configure(failureButton, title: "", filled: false)
        failureButton.addAction(UIAction { [weak self] _ in self?.failureAction?() }, for: .touchUpInside)
        stack.addArrangedSubview(leading(failureButton))
        stack.addArrangedSubview(makeCard())
        stack.addArrangedSubview(makeExamples())
        configure(explanationLabel, style: .footnote, size: 13, color: UIColor.white.withAlphaComponent(0.6))
        explanationLabel.text = EqualizerDescribeCopy.explanation
        stack.addArrangedSubview(explanationLabel)
    }

    /// The sentence field: it grows with what is typed, and its hint sits beside the text view, not inside it,
    /// so a long hint wraps and holds the box open to its own height.
    private func buildField() {
        inputBox.backgroundColor = UIColor.white.withAlphaComponent(0.07)
        inputBox.layer.cornerRadius = 18
        inputBox.layer.cornerCurve = .continuous
        inputBox.layer.borderWidth = 1
        inputBox.layer.borderColor = UIColor.white.withAlphaComponent(0.12).cgColor

        field.font = .scaled(.body, size: 17, weight: .regular)
        field.adjustsFontForContentSizeCategory = true
        field.textColor = .white
        field.tintColor = accent
        field.backgroundColor = .clear
        field.isScrollEnabled = false
        field.textContainerInset = UIEdgeInsets(top: Self.fieldInset, left: Self.fieldInset, bottom: Self.fieldInset, right: Self.fieldInset)
        field.textContainer.lineFragmentPadding = 0
        field.returnKeyType = .go
        field.enablesReturnKeyAutomatically = true
        field.delegate = self
        field.accessibilityLabel = EqualizerDescribeCopy.title
        field.accessibilityIdentifier = "equalizer.describe.field"

        configure(placeholderLabel, style: .body, size: 17, color: UIColor.white.withAlphaComponent(0.4))
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

    private func makeShapeRow() -> UIView {
        configure(shapeButton, title: EqualizerDescribeCopy.shape, filled: true)
        shapeButton.accessibilityIdentifier = "equalizer.describe.shape"
        shapeButton.addAction(UIAction { [weak self] _ in self?.shapeTapped() }, for: .touchUpInside)
        spinner.color = .white
        spinner.hidesWhenStopped = true
        configure(statusLabel, style: .subheadline, size: 14, color: UIColor.white.withAlphaComponent(0.7))
        statusLabel.text = EqualizerDescribeCopy.shaping
        let row = UIStackView(arrangedSubviews: [shapeButton, spinner, statusLabel, UIView()])
        row.spacing = 10
        row.alignment = .center
        return row
    }

    private func makeExamples() -> UIView {
        examples.axis = .vertical
        examples.spacing = 8
        examples.alignment = .leading
        for example in EqualizerDescribeCopy.examples {
            let button = UIButton(type: .system)
            var configuration = UIButton.Configuration.plain()
            configuration.title = example
            configuration.baseForegroundColor = .white
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
            configuration.titleLineBreakMode = .byTruncatingTail
            configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var outgoing = incoming
                outgoing.font = UIFont.scaled(.subheadline, size: 15, weight: .medium, maxSize: 20)
                return outgoing
            }
            button.configuration = configuration
            button.addAction(UIAction { [weak self] _ in self?.ask(example) }, for: .touchUpInside)
            examples.addArrangedSubview(LiquidGlass.capsule(hosting: button, height: 42))
        }
        return examples
    }

    private func makeCard() -> UIView {
        card.backgroundColor = UIColor.white.withAlphaComponent(0.06)
        card.layer.cornerRadius = 22
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.layer.borderColor = UIColor.white.withAlphaComponent(0.1).cgColor
        card.accessibilityIdentifier = "equalizer.describe.card"

        nameLabel.font = .equalizerRounded(.title2, size: 22, weight: .bold)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.textColor = .white
        nameLabel.numberOfLines = 0
        nameLabel.accessibilityTraits = .header
        configure(noteLabel, style: .footnote, size: 13, color: EqualizerTheme.caution)

        curveView.backgroundColor = UIColor.black.withAlphaComponent(0.22)
        curveView.layer.cornerRadius = 14
        curveView.layer.masksToBounds = true
        curveView.translatesAutoresizingMaskIntoConstraints = false
        curveView.heightAnchor.constraint(equalToConstant: 110).isActive = true
        curveView.isAccessibilityElement = false
        curveFill.fillColor = accent.withAlphaComponent(0.2).cgColor
        curveLine.fillColor = nil
        curveLine.strokeColor = accent.cgColor
        curveLine.lineWidth = 2.4
        curveLine.lineJoin = .round
        curveZero.strokeColor = UIColor.white.withAlphaComponent(0.16).cgColor
        curveZero.lineWidth = 1
        curveView.layer.addSublayer(curveZero)
        curveView.layer.addSublayer(curveFill)
        curveView.layer.addSublayer(curveLine)
        for label in [curveTopLabel, curveBottomLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
            label.textColor = UIColor.white.withAlphaComponent(0.4)
            label.translatesAutoresizingMaskIntoConstraints = false
            curveView.addSubview(label)
            label.leadingAnchor.constraint(equalTo: curveView.leadingAnchor, constant: 8).isActive = true
        }
        curveTopLabel.topAnchor.constraint(equalTo: curveView.topAnchor, constant: 6).isActive = true
        curveBottomLabel.bottomAnchor.constraint(equalTo: curveView.bottomAnchor, constant: -6).isActive = true

        hearSwitch.onTintColor = accent
        hearSwitch.accessibilityLabel = EqualizerDescribeCopy.hearIt
        hearSwitch.addAction(UIAction { [weak self] _ in self?.hearToggled() }, for: .valueChanged)
        let hearTitle = UILabel()
        configure(hearTitle, style: .body, size: 16, color: .white, weight: .semibold)
        hearTitle.text = EqualizerDescribeCopy.hearIt
        hearTitle.isAccessibilityElement = false
        configure(hearingLabel, style: .footnote, size: 13, color: UIColor.white.withAlphaComponent(0.6))
        let hearTexts = UIStackView(arrangedSubviews: [hearTitle, hearingLabel])
        hearTexts.axis = .vertical
        hearTexts.spacing = 2
        let hearRow = UIStackView(arrangedSubviews: [hearTexts, hearSwitch])
        hearRow.spacing = 12
        hearRow.alignment = .center

        reasons.axis = .vertical
        reasons.spacing = 12

        configure(addButton, title: EqualizerDescribeCopy.addToPresets, filled: false)
        configure(useButton, title: EqualizerDescribeCopy.addAndUse, filled: true)
        useButton.accessibilityIdentifier = "equalizer.describe.use"
        addButton.addAction(UIAction { [weak self] _ in self?.keep(use: false) }, for: .touchUpInside)
        useButton.addAction(UIAction { [weak self] _ in self?.keep(use: true) }, for: .touchUpInside)
        let actions = UIStackView(arrangedSubviews: [useButton, addButton])
        actions.axis = .vertical
        actions.spacing = 8

        let content = UIStackView(arrangedSubviews: [nameLabel, noteLabel, curveView, hearRow, reasons, actions])
        content.axis = .vertical
        content.spacing = 14
        content.setCustomSpacing(6, after: nameLabel)
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
        ])
        return card
    }

    /// One band of the made curve: a dot in the band's colour, what the band is and what it is for.
    private func reasonRow(band: EqualizerBand, reason: String, index: Int) -> UIView {
        let dot = UIView()
        dot.backgroundColor = EqualizerTheme.bandColor(index)
        dot.layer.cornerRadius = Self.dotSize / 2
        dot.translatesAutoresizingMaskIntoConstraints = false
        let dotColumn = UIView()
        dotColumn.addSubview(dot)
        let title = UILabel()
        configure(title, style: .footnote, size: 13, color: .white, weight: .semibold)
        title.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .monospacedDigitSystemFont(ofSize: 13, weight: .semibold))
        title.text = EqualizerDescribeCopy.bandTitle(band)
        let body = UILabel()
        configure(body, style: .subheadline, size: 14.5, color: UIColor.white.withAlphaComponent(0.78))
        body.text = reason
        body.isHidden = reason.isEmpty
        let texts = UIStackView(arrangedSubviews: [title, body])
        texts.axis = .vertical
        texts.spacing = 2
        let row = UIStackView(arrangedSubviews: [dotColumn, texts])
        row.spacing = 10
        row.alignment = .fill
        NSLayoutConstraint.activate([
            dotColumn.widthAnchor.constraint(equalToConstant: Self.dotSize),
            dot.widthAnchor.constraint(equalToConstant: Self.dotSize),
            dot.heightAnchor.constraint(equalToConstant: Self.dotSize),
            dot.leadingAnchor.constraint(equalTo: dotColumn.leadingAnchor),
            dot.centerYAnchor.constraint(equalTo: title.centerYAnchor),
        ])
        row.isAccessibilityElement = true
        row.accessibilityLabel = [title.text, reason].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ". ")
        return row
    }

    // MARK: State

    private func render() {
        guard isViewLoaded else { return }
        var isAsking = false
        var isShaping = false
        var made: DescribedEqualizer?
        var failure: EqualizerDescriptionFailure?
        switch phase {
        case .asking: isAsking = true
        case .shaping: isShaping = true
        case .made(let described): made = described
        case .failed(let reason): failure = reason
        }
        placeholderLabel.text = shownCurve == nil ? EqualizerDescribeCopy.placeholder : EqualizerDescribeCopy.changePlaceholder
        field.isEditable = !isShaping
        isShaping ? spinner.startAnimating() : spinner.stopAnimating()
        statusLabel.isHidden = !isShaping
        failureLabel.isHidden = failure == nil
        failureLabel.text = failure.map(EqualizerDescribeCopy.failure)
        showAction(for: failure)
        card.isHidden = shownCurve == nil
        examples.isHidden = !(isAsking || failure?.invitesAnotherSentence == true) || shownCurve != nil
        explanationLabel.isHidden = shownCurve != nil
        if let made { show(made) }
        updateShapeButton()
        renderHearing()
        view.setNeedsLayout()
        if made != nil {
            UIAccessibility.post(notification: .screenChanged, argument: nameLabel)
        } else if failure != nil {
            UIAccessibility.post(notification: .layoutChanged, argument: failureLabel)
        }
    }

    /// The curve the card shows: the one just made, and while another sentence is being shaped or failed, the one
    /// made before it, which is still what is being heard and what a change starts from.
    private var shownCurve: DescribedEqualizer? {
        if case .made(let described) = phase { return described }
        return lastMade
    }

    private var lastMade: DescribedEqualizer?

    private func show(_ described: DescribedEqualizer) {
        nameLabel.text = described.profile.name
        noteLabel.text = described.note
        noteLabel.isHidden = described.note.isEmpty
        reasons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, band) in described.profile.bands.enumerated() {
            let reason = index < described.reasons.count ? described.reasons[index] : ""
            reasons.addArrangedSubview(reasonRow(band: band, reason: reason, index: index))
        }
        drawCurve()
    }

    private func renderHearing() {
        guard isViewLoaded else { return }
        let isHearing = auditioner.current != nil
        hearSwitch.setOn(isHearing, animated: true)
        hearingLabel.text = EqualizerDescribeCopy.hearing(isPlaying: AudioPlayer.shared.isPlaying, isHearing: isHearing)
        hearSwitch.accessibilityValue = hearingLabel.text
    }

    private func showAction(for failure: EqualizerDescriptionFailure?) {
        switch failure {
        case .needsEntitlement:
            failureButton.configuration?.title = PlaylistMakerCopy.seePlans
            failureAction = { [weak self] in
                guard let self else { return }
                PaywallViewController.presentSheet(from: self)
            }
        case .unreachable, .unavailable:
            failureButton.configuration?.title = PlaylistMakerCopy.tryAgain
            failureAction = { [weak self] in self?.shapeTapped() }
        case .quotaReached, .nothingToShape, nil:
            failureAction = nil
        }
        failureButton.superview?.isHidden = failureAction == nil
    }

    private func updateShapeButton() {
        var isShaping = false
        if case .shaping = phase { isShaping = true }
        shapeButton.isEnabled = !isShaping && !sentence.isEmpty
    }

    private var sentence: String {
        String((field.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(EqualizerDescription.longestRequest))
    }

    private func sentenceChanged() {
        placeholderLabel.isHidden = !field.text.isEmpty
        updateShapeButton()
        view.setNeedsLayout()
    }

    // MARK: Actions

    private func shapeTapped() {
        let sentence = sentence
        guard !sentence.isEmpty else { return }
        feedback.impactOccurred()
        field.resignFirstResponder()
        work?.cancel()
        let starting = shownCurve?.profile ?? engine.profileInForce
        let output = engine.outputKind
        let service = service
        phase = .shaping
        work = Task { [weak self] in
            let result = await service.curve(for: sentence, output: output, inForce: starting)
            guard !Task.isCancelled, let self else { return }
            switch result {
            case .success(let described):
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                lastMade = described
                field.text = ""
                sentenceChanged()
                phase = .made(described)
                auditioner.begin(described.profile)
                MidgarLog.info("Showing a described curve of \(described.profile.bands.count) bands", category: .ui)
            case .failure(let failure):
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                phase = .failed(failure)
            }
        }
    }

    private func hearToggled() {
        guard let described = shownCurve else { return }
        feedback.impactOccurred()
        if hearSwitch.isOn {
            auditioner.begin(described.profile)
        } else {
            auditioner.end()
        }
    }

    private func keep(use: Bool) {
        guard let described = shownCurve else { return }
        auditioner.end()
        let kept = engine.keep(described.profile, use: use)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        MidgarLog.info("Kept a described curve as \"\(kept.name)\", in use: \(use)", category: .ui)
        if let host = navigationController?.view {
            ToastView.show(EqualizerDescribeCopy.added(kept.name), in: host, style: .success)
        }
        navigationController?.popViewController(animated: true)
    }

    @objc private func playbackChanged() {
        renderHearing()
    }

    func textViewDidChange(_ textView: UITextView) {
        sentenceChanged()
    }

    /// Return shapes the curve: a description is one sentence, never several lines.
    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard text == "\n" else { return true }
        shapeTapped()
        return false
    }

    // MARK: Drawing

    /// Draws the made curve on a scale that fits it: a gentle curve fills a ±6 dB plot instead of lying almost
    /// flat in the equalizer's ±12, and the two corner labels say which scale it is.
    private func drawCurve() {
        guard let described = shownCurve, curveView.bounds.width > 0 else { return }
        let rect = curveView.bounds
        let points = BiquadMath.curve(described.profile.resolvedBands(), points: 140)
        let reach = points.map(abs).max() ?? 0
        let span = reach <= Self.gentleSpan - 0.5 ? Self.gentleSpan : EqualizerBand.gainRange.upperBound
        let half = rect.height / 2 - Self.curveInset
        let line = UIBezierPath()
        let fill = UIBezierPath()
        fill.move(to: CGPoint(x: 0, y: rect.midY))
        for (index, decibels) in points.enumerated() {
            let x = rect.width * CGFloat(index) / CGFloat(points.count - 1)
            let y = rect.midY - CGFloat(min(max(decibels, -span), span) / span) * half
            index == 0 ? line.move(to: CGPoint(x: x, y: y)) : line.addLine(to: CGPoint(x: x, y: y))
            fill.addLine(to: CGPoint(x: x, y: y))
        }
        fill.addLine(to: CGPoint(x: rect.width, y: rect.midY))
        fill.close()
        let zero = UIBezierPath()
        zero.move(to: CGPoint(x: 0, y: rect.midY))
        zero.addLine(to: CGPoint(x: rect.width, y: rect.midY))
        curveZero.path = zero.cgPath
        curveLine.path = line.cgPath
        curveFill.path = fill.cgPath
        for layer in [curveZero, curveLine, curveFill] { layer.frame = rect }
        curveTopLabel.text = "+\(Int(span)) dB"
        curveBottomLabel.text = "\u{2212}\(Int(span)) dB"
    }

    #if DEBUG
    /// Scrolls to the end of the made curve's card, for a capture of the buttons under a long list of bands.
    func revealEndForScreenshot() {
        view.layoutIfNeeded()
        let bottom = max(scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom, -scroll.adjustedContentInset.top)
        scroll.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
    }
    #endif

    // MARK: Pieces

    private func leading(_ view: UIView) -> UIStackView {
        let row = UIStackView(arrangedSubviews: [view, UIView()])
        row.axis = .horizontal
        return row
    }

    private func configure(_ button: UIButton, title: String, filled: Bool) {
        var configuration = filled ? UIButton.Configuration.filled() : UIButton.Configuration.tinted()
        configuration.title = title
        configuration.cornerStyle = .capsule
        configuration.baseBackgroundColor = filled ? accent : .white
        configuration.baseForegroundColor = filled ? UIColor(red: 0.09, green: 0.04, blue: 0.08, alpha: 1) : .white
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 13, leading: 18, bottom: 13, trailing: 18)
        configuration.titleLineBreakMode = .byTruncatingTail
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = UIFont.scaled(.body, size: 15, weight: .bold, maxSize: 19)
            return outgoing
        }
        button.configuration = configuration
    }

    private func configure(_ label: UILabel, style: UIFont.TextStyle, size: CGFloat, color: UIColor, weight: UIFont.Weight = .regular) {
        label.font = .scaled(style, size: size, weight: weight)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = color
        label.numberOfLines = 0
    }
}
