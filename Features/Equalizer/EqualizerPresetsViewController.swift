import FlaccyCore
import UIKit

/// The presets list and the per-output profiles, in one screen behind the
/// equalizer: audition a preset by tapping it, keep your own, and tell each
/// output which profile it should remember.
final class EqualizerPresetsViewController: UIViewController {

    enum Tab: Int {
        case presets
        case outputs
    }

    private let engine = EqualizerEngine.shared
    private let accent: UIColor
    private var selectedTab: Tab

    private let backdrop = AmbientPaletteBackdropView()
    private let titleLabel = UILabel()
    private let tabs = UISegmentedControl(items: [String(localized: "Presets"), String(localized: "Outputs")])
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let outputsScroll = UIScrollView()
    private let outputsStack = UIStackView()
    private let impact = UIImpactFeedbackGenerator(style: .light)
    private let selection = UISelectionFeedbackGenerator()
    private let auditioner = EqualizerAuditioner()

    private struct Row {
        enum Kind {
            case header(String)
            case profile(EqualizerProfile, subtitle: String)
        }
        let kind: Kind
    }

    private var rows: [Row] = []

    init(startingOn tab: Tab, accent: UIColor) {
        self.selectedTab = tab
        self.accent = accent
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        overrideUserInterfaceStyle = .dark
        buildLayout()
        NotificationCenter.default.addObserver(self, selector: #selector(stateChanged), name: EqualizerEngine.stateDidChange, object: nil)
        auditioner.didChange = { [weak self] _ in self?.refreshAuditionedRows() }
        ArtworkPaletteExtractor.palette(
            for: AudioPlayer.shared.currentTrack?.artwork,
            cacheKey: AudioPlayer.shared.currentTrack.map { "\($0.albumTitle)\0\($0.artist)" } ?? "flaccy",
            fallbackSeed: AudioPlayer.shared.currentTrack.map { "\($0.title)\($0.artist)" } ?? "flaccy"
        ) { [weak self] palette in self?.backdrop.apply(palette, animated: false) }
        reload()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        endHold()
    }

    @objc private func stateChanged() {
        reload()
    }

    @objc private func handleRowHold(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            tableView.isScrollEnabled = false
            navigationController?.isModalInPresentation = true
            selection.prepare()
            auditionRow(at: gesture.location(in: tableView))
        case .changed:
            auditionRow(at: gesture.location(in: tableView))
        default:
            endHold()
        }
    }

    private func auditionRow(at point: CGPoint) {
        guard let indexPath = tableView.indexPathForRow(at: point),
              case .profile(let profile, _) = rows[indexPath.row].kind,
              profile.id != auditioner.current?.id else { return }
        selection.selectionChanged()
        auditioner.begin(profile)
    }

    /// Releasing ends the audition and puts back what was in force; choosing stays a tap.
    private func endHold() {
        tableView.isScrollEnabled = true
        navigationController?.isModalInPresentation = false
        auditioner.end()
    }

    private func refreshAuditionedRows() {
        for cell in tableView.visibleCells {
            guard let row = cell as? EqualizerPresetRowCell, let indexPath = tableView.indexPath(for: cell),
                  case .profile(let profile, _) = rows[indexPath.row].kind else { continue }
            row.setAuditioned(profile.id == auditioner.current?.id)
        }
    }

