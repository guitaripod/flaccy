import AppKit
import FlaccyCore
import MidgarCore

/// Appearance: the gallery of themes, the worn theme's colors, variant and
/// Albums view, the person's own choices over any theme, the interface scale,
/// and where their own themes go. Every control writes through `MacTheme` and
/// is set back from the look that results, so the page follows a view
/// switched on the Albums page or a theme changed on disk as well.
final class AppearanceSettingsPane: SettingsPane {

    private static let titleWidth: CGFloat = 116
    private static let coverShapes = ThemePack.CoverShape.allCases
    private static let albumsViews = ThemePack.AlbumsView.allCases
    private static let cornerIDs = ["sharp", "standard", "round"]
    private static let fontIDs = ["system-ui", "ui-rounded", "serif", "monospace"]
    private static let glowIDs = ["on", "off"]

    private static let cardsInRow = 3

    private let gallery = NSStackView()
    private let swatches = NSStackView()
    private let variantPopUp = NSPopUpButton()
    private let albumsPopUp = NSPopUpButton()
    private let coversPopUp = NSPopUpButton()
    private let cornersPopUp = NSPopUpButton()
    private let fontPopUp = NSPopUpButton()
    private let glowPopUp = NSPopUpButton()
    private let scaleStepper = NSStepper()
    private let scaleLabel = NSTextField(labelWithString: "")
    private let modeNote = NSTextField(wrappingLabelWithString: "")
    private let problemsLabel = NSTextField(wrappingLabelWithString: "")
    private let resetButton = NSButton(title: ThemeCopy.reset, target: nil, action: nil)
    private let folderButton = NSButton(title: ThemeCopy.openFolder, target: nil, action: nil)
    private let copyButton = NSButton(title: "", target: nil, action: nil)
    private var colorsRow: NSView?
    private var variantRow: NSView?
    private var shownGallery: [String] = []
    private var chooseFontIndex = 0

