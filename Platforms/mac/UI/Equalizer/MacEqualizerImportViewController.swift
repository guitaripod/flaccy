import AppKit
import FlaccyCore
import UniformTypeIdentifiers

/// The Mac's import sheet: paste or open an Equalizer APO or AutoEq profile,
/// see the curve it makes, and add it. The same text the iPhone and Linux read.
final class MacEqualizerImportViewController: NSViewController, NSTextViewDelegate {

    var onFinish: (() -> Void)?

    private let engine = EqualizerEngine.shared
    private let accent: NSColor
    private let textView = NSTextView()
    private let detectedLabel = NSTextField(labelWithString: "")
    private let warningLabel = NSTextField(wrappingLabelWithString: "")
    private let nameField = NSTextField()
    private let preview = MacCurveThumbnailView()
    private let addButton = NSButton()
    private let useButton = NSButton()
    private var parsed: EqualizerProfileText.Parsed?

    init(accent: NSColor) {
        self.accent = accent
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView()
        view = root

        let title = NSTextField(labelWithString: String(localized: "Import a Profile"))
        title.font = .systemFont(ofSize: 17, weight: .bold)

        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 150).isActive = true

        let paste = NSButton(title: String(localized: "Paste"), target: self, action: #selector(pasteText))
        let file = NSButton(title: String(localized: "Choose File…"), target: self, action: #selector(chooseFile))
        let site = NSButton(title: "autoeq.app", target: self, action: #selector(openSite))
        let sources = NSStackView(views: [paste, file, site])
        sources.spacing = 8

        detectedLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        detectedLabel.textColor = EqualizerTheme.lossless
        warningLabel.font = .systemFont(ofSize: 12)
        warningLabel.textColor = EqualizerTheme.caution
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.heightAnchor.constraint(equalToConstant: 84).isActive = true
        nameField.placeholderString = String(localized: "Name")

        addButton.title = String(localized: "Add to Presets")
        addButton.target = self
        addButton.action = #selector(addOnly)
        useButton.title = String(localized: "Add and Use")
        useButton.bezelStyle = .rounded
        useButton.keyEquivalent = "\r"
        useButton.target = self
        useButton.action = #selector(addAndUse)
        let cancel = NSButton(title: String(localized: "Cancel"), target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [cancel, NSView(), addButton, useButton])
        buttons.spacing = 8

        let column = NSStackView(views: [title, scroll, sources, detectedLabel, preview, warningLabel, nameField, buttons])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 12
        column.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            column.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            column.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            scroll.widthAnchor.constraint(equalTo: column.widthAnchor),
            preview.widthAnchor.constraint(equalTo: column.widthAnchor),
            nameField.widthAnchor.constraint(equalTo: column.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: column.widthAnchor),
            root.widthAnchor.constraint(equalToConstant: 520),
        ])
        reparse()
    }

    func textDidChange(_ notification: Notification) {
        reparse()
    }

    private func reparse() {
        parsed = EqualizerProfileText.parse(textView.string, fallbackName: String(localized: "Imported profile"))
        let hasProfile = parsed != nil
        for view in [detectedLabel, preview, nameField, addButton, useButton] { view.isHidden = !hasProfile }
        guard let parsed else {
            warningLabel.isHidden = true
            return
        }
        let filters = parsed.profile.kind == .graphic ? GraphicSolver.centres.count : parsed.profile.bands.count
        detectedLabel.stringValue = String(localized: "Profile detected · \(filters) filters")
        warningLabel.isHidden = parsed.droppedFilters == 0
        warningLabel.stringValue = String(localized: "\(parsed.droppedFilters) filters could not be kept: a profile holds up to 10, and Flaccy kept the strongest.")
        if nameField.stringValue.isEmpty { nameField.stringValue = parsed.profile.name }
        preview.set(bands: parsed.profile.resolvedBands(), accent: accent, isEnabled: true)
    }

    @objc private func pasteText() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        textView.string = text
        reparse()
    }

    @objc private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text]
        panel.allowsMultipleSelection = false
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            self?.textView.string = text
            self?.nameField.stringValue = url.deletingPathExtension().lastPathComponent
            self?.reparse()
        }
    }

    @objc private func openSite() {
        if let url = URL(string: "https://autoeq.app") { NSWorkspace.shared.open(url) }
    }

    @objc private func addOnly() {
        commit(use: false)
    }

    @objc private func addAndUse() {
        commit(use: true)
    }

    @objc private func cancel() {
        dismiss(nil)
    }

    private func commit(use: Bool) {
        guard let parsed else { return }
        var name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { name = parsed.profile.name }
        let outcome = engine.importProfile(text: textView.string, name: name, use: use)
        guard case .imported(let profile, _) = outcome else { return }
        if profile.name != name { engine.rename(profileID: profile.id, to: name) }
        onFinish?()
        dismiss(nil)
    }
}