    private func buildLayout() {
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(backdrop)

        let back = UIButton(type: .system)
        var backConfiguration = UIButton.Configuration.plain()
        backConfiguration.image = UIImage(systemName: "chevron.left", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold))
        backConfiguration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 8)
        back.configuration = backConfiguration
        back.tintColor = accent
        back.accessibilityLabel = EqualizerCopy.title
        back.addAction(UIAction { [weak self] _ in self?.navigationController?.popViewController(animated: true) }, for: .touchUpInside)

        titleLabel.font = .equalizerRounded(.title1, size: 28, weight: .bold)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .white
        titleLabel.accessibilityTraits = .header

        let plus = UIButton(type: .system)
        plus.setImage(UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)), for: .normal)
        plus.tintColor = .white
        plus.accessibilityLabel = String(localized: "Add or import")
        plus.showsMenuAsPrimaryAction = true
        plus.menu = UIMenu(children: [
            UIAction(title: String(localized: "Save Current Curve…"), image: UIImage(systemName: "bookmark")) { [weak self] _ in self?.promptSaveCurrent() },
            UIAction(title: String(localized: "Paste or Import Text…"), image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in
                guard let self else { return }
                self.navigationController?.pushViewController(EqualizerImportViewController(accent: self.accent), animated: true)
            },
            UIAction(title: String(localized: "Find Headphones on AutoEq"), image: UIImage(systemName: "arrow.up.right.square")) { _ in
                if let url = URL(string: "https://autoeq.app") { UIApplication.shared.open(url) }
            },
        ])
        let plusCapsule = LiquidGlass.capsule(hosting: plus, height: 40)
        plusCapsule.widthAnchor.constraint(equalToConstant: 40).isActive = true

        let header = UIStackView(arrangedSubviews: [back, titleLabel, UIView(), plusCapsule])
        header.alignment = .center
        header.spacing = 4
        header.translatesAutoresizingMaskIntoConstraints = false

        tabs.selectedSegmentIndex = selectedTab.rawValue
        tabs.selectedSegmentTintColor = UIColor.white.withAlphaComponent(0.18)
        tabs.backgroundColor = UIColor.white.withAlphaComponent(0.07)
        tabs.setTitleTextAttributes([.foregroundColor: UIColor.white.withAlphaComponent(0.7), .font: UIFont.scaled(.subheadline, size: 13.5, weight: .semibold)], for: .normal)
        tabs.setTitleTextAttributes([.foregroundColor: UIColor.white, .font: UIFont.scaled(.subheadline, size: 13.5, weight: .semibold)], for: .selected)
        tabs.addAction(UIAction { [weak self] _ in
            guard let self, let tab = Tab(rawValue: self.tabs.selectedSegmentIndex) else { return }
            self.selectedTab = tab
            self.endHold()
            self.reload()
        }, for: .valueChanged)
        tabs.translatesAutoresizingMaskIntoConstraints = false

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(EqualizerPresetRowCell.self, forCellReuseIdentifier: EqualizerPresetRowCell.reuseIdentifier)
        tableView.register(EqualizerSectionHeaderCell.self, forCellReuseIdentifier: EqualizerSectionHeaderCell.reuseIdentifier)
        tableView.contentInset = UIEdgeInsets(top: 4, left: 0, bottom: 40, right: 0)
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(handleRowHold(_:)))
        hold.minimumPressDuration = 0.25
        tableView.addGestureRecognizer(hold)

        outputsScroll.translatesAutoresizingMaskIntoConstraints = false
        outputsScroll.alwaysBounceVertical = true
        outputsStack.axis = .vertical
        outputsStack.spacing = 14
        outputsStack.translatesAutoresizingMaskIntoConstraints = false
        outputsScroll.addSubview(outputsStack)

        [header, tabs, tableView, outputsScroll].forEach(view.addSubview)
        let guide = view.layoutMarginsGuide
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: view.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            backdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 30),
            header.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 14),
            header.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            tabs.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14),
            tabs.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            tabs.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            tabs.heightAnchor.constraint(equalToConstant: 36),
            tableView.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 8),
            tableView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            outputsScroll.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 12),
            outputsScroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            outputsScroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            outputsScroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            outputsStack.topAnchor.constraint(equalTo: outputsScroll.contentLayoutGuide.topAnchor, constant: 4),
            outputsStack.bottomAnchor.constraint(equalTo: outputsScroll.contentLayoutGuide.bottomAnchor, constant: -40),
            outputsStack.leadingAnchor.constraint(equalTo: outputsScroll.frameLayoutGuide.leadingAnchor, constant: 20),
            outputsStack.trailingAnchor.constraint(equalTo: outputsScroll.frameLayoutGuide.trailingAnchor, constant: -20),
        ])
        _ = guide
    }

    // MARK: Reload

    private func reload() {
        titleLabel.text = selectedTab == .presets ? String(localized: "Presets") : String(localized: "Outputs")
        tableView.isHidden = selectedTab != .presets
        outputsScroll.isHidden = selectedTab != .outputs
        if selectedTab == .presets {
            rebuildRows()
            tableView.reloadData()
        } else {
            rebuildOutputs()
        }
    }

    private func rebuildRows() {
        var built: [Row] = []
        built.append(Row(kind: .header(String(localized: "Bit-perfect"))))
        built.append(Row(kind: .profile(EqualizerPresets.flat, subtitle: EqualizerCopy.presetSubtitle(forKey: "flat"))))
        let mine = engine.state.userProfiles
        if !mine.isEmpty {
            built.append(Row(kind: .header(String(localized: "Yours"))))
            for profile in mine {
                let kind = profile.kind == .graphic ? String(localized: "Simple") : String(localized: "Advanced · \(profile.bands.count) bands")
                built.append(Row(kind: .profile(profile, subtitle: kind)))
            }
        }
        built.append(Row(kind: .header(String(localized: "Tune"))))
        for key in EqualizerPresets.tuneKeys {
            if let profile = EqualizerPresets.profile(forKey: key) {
                built.append(Row(kind: .profile(profile, subtitle: EqualizerCopy.presetSubtitle(forKey: key))))
            }
        }
        built.append(Row(kind: .header(String(localized: "Genres"))))
        for key in EqualizerPresets.genreKeys {
            if let profile = EqualizerPresets.profile(forKey: key) {
                built.append(Row(kind: .profile(profile, subtitle: EqualizerCopy.presetSubtitle(forKey: key))))
            }
        }
        rows = built
    }

    private func promptSaveCurrent() {
        let alert = UIAlertController(
            title: String(localized: "Save as Preset"),
            message: String(localized: "Give this curve a name. It appears at the start of your presets."),
            preferredStyle: .alert
        )
        alert.addTextField { [engine] field in
            field.text = EqualizerCopy.name(of: engine.profileInForce)
            field.autocapitalizationType = .words
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Save"), style: .default) { [weak self, weak alert] _ in
            guard let name = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return }
            self?.engine.saveInForce(as: name)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        })
        present(alert, animated: true)
    }

    private func promptRename(_ profile: EqualizerProfile) {
        let alert = UIAlertController(title: String(localized: "Rename Preset"), message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = profile.name
            field.autocapitalizationType = .words
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Rename"), style: .default) { [weak self, weak alert] _ in
            guard let name = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return }
            self?.engine.rename(profileID: profile.id, to: name)
        })
        present(alert, animated: true)
    }

    // MARK: Outputs

    private func rebuildOutputs() {
        outputsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        outputsStack.addArrangedSubview(currentOutputCard())

        let others = engine.rememberedOutputs.filter { $0.id != engine.outputID }
        outputsStack.addArrangedSubview(sectionTag(String(localized: "Other outputs")))
        if others.isEmpty {
            let empty = noteLabel(String(localized: "An output you connect shows up here once it remembers a profile."))
            outputsStack.addArrangedSubview(empty)
        } else {
            let card = cardContainer()
            let list = UIStackView()
            list.axis = .vertical
            for (index, output) in others.enumerated() {
                if index > 0 { list.addArrangedSubview(hairline()) }
                list.addArrangedSubview(otherOutputRow(output))
            }
            embed(list, in: card, insets: UIEdgeInsets(top: 4, left: 16, bottom: 4, right: 16))
            outputsStack.addArrangedSubview(card)
        }

        outputsStack.addArrangedSubview(defaultCard())
        outputsStack.addArrangedSubview(noteLabel(String(localized: "The equalizer only shapes what Flaccy plays. Other apps and system sounds are untouched.")))
    }

    private func currentOutputCard() -> UIView {
        let card = cardContainer()
        let output = engine.output

        let icon = UIImageView(image: UIImage(systemName: symbol(for: output?.kind), withConfiguration: UIImage.SymbolConfiguration(pointSize: 24, weight: .semibold)))
        icon.tintColor = accent
        icon.contentMode = .center
        let iconBackground = UIView()
        iconBackground.backgroundColor = accent.withAlphaComponent(0.2)
        iconBackground.layer.cornerRadius = 26
        iconBackground.translatesAutoresizingMaskIntoConstraints = false
        icon.translatesAutoresizingMaskIntoConstraints = false
        iconBackground.addSubview(icon)
        NSLayoutConstraint.activate([
            iconBackground.widthAnchor.constraint(equalToConstant: 52),
            iconBackground.heightAnchor.constraint(equalToConstant: 52),
            icon.centerXAnchor.constraint(equalTo: iconBackground.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconBackground.centerYAnchor),
        ])

        let name = UILabel()
        name.text = output?.name ?? String(localized: "Speaker")
        name.font = .scaled(.title3, size: 18, weight: .bold)
        name.adjustsFontForContentSizeCategory = true
        name.textColor = .white
        let state = UILabel()
        state.text = String(localized: "Playing now")
        state.font = .scaled(.footnote, size: 13, weight: .semibold)
        state.adjustsFontForContentSizeCategory = true
        state.textColor = EqualizerTheme.lossless
        let texts = UIStackView(arrangedSubviews: [name, state])
        texts.axis = .vertical
        texts.spacing = 2
        let top = UIStackView(arrangedSubviews: [iconBackground, texts])
        top.spacing = 14
        top.alignment = .center

        let profileButton = UIButton(type: .system)
        var configuration = UIButton.Configuration.plain()
        configuration.title = engine.isOutputBoundToOff ? String(localized: "Off · bit-perfect") : EqualizerCopy.name(of: engine.profileInForce)
        configuration.image = UIImage(systemName: "chevron.up.chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .bold))
        configuration.imagePlacement = .trailing
        configuration.imagePadding = 6
        configuration.contentInsets = .zero
        configuration.baseForegroundColor = .white
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = UIFont.scaled(.body, size: 15, weight: .semibold)
            return outgoing
        }
        profileButton.configuration = configuration
        profileButton.showsMenuAsPrimaryAction = true
        profileButton.menu = profileMenu { [weak self] choice in self?.applyChoice(choice, toOutput: self?.engine.outputID) }
        let profileRow = labelledRow(String(localized: "Profile"), trailing: profileButton)

        let remember = UISwitch()
        remember.onTintColor = accent
        remember.isOn = engine.keepsOwnProfileForOutput
        remember.isEnabled = output != nil
        remember.accessibilityLabel = String(localized: "Remember for this output")
        remember.addAction(UIAction { [weak self, weak remember] _ in
            guard let self, let remember else { return }
            self.impact.impactOccurred()
            self.engine.setRemembering(remember.isOn)
        }, for: .valueChanged)
        let rememberRow = labelledRow(String(localized: "Remember for this output"), trailing: remember)

        let caption = noteLabel(String(localized: "When this output connects, Flaccy switches to its profile by itself and says so with a short banner."))

        let list = UIStackView(arrangedSubviews: [top, hairline(), profileRow, hairline(), rememberRow, caption])
        list.axis = .vertical
        list.spacing = 12
        embed(list, in: card, insets: UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16))
        return card
    }

    private func otherOutputRow(_ output: (id: String, name: String, binding: String)) -> UIView {
        let nameLabel = UILabel()
        nameLabel.text = output.name
        nameLabel.font = .scaled(.body, size: 15.5, weight: .semibold)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.textColor = .white
        let profileName: String
        if output.binding == EqualizerState.offBinding {
            profileName = String(localized: "Off · bit-perfect")
        } else {
            profileName = engine.state.profile(withID: output.binding).map { EqualizerCopy.name(of: $0) } ?? EqualizerCopy.presetName(forKey: "flat")
        }
        let button = UIButton(type: .system)
        var configuration = UIButton.Configuration.plain()
        configuration.title = profileName
        configuration.image = UIImage(systemName: "chevron.up.chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .bold))
        configuration.imagePlacement = .trailing
        configuration.imagePadding = 6
        configuration.contentInsets = .zero
        configuration.baseForegroundColor = output.binding == EqualizerState.offBinding ? EqualizerTheme.lossless : UIColor.white.withAlphaComponent(0.7)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = UIFont.scaled(.footnote, size: 13, weight: .semibold)
            return outgoing
        }
        button.configuration = configuration
        button.showsMenuAsPrimaryAction = true
        button.menu = profileMenu(includeForget: true) { [weak self] choice in self?.applyChoice(choice, toOutput: output.id) }
        let row = UIStackView(arrangedSubviews: [nameLabel, UIView(), button])
        row.alignment = .center
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true
        return row
    }

    private func defaultCard() -> UIView {
        let card = cardContainer()
        let button = UIButton(type: .system)
        var configuration = UIButton.Configuration.plain()
        configuration.title = engine.state.profile(withID: engine.state.activeProfileID).map { EqualizerCopy.name(of: $0) } ?? EqualizerCopy.presetName(forKey: "flat")
        configuration.image = UIImage(systemName: "chevron.up.chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .bold))
        configuration.imagePlacement = .trailing
        configuration.imagePadding = 6
        configuration.contentInsets = .zero
        configuration.baseForegroundColor = .white
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = UIFont.scaled(.body, size: 15, weight: .semibold)
            return outgoing
        }
        button.configuration = configuration
        button.showsMenuAsPrimaryAction = true
        button.menu = profileMenu(includeOff: false) { [weak self] choice in
            if case .profile(let id) = choice { self?.engine.setDefaultProfile(id) }
        }
        let row = labelledRow(String(localized: "Other outputs use"), trailing: button)
        embed(row, in: card, insets: UIEdgeInsets(top: 14, left: 16, bottom: 14, right: 16))
        return card
    }

    private enum Choice {
        case off
        case profile(String)
        case forget
    }

    private func profileMenu(includeOff: Bool = true, includeForget: Bool = false, handler: @escaping (Choice) -> Void) -> UIMenu {
        var children: [UIMenuElement] = []
        if includeOff {
            children.append(UIAction(title: String(localized: "Off · bit-perfect"), image: UIImage(systemName: "checkmark.circle")) { _ in handler(.off) })
        }
        let mine = engine.state.userProfiles.map { profile in
            UIAction(title: profile.name) { _ in handler(.profile(profile.id)) }
        }
        if !mine.isEmpty { children.append(UIMenu(title: String(localized: "Yours"), options: .displayInline, children: mine)) }
        let builtIn = EqualizerPresets.all.map { profile in
            UIAction(title: EqualizerCopy.name(of: profile)) { _ in handler(.profile(profile.id)) }
        }
        children.append(UIMenu(title: String(localized: "Presets"), options: .displayInline, children: builtIn))
        if includeForget {
            children.append(UIAction(title: String(localized: "Forget this Output"), image: UIImage(systemName: "trash"), attributes: .destructive) { _ in handler(.forget) })
        }
        return UIMenu(children: children)
    }

    private func applyChoice(_ choice: Choice, toOutput id: String?) {
        guard let id else { return }
        impact.impactOccurred()
        switch choice {
        case .off: engine.bindOutputToOff(id)
        case .profile(let profileID): engine.setBinding(profileID, forOutput: id)
        case .forget: engine.forgetOutput(id)
        }
    }

    // MARK: Output views

    private func symbol(for kind: EqualizerOutput.Kind?) -> String {
        switch kind {
        case .headphones: return "headphones"
        case .bluetooth: return "airpods.pro"
        case .airPlay: return "airplayaudio"
        case .usb: return "cable.connector"
        case .display: return "tv"
        case .car: return "car"
        default: return "iphone"
        }
    }

    private func cardContainer() -> UIView {
        let card = UIView()
        card.backgroundColor = UIColor.white.withAlphaComponent(0.06)
        card.layer.cornerRadius = 22
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.layer.borderColor = UIColor.white.withAlphaComponent(0.1).cgColor
        return card
    }

    private func embed(_ content: UIView, in card: UIView, insets: UIEdgeInsets) {
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: insets.top),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -insets.bottom),
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: insets.left),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -insets.right),
        ])
    }

    private func labelledRow(_ title: String, trailing: UIView) -> UIView {
        let label = UILabel()
        label.text = title
        label.font = .scaled(.body, size: 15, weight: .regular)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .white
        label.numberOfLines = 0
        let row = UIStackView(arrangedSubviews: [label, UIView(), trailing])
        row.alignment = .center
        row.spacing = 12
        return row
    }

    private func hairline() -> UIView {
        HairlineView(color: UIColor.white.withAlphaComponent(0.1))
    }

    private func sectionTag(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text.uppercased()
        label.font = .scaled(.caption2, size: 11, weight: .bold)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = UIColor.white.withAlphaComponent(0.42)
        return label
    }

    private func noteLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .scaled(.caption1, size: 12.5, weight: .regular)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = UIColor.white.withAlphaComponent(0.42)
        label.numberOfLines = 0
        return label
    }
}

