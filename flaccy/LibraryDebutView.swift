import FlaccyCore
import UIKit

/// The once-per-library Debut, in three acts on one canvas.
///
/// Act I narrates the bounded disk scan: a determinate hairline and a mosaic
/// that fills with the embedded covers as they are decoded. Act II drops the
/// hairline — the fraction is spent — and counts the durable enrichment job
/// down instead, lighting a tile back up for each album the job repairs. Act III
/// settles the grid and raises the summary card over it.
///
/// The 156 pt ring is deliberately absent: the mosaic *is* Act I's progress, and
/// two indicators for one bounded job is one too many.
final class LibraryDebutView: UIView {

    /// Called when the reader taps *Take me to my music*. The caller is expected
    /// to answer with `morph(to:completion:)` — passing the album grid's
    /// first-screen cell frames from `tileFrames()`, or an empty array for a
    /// plain dissolve — and to remove this view in that completion.
    var onDismiss: (() -> Void)?

    var onShowPaywall: (() -> Void)?

    private enum Metrics {
        static let horizontalInset: CGFloat = 24
        static let hairlineHeight: CGFloat = 3
        static let mosaicMaximumSide: CGFloat = 344
        static let mosaicHeightShare: CGFloat = 0.42
        static let chipGap: CGFloat = 8
        static let cardMaximumWidth: CGFloat = 420
        static let cardRise: CGFloat = 56
        static let cardSpringDuration: TimeInterval = 0.55
        static let cardBounce: CGFloat = 0.15
        static let captionCrossfade: TimeInterval = 0.28
        static let chromeFade: TimeInterval = 0.32
        static let scrimAlpha: CGFloat = 0.42
    }

    private let backdrop = CAGradientLayer()
    private let wordmark = UILabel()
    private let hairline = DebutHairlineView()
    private let countdown = UILabel()
    private let mosaic = LibraryMosaicView()
    private let caption = UILabel()
    private let headline = UILabel()
    private let trialChip = DebutChipView()
    private let headlineRow = UIStackView()
    private let explanation = UILabel()
    private let statsRow = StatsRowView()
    private let entitlementPill = UIButton(configuration: .filled())
    private let contentStack = UIStackView()
    private let scrim = UIView()

    private var card: LibraryDebutSummaryCard?
    private var act: LibraryDebutAct = .indexing
    private var hasAppliedAct = false
    private var lastAnnouncedPhase: LibraryLoadPhase = .idle
    private var lastCaptionTitle: String?
    private var lastJobActivity: EnrichmentJobProgress.Activity = .idle
    private var lastJobScope: EnrichmentScope = .album
    private var isDismissing = false

    private var reduceMotion: Bool { UIAccessibility.isReduceMotionEnabled }

