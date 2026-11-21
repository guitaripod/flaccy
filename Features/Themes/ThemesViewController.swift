import FlaccyCore
import MidgarCore
import UIKit

/// Settings › Appearance › Theme: the gallery of themes, the worn theme's
/// colors, variant and Albums view, the person's own choices over any theme,
/// and where their own themes go. Every control writes through `AppTheme` and
/// is set back from the look that results, so the page follows a view switched
/// in the Library or a theme changed on disk as well.
final class ThemesViewController: UITableViewController {

    private enum Section: Int, CaseIterable {
        case gallery
        case theme
        case own
        case yours
    }

    private enum Row: Hashable {
        case gallery
        case colors
        case variant
        case albumsView
        case covers
        case corners
        case font
        case reset
        case folder
        case problem(String)
    }

    private let selectionFeedback = UISelectionFeedbackGenerator()
    private let impactLight = UIImpactFeedbackGenerator(style: .light)
    private var rows: [[Row]] = []

    init() {
        super.init(style: .insetGrouped)
        title = ThemeCopy.theme
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.backgroundColor = .flaccyGroupedBackground
        tableView.register(ThemeGalleryCell.self, forCellReuseIdentifier: ThemeGalleryCell.reuseID)
        tableView.register(ThemeSwatchesCell.self, forCellReuseIdentifier: ThemeSwatchesCell.reuseID)
        tableView.register(ThemeChoiceCell.self, forCellReuseIdentifier: ThemeChoiceCell.reuseID)
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "plain")
        tableView.accessibilityIdentifier = "themes.table"
        rows = buildRows()
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChange), name: AppTheme.didChange, object: nil
        )
    }

    @objc private func themeDidChange() {
        rows = buildRows()
        tableView.reloadData()
    }

    private func buildRows() -> [[Row]] {
        let theme = AppTheme.shared
        var themeRows: [Row] = []
        if theme.look.pack.schemes.count > 1 { themeRows.append(.colors) }
        if theme.look.pack.variants.count > 1 { themeRows.append(.variant) }
        themeRows.append(.albumsView)
        return [
            [.gallery],
            themeRows,
            [.covers, .corners, .font, .reset],
            [.folder] + theme.library.problems.map { .problem("\($0.folder): \($0.reason)") },
        ]
    }

    override func numberOfSections(in tableView: UITableView) -> Int { rows.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows[section].count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section) {
        case .own: ThemeCopy.ownChoices
        case .yours: ThemeCopy.ownThemes
        default: nil
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section) {
        case .theme: ThemeCopy.modeNote(for: AppTheme.shared.look)
        case .own: ThemeCopy.ownChoicesFooter
        case .yours: ThemeCopy.ownThemesFooter
        default: nil
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let theme = AppTheme.shared
        switch rows[indexPath.section][indexPath.row] {
        case .gallery:
            let cell = tableView.dequeueReusableCell(withIdentifier: ThemeGalleryCell.reuseID, for: indexPath) as! ThemeGalleryCell
            cell.configure(library: theme.library, wardrobe: theme.wardrobe) { [weak self] pack in
                self?.selectionFeedback.selectionChanged()
                AppTheme.shared.edit { $0.wear(pack: pack) }
            }
            return cell
        case .colors:
            let cell = tableView.dequeueReusableCell(withIdentifier: ThemeSwatchesCell.reuseID, for: indexPath) as! ThemeSwatchesCell
            cell.configure(look: theme.look) { [weak self] scheme in
                self?.selectionFeedback.selectionChanged()
                AppTheme.shared.edit { $0.wear(scheme: scheme) }
            }
            return cell
        case .variant:
            let variants = theme.look.pack.variants
            return choiceCell(
                at: indexPath, title: ThemeCopy.variant, identifier: "themes.variant",
                options: variants.map { ThemeCopy.variantName($0.name) },
                selected: theme.look.variant ?? 0
            ) { index in
                AppTheme.shared.edit { $0.wear(variant: variants[index].id) }
            }
        case .albumsView:
            let views = ThemePack.AlbumsView.allCases
            let own = ThemePack.AlbumsView(rawValue: theme.wardrobe.albumsView)
            return choiceCell(
                at: indexPath, title: ThemeCopy.albumsView, identifier: "themes.albumsView",
                options: [ThemeCopy.themesChoice] + views.map(ThemeCopy.name(of:)),
                selected: own.flatMap(views.firstIndex(of:)).map { $0 + 1 } ?? 0,
                themesValue: own == nil ? ThemeCopy.name(of: theme.look.albums) : nil
            ) { index in
                AppTheme.shared.edit { $0.show(albumsAs: index == 0 ? "" : views[index - 1].id) }
            }
        case .covers:
            let shapes = ThemePack.CoverShape.allCases
            let own = ThemePack.CoverShape(rawValue: theme.wardrobe.covers)
            return choiceCell(
                at: indexPath, title: ThemeCopy.covers, identifier: "themes.covers",
                options: [ThemeCopy.themesChoice] + shapes.map(ThemeCopy.name(of:)),
                selected: own.flatMap(shapes.firstIndex(of:)).map { $0 + 1 } ?? 0,
                themesValue: own == nil ? ThemeCopy.name(of: theme.look.covers) : nil
            ) { index in
                AppTheme.shared.edit { $0.covers = index == 0 ? "" : shapes[index - 1].id }
            }
        case .corners:
            let ids = ["sharp", "standard", "round"]
            return choiceCell(
                at: indexPath, title: ThemeCopy.corners, identifier: "themes.corners",
                options: [ThemeCopy.themesChoice, ThemeCopy.sharp, ThemeCopy.standard, ThemeCopy.round],
                selected: ids.firstIndex(of: theme.wardrobe.corners).map { $0 + 1 } ?? 0,
                themesValue: theme.wardrobe.corners.isEmpty ? ThemeCopy.cornersName(theme.look.corners) : nil
            ) { index in
                AppTheme.shared.edit { $0.corners = index == 0 ? "" : ids[index - 1] }
            }
        case .font:
            let ids = ["system-ui", "ui-rounded", "serif", "monospace"]
            let chosen = theme.wardrobe.font
            var options = [ThemeCopy.themesChoice, ThemeCopy.fontSystem, ThemeCopy.fontRounded, ThemeCopy.fontSerif, ThemeCopy.fontMonospaced]
            var selected = ids.firstIndex(of: chosen).map { $0 + 1 } ?? 0
            if !chosen.isEmpty, !ids.contains(chosen) {
                options.append(chosen)
                selected = options.count - 1
            }
            options.append(ThemeCopy.fontChoose)
            let chooseIndex = options.count - 1
            return choiceCell(
                at: indexPath, title: ThemeCopy.font, identifier: "themes.font", options: options, selected: selected
            ) { [weak self] index in
                if index == chooseIndex {
                    self?.presentFontPicker()
                } else if index >= 1, index <= ids.count {
                    AppTheme.shared.edit { $0.font = ids[index - 1] }
                } else if index == 0 {
                    AppTheme.shared.edit { $0.font = "" }
                }
            }
        case .reset:
            let cell = tableView.dequeueReusableCell(withIdentifier: "plain", for: indexPath)
            var content = cell.defaultContentConfiguration()
            content.text = ThemeCopy.reset
            let enabled = theme.wardrobe.hasOwnChoices
            content.textProperties.color = enabled ? .systemRed : .flaccyTertiaryLabel
            cell.contentConfiguration = content
            cell.selectionStyle = enabled ? .default : .none
            cell.accessibilityIdentifier = "themes.reset"
            cell.accessibilityTraits = enabled ? .button : [.button, .notEnabled]
            return cell
        case .folder:
            let cell = tableView.dequeueReusableCell(withIdentifier: "plain", for: indexPath)
            var content = cell.defaultContentConfiguration()
            content.text = ThemeCopy.openFolder
            content.image = UIImage(systemName: "folder")
            content.textProperties.color = .tintColor
            cell.contentConfiguration = content
            cell.selectionStyle = .default
            cell.accessibilityIdentifier = "themes.folder"
            cell.accessibilityTraits = .button
            return cell
        case .problem(let text):
            let cell = tableView.dequeueReusableCell(withIdentifier: "plain", for: indexPath)
            var content = cell.defaultContentConfiguration()
            content.text = text
            content.textProperties.font = .preferredFont(forTextStyle: .footnote)
            content.textProperties.color = .flaccySecondaryLabel
            content.image = UIImage(systemName: "exclamationmark.triangle.fill")
            content.imageProperties.tintColor = .systemOrange
            cell.contentConfiguration = content
            cell.selectionStyle = .none
            cell.accessibilityTraits = .staticText
            return cell
        }
    }

    private func choiceCell(
        at indexPath: IndexPath, title: String, identifier: String, options: [String], selected: Int,
        themesValue: String? = nil, onPick: @escaping (Int) -> Void
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: ThemeChoiceCell.reuseID, for: indexPath) as! ThemeChoiceCell
        cell.configure(title: title, options: options, selected: selected, themesValue: themesValue) { [weak self] index in
            self?.selectionFeedback.selectionChanged()
            onPick(index)
        }
        cell.accessibilityIdentifier = identifier
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch rows[indexPath.section][indexPath.row] {
        case .reset:
            guard AppTheme.shared.wardrobe.hasOwnChoices else { return }
            impactLight.impactOccurred()
            AppTheme.shared.edit { $0.resetOwnChoices() }
        case .folder:
            impactLight.impactOccurred()
            openThemesFolder()
        default:
            break
        }
    }

    /// Makes the themes folder if it is not there yet and shows it in Files,
    /// where a theme's folder can be dropped in.
    private func openThemesFolder() {
        let folder = AppTheme.themesDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var components = URLComponents(url: folder, resolvingAgainstBaseURL: false)
        components?.scheme = "shareddocuments"
        guard let url = components?.url else { return }
        UIApplication.shared.open(url) { [weak self] opened in
            guard !opened, let self else { return }
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            ToastView.show(ThemeCopy.folderDidNotOpen, in: self.view, style: .error)
            MidgarLog.notice("Themes folder did not open in Files", category: .ui)
        }
    }

    private func presentFontPicker() {
        let configuration = UIFontPickerViewController.Configuration()
        configuration.includeFaces = false
        let picker = UIFontPickerViewController(configuration: configuration)
        picker.delegate = self
        present(picker, animated: true)
    }
}

extension ThemesViewController: UIFontPickerViewControllerDelegate {

    func fontPickerViewControllerDidPickFont(_ viewController: UIFontPickerViewController) {
        guard let family = viewController.selectedFontDescriptor?.object(forKey: .family) as? String else { return }
        selectionFeedback.selectionChanged()
        AppTheme.shared.edit { $0.font = family }
    }
}