extension EqualizerPresetsViewController: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch rows[indexPath.row].kind {
        case .header(let title):
            let cell = tableView.dequeueReusableCell(withIdentifier: EqualizerSectionHeaderCell.reuseIdentifier, for: indexPath) as! EqualizerSectionHeaderCell
            cell.configure(title: title)
            return cell
        case .profile(let profile, let subtitle):
            let cell = tableView.dequeueReusableCell(withIdentifier: EqualizerPresetRowCell.reuseIdentifier, for: indexPath) as! EqualizerPresetRowCell
            let current = profile.id == engine.profileInForce.id
            cell.configure(
                name: EqualizerCopy.name(of: profile),
                subtitle: subtitle,
                points: BiquadMath.curve(profile.resolvedBands(), points: 40),
                isCurrent: current,
                tint: accent
            )
            cell.setAuditioned(profile.id == auditioner.current?.id)
            return cell
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard case .profile(let profile, _) = rows[indexPath.row].kind else { return }
        impact.impactOccurred()
        engine.select(profileID: profile.id)
    }

    func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        if case .profile = rows[indexPath.row].kind { return true }
        return false
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard case .profile(let profile, _) = rows[indexPath.row].kind, !profile.isBuiltIn else { return nil }
        let delete = UIContextualAction(style: .destructive, title: String(localized: "Delete")) { [weak self] _, _, done in
            self?.engine.delete(profileID: profile.id)
            done(true)
        }
        let rename = UIContextualAction(style: .normal, title: String(localized: "Rename")) { [weak self] _, _, done in
            self?.promptRename(profile)
            done(true)
        }
        rename.backgroundColor = accent.withAlphaComponent(0.8)
        let share = UIContextualAction(style: .normal, title: String(localized: "Share")) { [weak self] _, _, done in
            guard let self else { return done(false) }
            let activity = UIActivityViewController(activityItems: [self.engine.exportText(for: profile)], applicationActivities: nil)
            self.present(activity, animated: true)
            done(true)
        }
        share.backgroundColor = UIColor.systemGray
        return UISwipeActionsConfiguration(actions: [delete, rename, share])
    }
}