    override init(frame: CGRect) {
        super.init(frame: frame)
        overrideUserInterfaceStyle = .dark
        backgroundColor = UIColor(white: 0.04, alpha: 1)
        layer.insertSublayer(backdrop, at: 0)
        backdrop.colors = [
            UIColor(white: 0.08, alpha: 1).cgColor,
            UIColor(white: 0.02, alpha: 1).cgColor,
        ]
        setupSubviews()
        configureAccessibility()
        applyAct(.indexing, animated: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop.frame = bounds
        CATransaction.commit()
        updateHeadlineAxis()
    }

    private func setupSubviews() {
        wordmark.text = "flaccy"
        wordmark.font = .scaled(.caption1, size: 13, weight: .semibold)
        wordmark.adjustsFontForContentSizeCategory = true
        wordmark.textColor = UIColor.white.withAlphaComponent(0.4)
        wordmark.textAlignment = .center
        wordmark.accessibilityElementsHidden = true

        countdown.font = .scaled(.footnote, size: 13, weight: .medium).monospacedDigits
        countdown.adjustsFontForContentSizeCategory = true
        countdown.textColor = UIColor.white.withAlphaComponent(0.62)
        countdown.textAlignment = .center
        countdown.numberOfLines = 1
        countdown.adjustsFontSizeToFitWidth = true
        countdown.minimumScaleFactor = 0.8
        countdown.accessibilityElementsHidden = true

        caption.font = .scaled(.subheadline, size: 15, weight: .medium)
        caption.adjustsFontForContentSizeCategory = true
        caption.textColor = UIColor.white.withAlphaComponent(0.86)
        caption.textAlignment = .center
        caption.numberOfLines = 1
        caption.lineBreakMode = .byTruncatingTail
        caption.accessibilityElementsHidden = true

        headline.font = .scaled(.title3, size: 20, weight: .semibold)
        headline.adjustsFontForContentSizeCategory = true
        headline.textAlignment = .center
        headline.numberOfLines = 2
        headline.setContentHuggingPriority(.defaultLow, for: .horizontal)

        explanation.font = .preferredFont(forTextStyle: .footnote)
        explanation.adjustsFontForContentSizeCategory = true
        explanation.textColor = .secondaryLabel
        explanation.textAlignment = .center
        explanation.numberOfLines = 3
        explanation.accessibilityElementsHidden = true

        headlineRow.axis = .horizontal
        headlineRow.alignment = .center
        headlineRow.spacing = Metrics.chipGap
        headlineRow.addArrangedSubview(headline)
        headlineRow.addArrangedSubview(trialChip)

        var pill = entitlementPill.configuration ?? .filled()
        pill.title = LibraryDebutCopy.aiSkippedAction
        pill.image = UIImage(systemName: "wand.and.stars")
        pill.imagePadding = 6
        pill.cornerStyle = .capsule
        pill.baseBackgroundColor = .tintColor
        pill.baseForegroundColor = .white
        pill.contentInsets = NSDirectionalEdgeInsets(top: 11, leading: 18, bottom: 11, trailing: 18)
        pill.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = .scaled(.subheadline, size: 15, weight: .semibold)
            return outgoing
        }
        entitlementPill.configuration = pill
        entitlementPill.addAction(UIAction { [weak self] _ in self?.showPaywall() }, for: .touchUpInside)

        let textStack = UIStackView(arrangedSubviews: [headlineRow, explanation])
        textStack.axis = .vertical
        textStack.spacing = 6
        textStack.alignment = .fill

        contentStack.axis = .vertical
        contentStack.alignment = .center
        contentStack.spacing = 22
        contentStack.addArrangedSubview(mosaic)
        contentStack.addArrangedSubview(caption)
        contentStack.addArrangedSubview(textStack)
        contentStack.addArrangedSubview(statsRow)
        contentStack.addArrangedSubview(entitlementPill)
        contentStack.setCustomSpacing(18, after: mosaic)
        contentStack.setCustomSpacing(18, after: caption)
        contentStack.setCustomSpacing(26, after: textStack)
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        scrim.backgroundColor = .black
        scrim.alpha = 0
        scrim.isUserInteractionEnabled = false
        scrim.translatesAutoresizingMaskIntoConstraints = false

        for view in [hairline, wordmark, countdown, contentStack, scrim] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        let mosaicWidth = mosaic.widthAnchor.constraint(equalTo: widthAnchor, constant: -2 * Metrics.horizontalInset)
        mosaicWidth.priority = .required - 1
        let contentCentre = contentStack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 16)
        contentCentre.priority = .defaultHigh

