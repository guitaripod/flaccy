import UIKit

/// Full-screen Year in Music share configurator: swipeable 9:16 story pages
/// with parallax, theme picker, year picker, and one-tap export to Instagram
/// Stories or the system share sheet. Rendered cards are cached per theme so
/// revisiting a theme is instant.
final class YearInMusicViewController: UIViewController {

    private var year: Int
    private var data: YearInMusicData?
    private var artwork = StoryArtwork.empty
    private var themes: [StoryTheme] = []
    private var selectedThemeIndex = 0
    private var slideImages: [UIImage] = []
    private var renderCache: [String: [UIImage]] = [:]
    private var posterCache: [String: UIImage] = [:]
    private var pageViews: [UIImageView] = []

    private let pagesScrollView = UIScrollView()
    private let pagesStack = UIStackView()
    private let pageControl = UIPageControl()
    private let slideTitleLabel = UILabel()
    private let themeRow = UIStackView()
    private let yearButton = UIButton(configuration: .plain())
    private let emptyStack = UIStackView()
    private let actionsRow = UIStackView()

    private let selectionFeedback = UISelectionFeedbackGenerator()
    private let impactLight = UIImpactFeedbackGenerator(style: .light)
    private let impactMedium = UIImpactFeedbackGenerator(style: .medium)
    private let notificationFeedback = UINotificationFeedbackGenerator()

    init(year: Int = Calendar.current.component(.year, from: Date())) {
        self.year = year
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupTopBar()
        setupPages()
        setupControls()
        reload()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyPageTransforms()
    }