/// One preset in the list: its curve, its name, what it is for, a tick if it is in force.
private final class EqualizerPresetRowCell: UITableViewCell {

    static let reuseIdentifier = "EqualizerPresetRowCell"

    private let thumb = UIView()
    private let curveLayer = CAShapeLayer()
    private let nameLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let tick = UIImageView()
    private let bars = NowPlayingBarsView()
    private let highlightView = UIView()
    private var points: [Double] = []
    private var tint = EqualizerTheme.fallbackAccent
    private var current = false

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none

        highlightView.layer.cornerRadius = 18
        highlightView.layer.cornerCurve = .continuous
        highlightView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(highlightView)

        thumb.backgroundColor = UIColor.white.withAlphaComponent(0.06)
        thumb.layer.cornerRadius = 12
        thumb.layer.cornerCurve = .continuous
        thumb.layer.borderWidth = 1
        thumb.layer.borderColor = UIColor.white.withAlphaComponent(0.08).cgColor
        thumb.translatesAutoresizingMaskIntoConstraints = false
        curveLayer.fillColor = nil
        curveLayer.lineWidth = 2
        curveLayer.lineCap = .round
        curveLayer.lineJoin = .round
        thumb.layer.addSublayer(curveLayer)

        nameLabel.font = .scaled(.body, size: 16, weight: .semibold)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.textColor = .white
        subtitleLabel.font = .scaled(.footnote, size: 12.5, weight: .regular)
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.textColor = UIColor.white.withAlphaComponent(0.66)
        let texts = UIStackView(arrangedSubviews: [nameLabel, subtitleLabel])
        texts.axis = .vertical
        texts.spacing = 1