        NSLayoutConstraint.activate([
            hairline.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
            hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            hairline.heightAnchor.constraint(equalToConstant: Metrics.hairlineHeight),

            wordmark.topAnchor.constraint(equalTo: hairline.bottomAnchor, constant: 18),
            wordmark.centerXAnchor.constraint(equalTo: centerXAnchor),

            countdown.topAnchor.constraint(equalTo: wordmark.bottomAnchor, constant: 12),
            countdown.centerXAnchor.constraint(equalTo: centerXAnchor),
            countdown.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: Metrics.horizontalInset),

            contentCentre,
            contentStack.topAnchor.constraint(greaterThanOrEqualTo: countdown.bottomAnchor, constant: 20),
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.horizontalInset),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.horizontalInset),
            contentStack.bottomAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.bottomAnchor, constant: -24),

            mosaicWidth,
            mosaic.widthAnchor.constraint(lessThanOrEqualToConstant: Metrics.mosaicMaximumSide),
            mosaic.heightAnchor.constraint(equalTo: mosaic.widthAnchor),
            mosaic.heightAnchor.constraint(lessThanOrEqualTo: heightAnchor, multiplier: Metrics.mosaicHeightShare),
            caption.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            textStack.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            headline.widthAnchor.constraint(lessThanOrEqualTo: headlineRow.widthAnchor),
            statsRow.widthAnchor.constraint(equalTo: contentStack.widthAnchor),

            scrim.topAnchor.constraint(equalTo: topAnchor),
            scrim.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrim.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrim.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func configureAccessibility() {
        accessibilityViewIsModal = true
        headline.isAccessibilityElement = true
        headline.accessibilityTraits = [.header, .updatesFrequently]
    }

    /// One snapshot, one repaint. Act I reads the bounded load, Act II reads the
    /// fraction-free job, and Act III is driven by `presentSummary(_:aiSkippedForEntitlement:)` instead —
    /// the summary is a fact from the database, not a phase of a stream.
    func update(progress: LibraryLoadProgress, fraction: Double, job: EnrichmentJobProgress, act: LibraryDebutAct) {
        applyAct(act)
        switch act {
        case .indexing:
            renderIndexing(progress: progress, fraction: fraction)
        case .finishing:
            renderFinishing(job)
        case .summary, .done:
            break
        }
    }

    func insert(cover: UIImage, forKey key: String) {
        mosaic.insert(cover: cover, forKey: key)
    }

    private func renderIndexing(progress: LibraryLoadProgress, fraction: Double) {
        headline.text = LibraryLoadPhaseCopy.headline(for: progress.phase)
        explanation.text = LibraryLoadPhaseCopy.explanation(for: progress.phase)
        hairline.setFraction(fraction)
        statsRow.update(progress: progress)
        headline.accessibilityLabel = LibraryLoadPhaseCopy.accessibilityValue(for: progress, fraction: fraction)
        announcePhaseChangeIfNeeded(progress.phase)
    }

    /// Act II is honest about the two ways it can end: the job counts down, or
    /// the trial has run out and the messy titles stay on screen behind an offer
    /// to fix them.
    private func renderFinishing(_ job: EnrichmentJobProgress) {
        applyJobChromeIfNeeded(job)
        guard job.activity != .needsEntitlement else {
            headline.text = LibraryDebutCopy.aiSkippedHeadline
            explanation.text = LibraryDebutCopy.explanation(for: .aiBatch)
            countdown.text = EnrichmentJobCopy.needsEntitlement
            headline.accessibilityLabel = LibraryDebutCopy.aiSkippedHeadline
            return
        }
        headline.text = LibraryDebutCopy.headline(for: job.scope)
        explanation.text = LibraryDebutCopy.explanation(for: job.scope)
        countdown.text = EnrichmentJobCopy.line(for: job)
        headline.accessibilityLabel = EnrichmentJobCopy.accessibilityValue(for: job)
        lightUpRepairedAlbumIfNeeded(job.currentTitle)
    }

    /// The trial chip belongs to the AI pass and the offer belongs to the pass
    /// that could not run; both can change inside Act II, so they are keyed to
    /// the job rather than to the act.
    private func applyJobChromeIfNeeded(_ job: EnrichmentJobProgress) {
        guard job.activity != lastJobActivity || job.scope != lastJobScope else { return }
        lastJobActivity = job.activity
        lastJobScope = job.scope
        let skipped = job.activity == .needsEntitlement
        let apply = {
            self.trialChip.isHidden = skipped || job.scope != .aiBatch
                || PurchaseManager.shared.state == .purchased
            self.entitlementPill.isHidden = !skipped
        }
        guard !reduceMotion else {
            apply()
            updateHeadlineAxis()
            return
        }
        UIView.animate(withDuration: 0.32, delay: 0, options: [.beginFromCurrentState]) {
            apply()
            self.layoutIfNeeded()
        } completion: { _ in
            self.updateHeadlineAxis()
        }
    }

    /// Every album the job finishes brings one dimmed tile back to full strength
    /// and crossfades its real title in underneath — the visible half of "the AI
    /// just corrected this".
    private func lightUpRepairedAlbumIfNeeded(_ title: String?) {
        guard let title, !title.isEmpty, title != lastCaptionTitle else { return }
        lastCaptionTitle = title
        mosaic.popNextTile()
        guard !reduceMotion else {
            caption.text = title
            return
        }
        UIView.transition(with: caption, duration: Metrics.captionCrossfade, options: [.transitionCrossDissolve]) {
            self.caption.text = title
        }
    }

    /// Act I owns a fraction, so it draws one. Act II has none to draw — the job
    /// is a countdown — so the hairline leaves rather than freezing at whatever
    /// it happened to reach.
    private func applyAct(_ next: LibraryDebutAct, animated: Bool = true) {
        guard next != act || !hasAppliedAct else { return }
        act = next
        hasAppliedAct = true
        switch next {
        case .indexing:
            setChrome(indexing: true, animated: animated)
        case .finishing:
            setChrome(indexing: false, animated: animated)
        case .summary, .done:
            break
        }
    }

    private func setChrome(indexing: Bool, animated: Bool) {
        trialChip.text = LibraryDebutCopy.trialChip
        let apply = {
            self.hairline.alpha = indexing ? 1 : 0
            self.countdown.alpha = indexing ? 0 : 1
            self.caption.alpha = indexing ? 0 : 1
            if indexing {
                self.trialChip.isHidden = true
                self.entitlementPill.isHidden = true
            }
        }
        mosaic.setDimmed(!indexing, animated: animated)
        guard animated, !reduceMotion else {
            apply()
            setNeedsLayout()
            return
        }
        UIView.animate(withDuration: 0.45, delay: 0, options: [.beginFromCurrentState]) {
            apply()
            self.layoutIfNeeded()
        }
    }

    /// Settles the grid, plays the one haptic the whole Debut is allowed, and
    /// raises the card over a mosaic that is still alive behind it.
    func presentSummary(_ summary: LibraryDebutSummary, aiSkippedForEntitlement: Bool) {
        guard card == nil else { return }
        act = .summary
        mosaic.setDimmed(true, animated: true)
        mosaic.settle()
        UINotificationFeedbackGenerator().notificationOccurred(.success)

        let card = LibraryDebutSummaryCard(
            summary: summary, aiSkippedForEntitlement: aiSkippedForEntitlement
        )
        card.onPrimaryAction = { [weak self] in self?.dismissTapped() }
        card.onSecondaryAction = { [weak self] in self?.showPaywall() }
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        self.card = card

        let width = card.widthAnchor.constraint(equalTo: widthAnchor, constant: -2 * Metrics.horizontalInset)
        width.priority = .required - 1
        NSLayoutConstraint.activate([
            width,
            card.widthAnchor.constraint(lessThanOrEqualToConstant: Metrics.cardMaximumWidth),
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            card.topAnchor.constraint(greaterThanOrEqualTo: safeAreaLayoutGuide.topAnchor, constant: 20),
            card.bottomAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.bottomAnchor, constant: -20),
        ])
        layoutIfNeeded()

        raise(card)
        UIAccessibility.post(notification: .screenChanged, argument: card)
    }

    private func raise(_ card: LibraryDebutSummaryCard) {
        let fadeChrome = {
            for view in [self.hairline, self.countdown, self.caption, self.headlineRow, self.explanation, self.statsRow, self.entitlementPill] as [UIView] {
                view.alpha = 0
            }
            self.scrim.alpha = Metrics.scrimAlpha
        }
        guard !reduceMotion else {
            fadeChrome()
            card.alpha = 1
            return
        }
        card.alpha = 0
        card.transform = CGAffineTransform(translationX: 0, y: Metrics.cardRise).scaledBy(x: 0.97, y: 0.97)
        UIView.animate(withDuration: Metrics.chromeFade, delay: 0, options: [.beginFromCurrentState], animations: fadeChrome)
        UIView.animate(springDuration: Metrics.cardSpringDuration, bounce: Metrics.cardBounce, delay: 0.08) {
            card.alpha = 1
            card.transform = .identity
        }
    }

    /// The frames of every filled tile, in reading order, in this view's own
    /// coordinate space — what the caller pairs with the album grid's
    /// first-screen cells so the library the reader watched being built is
    /// literally the library they land in.
    func tileFrames() -> [CGRect] {
        mosaic.tileFrames().map { convert($0, from: mosaic) }
    }

    /// Flies the mosaic onto `targets` (this view's coordinate space) while the
    /// card falls away and the canvas dissolves, then hands back so the caller
    /// can remove this view. An empty `targets` degrades to a plain dissolve.
    func morph(to targets: [CGRect], completion: @escaping () -> Void) {
        let converted = targets.map { mosaic.convert($0, from: self) }
        dropCard()
        UIView.animate(withDuration: 0.34, delay: 0, options: [.beginFromCurrentState]) {
            self.backgroundColor = .clear
            self.backdrop.opacity = 0
            self.scrim.alpha = 0
            self.wordmark.alpha = 0
        }
        mosaic.morph(to: converted, completion: completion)
    }

    private func dropCard() {
        guard let card else { return }
        self.card = nil
        guard !reduceMotion else {
            card.removeFromSuperview()
            return
        }
        UIView.animate(withDuration: Metrics.chromeFade, delay: 0, options: [.curveEaseIn]) {
            card.alpha = 0
            card.transform = CGAffineTransform(translationX: 0, y: Metrics.cardRise)
        } completion: { _ in
            card.removeFromSuperview()
        }
    }

    private func dismissTapped() {
        guard !isDismissing else { return }
        isDismissing = true
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        guard let onDismiss else {
            morph(to: []) { [weak self] in self?.removeFromSuperview() }
            return
        }
        onDismiss()
    }

    private func showPaywall() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onShowPaywall?()
    }

    /// The chip only fits beside the headline when it actually fits; on a narrow
    /// phone it drops under it rather than squeezing a twenty-point title.
    private func updateHeadlineAxis() {
        guard !trialChip.isHidden else {
            headlineRow.axis = .horizontal
            return
        }
        let available = bounds.width - 2 * Metrics.horizontalInset
        let needed = headline.intrinsicContentSize.width + trialChip.intrinsicContentSize.width + Metrics.chipGap
        let axis: NSLayoutConstraint.Axis = needed <= available ? .horizontal : .vertical
        guard headlineRow.axis != axis else { return }
        headlineRow.axis = axis
    }

    private func announcePhaseChangeIfNeeded(_ phase: LibraryLoadPhase) {
        guard phase != lastAnnouncedPhase, UIAccessibility.isVoiceOverRunning else {
            lastAnnouncedPhase = phase
            return
        }
        lastAnnouncedPhase = phase
        UIAccessibility.post(notification: .announcement, argument: LibraryLoadPhaseCopy.headline(for: phase))
    }
}