    private func setupTopBar() {
        var closeConfig = UIButton.Configuration.plain()
        closeConfig.image = UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .bold))
        closeConfig.baseForegroundColor = .white
        let closeButton = UIButton(configuration: closeConfig)
        closeButton.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        closeButton.layer.cornerRadius = 17
        closeButton.accessibilityLabel = "Close"
        closeButton.addAction(UIAction { [weak self] _ in
            self?.impactLight.impactOccurred()
            self?.dismiss(animated: true)
        }, for: .touchUpInside)

        var yearConfig = UIButton.Configuration.plain()
        yearConfig.baseForegroundColor = .white
        yearConfig.imagePlacement = .trailing
        yearConfig.imagePadding = 4
        yearConfig.image = UIImage(systemName: "chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .bold))
        yearButton.configuration = yearConfig
        yearButton.showsMenuAsPrimaryAction = true
        yearButton.accessibilityLabel = "Change year"

        let topBar = UIStackView(arrangedSubviews: [yearButton, UIView(), closeButton])
        topBar.axis = .horizontal
        topBar.alignment = .center
        topBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topBar)
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            closeButton.widthAnchor.constraint(equalToConstant: 34),
            closeButton.heightAnchor.constraint(equalToConstant: 34),
        ])
    }

    private func setupPages() {
        pagesScrollView.isPagingEnabled = true
        pagesScrollView.showsHorizontalScrollIndicator = false
        pagesScrollView.clipsToBounds = false
        pagesScrollView.decelerationRate = .fast
        pagesScrollView.delegate = self
        pagesScrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pagesScrollView)

        pagesStack.axis = .horizontal
        pagesStack.alignment = .fill
        pagesStack.distribution = .fillEqually
        pagesStack.translatesAutoresizingMaskIntoConstraints = false
        pagesScrollView.addSubview(pagesStack)

        setupEmptyState()

        NSLayoutConstraint.activate([
            pagesScrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 56),
            pagesScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 44),
            pagesScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -44),

            pagesStack.topAnchor.constraint(equalTo: pagesScrollView.contentLayoutGuide.topAnchor),
            pagesStack.bottomAnchor.constraint(equalTo: pagesScrollView.contentLayoutGuide.bottomAnchor),
            pagesStack.leadingAnchor.constraint(equalTo: pagesScrollView.contentLayoutGuide.leadingAnchor),
            pagesStack.trailingAnchor.constraint(equalTo: pagesScrollView.contentLayoutGuide.trailingAnchor),
            pagesStack.heightAnchor.constraint(equalTo: pagesScrollView.frameLayoutGuide.heightAnchor),

            pagesScrollView.heightAnchor.constraint(equalTo: pagesScrollView.widthAnchor, multiplier: 16.0 / 9.0),

            emptyStack.centerXAnchor.constraint(equalTo: pagesScrollView.centerXAnchor),
            emptyStack.centerYAnchor.constraint(equalTo: pagesScrollView.centerYAnchor),
            emptyStack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 40),
            emptyStack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -40),
        ])
    }

    private func setupEmptyState() {
        let icon = UIImageView(image: UIImage(systemName: "sparkles", withConfiguration: UIImage.SymbolConfiguration(pointSize: 40, weight: .medium)))
        icon.tintColor = UIColor.white.withAlphaComponent(0.35)
        icon.contentMode = .scaleAspectFit

        let title = UILabel()
        title.text = "Nothing here yet"
        title.font = .scaled(.title3, size: 20, weight: .bold)
        title.adjustsFontForContentSizeCategory = true
        title.textColor = .white
        title.textAlignment = .center

        let subtitle = UILabel()
        subtitle.text = "Play some music and your Year in Music will build itself. Or pick another year above."
        subtitle.numberOfLines = 0
        subtitle.textAlignment = .center
        subtitle.textColor = UIColor.white.withAlphaComponent(0.55)
        subtitle.font = .scaled(.body, size: 15, weight: .medium)
        subtitle.adjustsFontForContentSizeCategory = true

        emptyStack.axis = .vertical
        emptyStack.spacing = 10
        emptyStack.alignment = .center
        emptyStack.isHidden = true
        emptyStack.translatesAutoresizingMaskIntoConstraints = false
        [icon, title, subtitle].forEach { emptyStack.addArrangedSubview($0) }
        emptyStack.setCustomSpacing(16, after: icon)
        view.addSubview(emptyStack)
    }

    private func setupControls() {
        slideTitleLabel.font = .scaled(.footnote, size: 13, weight: .semibold)
        slideTitleLabel.adjustsFontForContentSizeCategory = true
        slideTitleLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        slideTitleLabel.textAlignment = .center

        pageControl.numberOfPages = StorySlide.allCases.count
        pageControl.currentPageIndicatorTintColor = .white
        pageControl.pageIndicatorTintColor = UIColor.white.withAlphaComponent(0.3)
        pageControl.addAction(UIAction { [weak self] _ in self?.scrollToCurrentPage() }, for: .valueChanged)

        themeRow.axis = .horizontal
        themeRow.spacing = 14
        themeRow.alignment = .center

        actionsRow.axis = .horizontal
        actionsRow.spacing = 12
        actionsRow.distribution = .fillEqually
        actionsRow.addArrangedSubview(makeActionButton(title: "Stories", systemImage: "camera.circle.fill", prominent: true) { [weak self] in
            self?.shareToInstagramStories()
        })
        actionsRow.addArrangedSubview(makeShareMenuButton())

        let controls = UIStackView(arrangedSubviews: [slideTitleLabel, pageControl, themeRow, actionsRow])
        controls.axis = .vertical
        controls.alignment = .center
        controls.spacing = 8
        controls.setCustomSpacing(2, after: slideTitleLabel)
        controls.setCustomSpacing(14, after: themeRow)
        controls.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controls)

        NSLayoutConstraint.activate([
            controls.topAnchor.constraint(greaterThanOrEqualTo: pagesScrollView.bottomAnchor, constant: 8),
            controls.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            controls.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            controls.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            actionsRow.widthAnchor.constraint(equalTo: controls.widthAnchor),
            actionsRow.heightAnchor.constraint(equalToConstant: 50),
        ])
    }

    private func makeActionButton(title: String, systemImage: String, prominent: Bool, action: @escaping () -> Void) -> UIButton {
        var config = prominent ? UIButton.Configuration.filled() : UIButton.Configuration.gray()
        config.title = title
        config.image = UIImage(systemName: systemImage, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
        config.imagePadding = 8
        config.cornerStyle = .capsule
        if prominent {
            config.baseBackgroundColor = .white
            config.baseForegroundColor = .black
        } else {
            config.baseBackgroundColor = UIColor.white.withAlphaComponent(0.14)
            config.baseForegroundColor = .white
        }
        let button = UIButton(configuration: config)
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    private func makeShareMenuButton() -> UIButton {
        var config = UIButton.Configuration.gray()
        config.title = "Share"
        config.image = UIImage(systemName: "square.and.arrow.up", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
        config.imagePadding = 8
        config.cornerStyle = .capsule
        config.baseBackgroundColor = UIColor.white.withAlphaComponent(0.14)
        config.baseForegroundColor = .white
        let button = UIButton(configuration: config)
        button.showsMenuAsPrimaryAction = true
        button.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.shareMenuActions() ?? [])
            }
        ])
        button.accessibilityLabel = "Share"
        return button
    }

    private func shareMenuActions() -> [UIMenuElement] {
        [
            UIAction(title: "This Card", subtitle: "Story size · 9:16", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
                self?.shareCurrentSlide()
            },
            UIAction(title: "All Four Cards", subtitle: "Instagram carousel · X photo grid", image: UIImage(systemName: "rectangle.stack")) { [weak self] _ in
                self?.shareAllCards()
            },
            UIAction(title: "Poster for Feeds", subtitle: "Everything on one card · 4:5", image: UIImage(systemName: "rectangle.portrait")) { [weak self] _ in
                self?.sharePoster()
            },
        ]
    }

    private func reload() {
        let data = YearInMusicService.shared.compute(year: year)
        self.data = data
        artwork = StoryArtwork.resolve(for: data)
        renderCache.removeAll()
        posterCache.removeAll()

        let seed = data.topArtists.first.map { "\($0.name)\(year)" } ?? "flaccy\(year)"
        themes = StoryTheme.all(seedPalette: ArtworkPaletteExtractor.fallbackPalette(seed: seed))
        selectedThemeIndex = min(selectedThemeIndex, themes.count - 1)

        yearButton.configuration?.attributedTitle = AttributedString(
            String(year),
            attributes: AttributeContainer([.font: UIFont.scaled(.headline, size: 17, weight: .bold)])
        )
        yearButton.menu = makeYearMenu()

        let hasContent = data.hasContent
        emptyStack.isHidden = hasContent
        pagesScrollView.isHidden = !hasContent
        [slideTitleLabel, pageControl, themeRow, actionsRow].forEach { $0.alpha = hasContent ? 1 : 0.3 }
        actionsRow.isUserInteractionEnabled = hasContent
        rebuildThemeRow()

        guard hasContent else { return }
        renderSlides(animated: false)
    }

    private func makeYearMenu() -> UIMenu {
        var years = YearInMusicService.shared.availableYears()
        let current = Calendar.current.component(.year, from: Date())
        if !years.contains(current) { years.insert(current, at: 0) }
        let actions = years.map { candidate in
            UIAction(title: String(candidate), state: candidate == year ? .on : .off) { [weak self] _ in
                guard let self, self.year != candidate else { return }
                self.selectionFeedback.selectionChanged()
                self.year = candidate
                self.reload()
            }
        }
        return UIMenu(children: actions)
    }

    private func rebuildThemeRow() {
        themeRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, theme) in themes.enumerated() {
            let swatch = UIButton(type: .custom)
            swatch.layer.cornerRadius = 16
            swatch.accessibilityLabel = "\(theme.name) theme"

            let gradient = CAGradientLayer()
            gradient.colors = [theme.gradientColors.first ?? .black, theme.accent].map(\.cgColor)
            gradient.startPoint = CGPoint(x: 0, y: 0)
            gradient.endPoint = CGPoint(x: 1, y: 1)
            gradient.frame = CGRect(x: 0, y: 0, width: 32, height: 32)
            gradient.cornerRadius = 16
            swatch.layer.addSublayer(gradient)

            swatch.layer.borderWidth = index == selectedThemeIndex ? 2.5 : 1
            swatch.layer.borderColor = index == selectedThemeIndex
                ? UIColor.white.cgColor
                : UIColor.white.withAlphaComponent(0.25).cgColor
            swatch.accessibilityTraits = index == selectedThemeIndex ? [.button, .selected] : .button

            swatch.widthAnchor.constraint(equalToConstant: 32).isActive = true
            swatch.heightAnchor.constraint(equalToConstant: 32).isActive = true
            swatch.addAction(UIAction { [weak self] _ in self?.selectTheme(at: index) }, for: .touchUpInside)
            themeRow.addArrangedSubview(swatch)
        }
    }

    private func selectTheme(at index: Int) {
        guard index != selectedThemeIndex else { return }
        selectionFeedback.selectionChanged()
        selectedThemeIndex = index
        rebuildThemeRow()
        renderSlides(animated: true)
    }

    private func renderSlides(animated: Bool) {
        guard let data, data.hasContent else { return }
        let theme = themes[selectedThemeIndex]

        if let cached = renderCache[theme.name] {
            slideImages = cached
        } else {
            slideImages = StorySlide.allCases.map {
                YearInMusicStoryView.makeImage(slide: $0, data: data, artwork: artwork, theme: theme)
            }
            renderCache[theme.name] = slideImages
        }

        if pageViews.count != slideImages.count {
            pagesStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            pageViews = slideImages.map { _ in
                let imageView = UIImageView()
                imageView.contentMode = .scaleAspectFit
                imageView.layer.cornerRadius = 24
                imageView.layer.cornerCurve = .continuous
                imageView.clipsToBounds = true
                pagesStack.addArrangedSubview(imageView)
                imageView.widthAnchor.constraint(equalTo: pagesScrollView.frameLayoutGuide.widthAnchor).isActive = true
                return imageView
            }
        }

        for (imageView, image) in zip(pageViews, slideImages) {
            if animated && !UIAccessibility.isReduceMotionEnabled {
                UIView.transition(with: imageView, duration: 0.28, options: .transitionCrossDissolve) {
                    imageView.image = image
                }
            } else {
                imageView.image = image
            }
        }
        applyPageTransforms()
        updateSlideTitle()
    }

    private func applyPageTransforms() {
        let width = pagesScrollView.bounds.width
        guard width > 0, !UIAccessibility.isReduceMotionEnabled else { return }
        for (index, page) in pageViews.enumerated() {
            let offset = (CGFloat(index) * width - pagesScrollView.contentOffset.x) / width
            let distance = min(1, abs(offset))
            let scale = 1 - 0.08 * distance
            page.transform = CGAffineTransform(scaleX: scale, y: scale)
            page.alpha = 1 - 0.35 * distance
        }
    }

    private var currentPage: Int {
        let width = pagesScrollView.bounds.width
        guard width > 0 else { return 0 }
        let page = Int(round(pagesScrollView.contentOffset.x / width))
        return min(max(page, 0), StorySlide.allCases.count - 1)
    }

    private func scrollToCurrentPage() {
        selectionFeedback.selectionChanged()
        let offset = CGFloat(pageControl.currentPage) * pagesScrollView.bounds.width
        pagesScrollView.setContentOffset(CGPoint(x: offset, y: 0), animated: true)
    }

    private func updateSlideTitle() {
        let slide = StorySlide.allCases[currentPage]
        let theme = themes.indices.contains(selectedThemeIndex) ? themes[selectedThemeIndex].name : ""
        slideTitleLabel.text = theme.isEmpty ? slide.displayName : "\(slide.displayName) · \(theme)"
        pageControl.currentPage = currentPage
    }

    private var currentSlideImage: UIImage? {
        guard slideImages.indices.contains(currentPage) else { return nil }
        return slideImages[currentPage]
    }

    private func shareToInstagramStories() {
        guard let image = currentSlideImage else { return }
        impactMedium.impactOccurred()

        let sourceApplication = Bundle.main.bundleIdentifier ?? "com.midgarcorp.flaccy"
        guard let url = URL(string: "instagram-stories://share?source_application=\(sourceApplication)"),
              UIApplication.shared.canOpenURL(url),
              let pngData = image.pngData() else {
            shareCurrentSlide()
            return
        }

        let items: [[String: Any]] = [["com.instagram.sharedSticker.backgroundImage": pngData]]
        let options: [UIPasteboard.OptionsKey: Any] = [.expirationDate: Date().addingTimeInterval(300)]
        UIPasteboard.general.setItems(items, options: options)
        UIApplication.shared.open(url)
        AppLogger.info("Shared Year in Music slide to Instagram Stories", category: .ui)
    }

    private func shareCurrentSlide() {
        guard let image = currentSlideImage else { return }
        shareImages([image])
    }

    /// The four detail cards, excluding the poster: exactly X's four-image
    /// limit, and a ready-made Instagram carousel.
    private func shareAllCards() {
        let coreSlides = StorySlide.allCases.filter { $0 != .poster }
        let images = coreSlides.compactMap { slide in
            slideImages.indices.contains(slide.rawValue) ? slideImages[slide.rawValue] : nil
        }
        guard !images.isEmpty else { return }
        shareImages(images)
    }

    private func sharePoster() {
        guard let data, data.hasContent else { return }
        let theme = themes[selectedThemeIndex]
        let cacheKey = "\(theme.name)|post"
        let image: UIImage
        if let cached = posterCache[cacheKey] {
            image = cached
        } else {
            image = YearInMusicStoryView.makeImage(slide: .poster, data: data, artwork: artwork, theme: theme, format: .post)
            posterCache[cacheKey] = image
        }
        shareImages([image])
    }

    private func shareImages(_ images: [UIImage]) {
        impactLight.impactOccurred()
        let activity = UIActivityViewController(activityItems: images, applicationActivities: nil)
        activity.completionWithItemsHandler = { [weak self] _, completed, _, _ in
            if completed { self?.notificationFeedback.notificationOccurred(.success) }
        }
        present(activity, animated: true)
    }
}

extension YearInMusicViewController: UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        applyPageTransforms()
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        selectionFeedback.selectionChanged()
        updateSlideTitle()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        updateSlideTitle()
    }
}