        tick.image = UIImage(systemName: "checkmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .bold))
        tick.setContentHuggingPriority(.required, for: .horizontal)

        bars.translatesAutoresizingMaskIntoConstraints = false
        bars.isHidden = true
        NSLayoutConstraint.activate([
            bars.widthAnchor.constraint(equalToConstant: 16),
            bars.heightAnchor.constraint(equalToConstant: 15),
        ])

        let row = UIStackView(arrangedSubviews: [thumb, texts, tick, bars])
        row.spacing = 14
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)

        NSLayoutConstraint.activate([
            highlightView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 2),
            highlightView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -2),
            highlightView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            highlightView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            thumb.widthAnchor.constraint(equalToConstant: 66),
            thumb.heightAnchor.constraint(equalToConstant: 40),
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 22),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(name: String, subtitle: String, points: [Double], isCurrent: Bool, tint: UIColor) {
        nameLabel.text = name
        subtitleLabel.text = subtitle
        self.points = points
        self.tint = tint
        current = isCurrent
        highlightView.backgroundColor = isCurrent ? tint.withAlphaComponent(0.14) : .clear
        tick.tintColor = tint
        tick.isHidden = !isCurrent
        curveLayer.strokeColor = (isCurrent ? tint : UIColor.white.withAlphaComponent(0.7)).cgColor
        isAccessibilityElement = true
        accessibilityLabel = "\(name), \(subtitle)"
        accessibilityTraits = isCurrent ? [.button, .selected] : .button
        setNeedsLayout()
    }

    /// Washes the row in the accent and swaps the tick for the moving bars while its preset is being heard.
    func setAuditioned(_ auditioned: Bool) {
        highlightView.backgroundColor = auditioned ? tint.withAlphaComponent(0.3) : (current ? tint.withAlphaComponent(0.14) : .clear)
        tick.isHidden = auditioned || !current
        bars.isHidden = !auditioned
        bars.tintColor = tint
        bars.setAnimating(auditioned && !UIAccessibility.isReduceMotionEnabled)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let rect = CGRect(x: 7, y: 6, width: 52, height: 28)
        let path = UIBezierPath()
        for (index, decibels) in points.enumerated() {
            let x = rect.minX + rect.width * CGFloat(index) / CGFloat(max(points.count - 1, 1))
            let clamped = min(max(decibels, -9), 9)
            let y = rect.midY - CGFloat(clamped / 9) * rect.height / 2
            index == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
        }
        curveLayer.path = path.cgPath
    }
}

private final class EqualizerSectionHeaderCell: UITableViewCell {

    static let reuseIdentifier = "EqualizerSectionHeaderCell"
    private let label = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        label.font = .scaled(.caption2, size: 11, weight: .bold)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = UIColor.white.withAlphaComponent(0.42)
        label.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 18),
            label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .header
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String) {
        label.text = title.uppercased()
        accessibilityLabel = title
    }
}