/// Act I's whole fraction: three points of accent under the safe area, with a
/// short glow riding the head of the fill so a slow phase still reads as moving.
/// It is drawn with layers rather than a `UIProgressView` because it has to sit
/// flush against the notch with no inset of its own.
private final class DebutHairlineView: UIView {

    private let track = CALayer()
    private let fill = CALayer()
    private let glow = CAGradientLayer()

    private var fraction: Double = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        track.backgroundColor = UIColor(white: 1, alpha: 0.08).cgColor
        glow.startPoint = CGPoint(x: 0, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 0.5)
        layer.addSublayer(track)
        layer.addSublayer(fill)
        fill.addSublayer(glow)
        applyColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: DebutHairlineView, _) in
            self.applyColors()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutLayers(animated: false)
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        applyColors()
    }

    func setFraction(_ value: Double) {
        let clamped = min(1, max(0, value))
        guard abs(clamped - fraction) > 0.0001 else { return }
        fraction = clamped
        layoutLayers(animated: !UIAccessibility.isReduceMotionEnabled)
    }

    private func layoutLayers(animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.3)
        track.frame = bounds
        fill.frame = CGRect(x: 0, y: 0, width: bounds.width * CGFloat(fraction), height: bounds.height)
        glow.frame = CGRect(x: max(0, fill.bounds.width - 44), y: 0, width: min(44, fill.bounds.width), height: bounds.height)
        CATransaction.commit()
    }

    private func applyColors() {
        let accent = tintColor.resolvedColor(with: traitCollection)
        fill.backgroundColor = accent.cgColor
        glow.colors = [accent.withAlphaComponent(0).cgColor, UIColor.white.withAlphaComponent(0.85).cgColor]
    }
}