    override func buildForm() {
        formStack.addArrangedSubview(sectionLabel(ThemeCopy.theme))
        buildGallery()
        colorsRow = addRow([rowTitle(ThemeCopy.colors), swatches])
        variantRow = addRow([rowTitle(ThemeCopy.variant), popUp(variantPopUp, #selector(variantPicked), "themes.variant")])
        addRow([rowTitle(ThemeCopy.albumsView), popUp(albumsPopUp, #selector(albumsViewPicked), "themes.albumsView")])
        style(modeNote)
        addFullWidth(modeNote)
        formStack.addArrangedSubview(separator())

        formStack.addArrangedSubview(sectionLabel(ThemeCopy.ownChoices))
        addRow([rowTitle(ThemeCopy.covers), popUp(coversPopUp, #selector(coversPicked), "themes.covers")])
        addRow([rowTitle(ThemeCopy.corners), popUp(cornersPopUp, #selector(cornersPicked), "themes.corners")])
        addRow([rowTitle(ThemeCopy.font), popUp(fontPopUp, #selector(fontPicked), "themes.font")])
        addRow([rowTitle(ThemeCopy.windowGlow), popUp(glowPopUp, #selector(glowPicked), "themes.glow")])
        buildScaleRow()
        resetButton.bezelStyle = .rounded
        resetButton.target = self
        resetButton.action = #selector(resetTapped)
        resetButton.setAccessibilityIdentifier("themes.reset")
        addRow([resetButton])
        addFullWidth(explanation(ThemeCopy.ownChoicesFooter))
        formStack.addArrangedSubview(separator())

        formStack.addArrangedSubview(sectionLabel(ThemeCopy.ownThemes))
        folderButton.bezelStyle = .rounded
        folderButton.target = self
        folderButton.action = #selector(folderTapped)
        folderButton.setAccessibilityIdentifier("themes.folder")
        copyButton.bezelStyle = .rounded
        copyButton.target = self
        copyButton.action = #selector(copyTapped)
        copyButton.setAccessibilityIdentifier("themes.copy")
        addRow([folderButton, copyButton])
        addFullWidth(explanation(ThemeCopy.ownThemesFooter))
        style(problemsLabel)
        problemsLabel.textColor = .systemOrange
        addFullWidth(problemsLabel)
    }

    private func rowTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13)
        label.widthAnchor.constraint(equalToConstant: Self.titleWidth).isActive = true
        return label
    }

    private func style(_ note: NSTextField) {
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.isSelectable = true
    }

    private func popUp(_ button: NSPopUpButton, _ action: Selector, _ identifier: String) -> NSPopUpButton {
        button.target = self
        button.action = action
        button.setAccessibilityIdentifier(identifier)
        return button
    }

    private func buildGallery() {
        gallery.orientation = .vertical
        gallery.alignment = .leading
        gallery.spacing = 10
        swatches.orientation = .horizontal
        swatches.spacing = 4
        formStack.addArrangedSubview(gallery)
    }

    private func buildScaleRow() {
        scaleLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        scaleStepper.minValue = Double(MacInterfaceScale.minimum * 100)
        scaleStepper.maxValue = Double(MacInterfaceScale.maximum * 100)
        scaleStepper.increment = Double(MacInterfaceScale.step * 100)
        scaleStepper.target = self
        scaleStepper.action = #selector(scaleStepped)
        addRow([rowTitle(String(localized: "Interface scale")), scaleLabel, scaleStepper])
        addFullWidth(explanation(String(localized: "Zoom the whole window. ⌘= and ⌘- work anywhere; ⌘0 returns to actual size.")))
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        MacTheme.shared.reloadLibrary()
        render()
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChange), name: WornTheme.didChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(scaleChanged), name: .flaccyInterfaceScaleChanged, object: nil
        )
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func themeDidChange() {
        render()
    }

    @objc private func scaleChanged() {
        renderScale()
    }

    private func renderScale() {
        scaleLabel.stringValue = "\(MacInterfaceScale.percent)%"
        scaleStepper.doubleValue = Double(MacInterfaceScale.percent)
    }

    @objc private func scaleStepped() {
        MacInterfaceScale.set(CGFloat(scaleStepper.doubleValue) / 100)
    }

    /// Sets every control from the look that is on.
    private func render() {
        let theme = MacTheme.shared
        let look = theme.look
        renderGallery()
        renderSwatches()
        colorsRow?.isHidden = theme.isSystemLook || look.pack.schemes.count < 2
        variantRow?.isHidden = look.pack.variants.count < 2
        fill(variantPopUp, look.pack.variants.map { ThemeCopy.variantName($0.name) }, selected: look.variant ?? 0)
        let ownView = ThemePack.AlbumsView(rawValue: theme.wardrobe.albumsView)
        fill(
            albumsPopUp, [themesChoice(ThemeCopy.name(of: look.albums), own: ownView != nil)] + Self.albumsViews.map(ThemeCopy.name(of:)),
            selected: ownView.flatMap(Self.albumsViews.firstIndex(of:)).map { $0 + 1 } ?? 0
        )
        let ownCovers = ThemePack.CoverShape(rawValue: theme.wardrobe.covers)
        fill(
            coversPopUp, [themesChoice(ThemeCopy.name(of: look.covers), own: ownCovers != nil)] + Self.coverShapes.map(ThemeCopy.name(of:)),
            selected: ownCovers.flatMap(Self.coverShapes.firstIndex(of:)).map { $0 + 1 } ?? 0
        )
        let ownCorners = Self.cornerIDs.firstIndex(of: theme.wardrobe.corners)
        fill(
            cornersPopUp,
            [themesChoice(ThemeCopy.cornersName(look.corners), own: ownCorners != nil), ThemeCopy.sharp, ThemeCopy.standard, ThemeCopy.round],
            selected: ownCorners.map { $0 + 1 } ?? 0
        )
        renderFonts()
        let ownGlow = Self.glowIDs.firstIndex(of: theme.wardrobe.glow)
        let glowName = look.glow ? String(localized: "On") : String(localized: "Off")
        fill(
            glowPopUp, [themesChoice(glowName, own: ownGlow != nil), String(localized: "On"), String(localized: "Off")],
            selected: ownGlow.map { $0 + 1 } ?? 0
        )
        glowPopUp.isEnabled = !theme.isSystemLook
        let note = ThemeCopy.modeNote(for: look)
        modeNote.stringValue = note ?? ""
        modeNote.isHidden = note == nil
        resetButton.isEnabled = theme.wardrobe.hasOwnChoices || AlbumGridViewController.hasOwnZoom
        copyButton.title = ThemeCopy.copyToChange(look.pack.name)
        var problems = theme.library.problems.map { "\($0.folder): \($0.reason)" }
        problems += look.pack.warnings.map { "\(look.pack.name): \($0)" }
        problemsLabel.stringValue = problems.joined(separator: "\n")
        problemsLabel.isHidden = problems.isEmpty
        renderScale()
    }

    /// "Theme's Choice", naming what the theme chose while the person has
    /// not chosen for themselves.
    private func themesChoice(_ value: String, own: Bool) -> String {
        own ? ThemeCopy.themesChoice : "\(ThemeCopy.themesChoice) (\(value))"
    }

    private func fill(_ button: NSPopUpButton, _ titles: [String], selected: Int) {
        if button.itemTitles != titles {
            button.removeAllItems()
            for title in titles {
                button.menu?.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
            }
        }
        button.selectItem(at: min(max(selected, 0), max(titles.count - 1, 0)))
    }

    private func renderFonts() {
        let chosen = MacTheme.shared.wardrobe.font
        var titles = [
            ThemeCopy.themesChoice, ThemeCopy.fontSystem, ThemeCopy.fontRounded, ThemeCopy.fontSerif,
            ThemeCopy.fontMonospaced,
        ]
        var selected = Self.fontIDs.firstIndex(of: chosen).map { $0 + 1 } ?? 0
        if !chosen.isEmpty, !Self.fontIDs.contains(chosen) {
            titles.append(chosen)
            selected = titles.count - 1
        }
        titles.append(ThemeCopy.fontChoose)
        chooseFontIndex = titles.count - 1
        fill(fontPopUp, titles, selected: selected)
    }

    /// One card for each theme, rebuilt only when the themes themselves or
    /// what they are worn with changed.
    private func renderGallery() {
        let theme = MacTheme.shared
        let worn = theme.look.pack.id
        let looks = theme.library.packs.map { pack in
            pack.id == worn ? theme.look : theme.wardrobe.look(wearing: pack, in: theme.library)
        }
        let signature = looks.map { "\($0.pack.id)|\($0.pack.name)|\($0.wornScheme.id)|\($0.albums.id)|\($0.covers.id)|\($0.corners)" }
        if signature != shownGallery {
            shownGallery = signature
            gallery.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for start in stride(from: 0, to: looks.count, by: Self.cardsInRow) {
                let cards = looks[start..<min(start + Self.cardsInRow, looks.count)].map { look in
                    let id = look.pack.id
                    return MacThemeCard(look: look, isChosen: id == worn) {
                        MacTheme.shared.edit { $0.wear(pack: id) }
                    }
                }
                let row = NSStackView(views: cards)
                row.orientation = .horizontal
                row.alignment = .top
                row.spacing = 6
                gallery.addArrangedSubview(row)
            }
        }
        for case let row as NSStackView in gallery.arrangedSubviews {
            for case let card as MacThemeCard in row.arrangedSubviews {
                card.isChosen = card.accessibilityIdentifier() == "themes.card.\(worn)"
                card.needsDisplay = true
            }
        }
    }

    private func renderSwatches() {
        let look = MacTheme.shared.look
        swatches.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, scheme) in look.pack.schemes.enumerated() {
            let seed: ThemeColor =
                switch scheme.accent {
                case .fixed(let color): color
                case .artwork: ThemeLook.brandSeed
                }
            let id = scheme.id
            swatches.addArrangedSubview(MacThemeSwatch(
                name: scheme.name, color: NSColor(ThemeInk(seed)), isChosen: index == look.scheme
            ) {
                MacTheme.shared.edit { $0.wear(scheme: id) }
            })
        }
    }

    @objc private func variantPicked() {
        let variants = MacTheme.shared.look.pack.variants
        guard variants.indices.contains(variantPopUp.indexOfSelectedItem) else { return }
        let id = variants[variantPopUp.indexOfSelectedItem].id
        MacTheme.shared.edit { $0.wear(variant: id) }
    }

    @objc private func albumsViewPicked() {
        let index = albumsPopUp.indexOfSelectedItem
        MacTheme.shared.edit { $0.show(albumsAs: index <= 0 ? "" : Self.albumsViews[index - 1].id) }
    }

    @objc private func coversPicked() {
        let index = coversPopUp.indexOfSelectedItem
        MacTheme.shared.edit { $0.covers = index <= 0 ? "" : Self.coverShapes[index - 1].id }
    }

    @objc private func cornersPicked() {
        let index = cornersPopUp.indexOfSelectedItem
        MacTheme.shared.edit { $0.corners = index <= 0 ? "" : Self.cornerIDs[index - 1] }
    }

    @objc private func glowPicked() {
        let index = glowPopUp.indexOfSelectedItem
        MacTheme.shared.edit { $0.glow = index <= 0 ? "" : Self.glowIDs[index - 1] }
    }

    @objc private func fontPicked() {
        let index = fontPopUp.indexOfSelectedItem
        if index == chooseFontIndex {
            renderFonts()
            let manager = NSFontManager.shared
            manager.target = self
            manager.action = #selector(changeFont(_:))
            manager.orderFrontFontPanel(self)
        } else if index >= 1, index <= Self.fontIDs.count {
            MacTheme.shared.edit { $0.font = Self.fontIDs[index - 1] }
        } else if index == 0 {
            MacTheme.shared.edit { $0.font = "" }
        }
    }

    /// The font panel's answer: the family of whatever was picked in it.
    @objc func changeFont(_ sender: NSFontManager?) {
        guard let family = sender?.convert(.systemFont(ofSize: 13)).familyName, !family.isEmpty else { return }
        MacTheme.shared.edit { $0.font = family }
    }

    @objc private func resetTapped() {
        AlbumGridViewController.forgetZoom()
        if MacTheme.shared.wardrobe.hasOwnChoices {
            MacTheme.shared.edit { $0.resetOwnChoices() }
        } else {
            MacTheme.shared.apply()
        }
    }

    @objc private func folderTapped() {
        let folder = MacTheme.themesDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    @objc private func copyTapped() {
        do {
            let folder = try MacTheme.shared.copyWornThemeToChange()
            NSWorkspace.shared.activateFileViewerSelecting([folder.appendingPathComponent(ThemeLibrary.documentName)])
        } catch {
            MidgarLog.error("Theme copy failed: \(error.reason)", category: .ui)
            MacToast.show(ThemeCopy.copyFailed, style: .error, in: view.window)
        }
    }
}