/// The hairline chip beside Act II's headline: a half-point outline and nothing
/// else, so the trial line reads as a footnote about the work rather than as an
/// advertisement over it.
private final class DebutChipView: UIView {

    private let label = UILabel()

    var text: String? {
        get { label.text }
        set {
            label.text = newValue
            accessibilityLabel = newValue
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerCurve = .continuous
        layer.borderWidth = 0.5
        applyColors()

        label.font = .scaled(.caption2, size: 11, weight: .medium)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = UIColor.white.withAlphaComponent(0.66)
        label.numberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
        ])
        setContentCompressionResistancePriority(.required - 1, for: .horizontal)
        isAccessibilityElement = true
        accessibilityTraits = .staticText
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }

    private func applyColors() {
        layer.borderColor = UIColor(white: 1, alpha: 0.18).cgColor
    }
}

/// Three live tallies — files seen, tracks indexed, albums built — so the wait
/// shows the library growing instead of an opaque spinner.
final class StatsRowView: UIView {

    private let files = StatView(title: String(localized: "Files"))
    private let tracks = StatView(title: String(localized: "Tracks"))
    private let albums = StatView(title: String(localized: "Albums"))

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: [files, divider(), tracks, divider(), albums])
        stack.axis = .horizontal
        stack.distribution = .fill
        stack.alignment = .center
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            tracks.widthAnchor.constraint(equalTo: files.widthAnchor),
            albums.widthAnchor.constraint(equalTo: files.widthAnchor),
        ])
        isAccessibilityElement = false
        accessibilityElementsHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func divider() -> UIView {
        let line = UIView()
        line.backgroundColor = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            line.widthAnchor.constraint(equalToConstant: 1),
            line.heightAnchor.constraint(equalToConstant: 28),
        ])
        return line
    }

    func update(progress: LibraryLoadProgress) {
        files.setValue(progress.filesFound)
        tracks.setValue(progress.tracksIndexed)
        albums.setValue(progress.albumsBuilt)
    }
}

final class StatView: UIView {

    private let valueLabel = UILabel()
    private let titleLabel = UILabel()
    private var lastValue = 0
    private var lastSpringAt: TimeInterval = 0

    /// Progress publishes at up to ten hertz; a digit that springs on every one
    /// of those is a strobe, not a flourish. A spring is allowed on the first
    /// real value and then at most three times a second.
    private static let springInterval: TimeInterval = 0.34

    init(title: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        valueLabel.font = .scaled(.title3, size: 19, weight: .semibold).monospacedDigits
        valueLabel.adjustsFontForContentSizeCategory = true
        valueLabel.textAlignment = .center
        valueLabel.textColor = .tertiaryLabel
        valueLabel.text = "—"

        titleLabel.text = title
        titleLabel.font = .scaled(.caption2, size: 11, weight: .medium)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .secondaryLabel
        titleLabel.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [valueLabel, titleLabel])
        stack.axis = .vertical
        stack.spacing = 2
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setValue(_ value: Int) {
        guard value != lastValue else { return }
        let wasEmpty = lastValue == 0
        lastValue = value
        valueLabel.text = value > 0 ? LibraryLoadPhaseCopy.number(value) : "—"
        valueLabel.textColor = value > 0 ? .label : .tertiaryLabel
        guard value > 0, !UIAccessibility.isReduceMotionEnabled else { return }
        let now = Date().timeIntervalSinceReferenceDate
        guard wasEmpty || now - lastSpringAt >= Self.springInterval else { return }
        lastSpringAt = now
        valueLabel.transform = CGAffineTransform(scaleX: wasEmpty ? 0.8 : 0.92, y: wasEmpty ? 0.8 : 0.92)
        UIView.animate(springDuration: 0.35, bounce: 0.3) {
            self.valueLabel.transform = .identity
        }
    }
}

extension UIFont {

    /// The same glyph width for every digit, so a counting label does not jitter
    /// its neighbours sideways on the way up.
    var monospacedDigits: UIFont {
        let settings: [UIFontDescriptor.FeatureKey: Int] = [
            .type: kNumberSpacingType,
            .selector: kMonospacedNumbersSelector,
        ]
        let descriptor = fontDescriptor.addingAttributes([.featureSettings: [settings]])
        return UIFont(descriptor: descriptor, size: 0)
    }
}
