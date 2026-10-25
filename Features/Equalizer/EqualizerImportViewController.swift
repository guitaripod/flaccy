import FlaccyCore
import UIKit
import UniformTypeIdentifiers

/// Brings an Equalizer APO or AutoEq profile in: paste it, choose the file, or
/// type it, and see the curve it makes before anything is added.
final class EqualizerImportViewController: UIViewController {

    private let engine = EqualizerEngine.shared
    private let accent: UIColor

    private let backdrop = AmbientPaletteBackdropView()
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private let textView = UITextView()
    private let placeholder = UILabel()
    private let previewCard = UIView()
    private let detectedLabel = UILabel()
    private let warningLabel = UILabel()
    private let previewLayer = CAShapeLayer()
    private let fillLayer = CAShapeLayer()
    private let previewCurve = UIView()
    private let nameField = UITextField()
    private let addButton = UIButton(type: .system)
    private let useButton = UIButton(type: .system)
    private var parsed: EqualizerProfileText.Parsed?
    private let initialText: String?

    init(accent: UIColor, initialText: String? = nil) {
        self.accent = accent
        self.initialText = initialText
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        overrideUserInterfaceStyle = .dark
        buildLayout()
        if let initialText { textView.text = initialText }
        reparse()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        drawPreview()
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
        back.accessibilityLabel = String(localized: "Back")
        back.addAction(UIAction { [weak self] _ in self?.navigationController?.popViewController(animated: true) }, for: .touchUpInside)
        let title = UILabel()
        title.text = String(localized: "Import")
        title.font = .equalizerRounded(.title1, size: 28, weight: .bold)
        title.adjustsFontForContentSizeCategory = true
        title.textColor = .white
        title.accessibilityTraits = .header
        let header = UIStackView(arrangedSubviews: [back, title, UIView()])
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
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -40),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -20),
        ])

        stack.addArrangedSubview(makeSourceBlock())
        stack.addArrangedSubview(makePreviewCard())
        stack.addArrangedSubview(makeHelpBlock())
    }

    private func makeSourceBlock() -> UIView {
        textView.backgroundColor = UIColor.white.withAlphaComponent(0.06)
        textView.layer.cornerRadius = 18
        textView.layer.cornerCurve = .continuous
        textView.layer.borderWidth = 1
        textView.layer.borderColor = UIColor.white.withAlphaComponent(0.1).cgColor
        textView.textColor = UIColor.white.withAlphaComponent(0.85)
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = UIEdgeInsets(top: 14, left: 12, bottom: 14, right: 12)
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.spellCheckingType = .no
        textView.delegate = self
        textView.accessibilityLabel = String(localized: "Profile text")
        textView.heightAnchor.constraint(equalToConstant: 150).isActive = true

        placeholder.text = String(localized: "Paste an Equalizer APO or AutoEq profile here, or use the buttons below.")
        placeholder.font = .scaled(.footnote, size: 13, weight: .regular)
        placeholder.adjustsFontForContentSizeCategory = true
        placeholder.textColor = UIColor.white.withAlphaComponent(0.4)
        placeholder.numberOfLines = 0
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        textView.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.topAnchor.constraint(equalTo: textView.topAnchor, constant: 14),
            placeholder.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 17),
            placeholder.trailingAnchor.constraint(equalTo: textView.trailingAnchor, constant: -17),
        ])

        let paste = pill(String(localized: "Paste"), symbol: "doc.on.clipboard") { [weak self] in self?.pasteFromClipboard() }
        let file = pill(String(localized: "Choose File"), symbol: "doc") { [weak self] in self?.chooseFile() }
        let site = pill("autoeq.app", symbol: "arrow.up.right") {
            if let url = URL(string: "https://autoeq.app") { UIApplication.shared.open(url) }
        }
        let buttons = UIStackView(arrangedSubviews: [paste, file, site])
        buttons.spacing = 8
        buttons.distribution = .fillEqually

        let block = UIStackView(arrangedSubviews: [textView, buttons])
        block.axis = .vertical
        block.spacing = 10
        return block
    }

    private func pill(_ title: String, symbol: String, action: @escaping () -> Void) -> UIView {
        let button = UIButton(type: .system)
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        configuration.imagePadding = 6
        configuration.baseForegroundColor = .white
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = UIFont.scaled(.subheadline, size: 14, weight: .semibold, maxSize: 18)
            return outgoing
        }
        button.configuration = configuration
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return LiquidGlass.capsule(hosting: button, height: 44)
    }

    private func makePreviewCard() -> UIView {
        previewCard.backgroundColor = UIColor.white.withAlphaComponent(0.06)
        previewCard.layer.cornerRadius = 22
        previewCard.layer.cornerCurve = .continuous
        previewCard.layer.borderWidth = 1
        previewCard.layer.borderColor = UIColor.white.withAlphaComponent(0.1).cgColor

        detectedLabel.font = .scaled(.footnote, size: 13.5, weight: .bold)
        detectedLabel.adjustsFontForContentSizeCategory = true
        detectedLabel.textColor = EqualizerTheme.lossless
        detectedLabel.numberOfLines = 0

        previewCurve.backgroundColor = UIColor.black.withAlphaComponent(0.22)
        previewCurve.layer.cornerRadius = 14
        previewCurve.layer.masksToBounds = true
        previewCurve.translatesAutoresizingMaskIntoConstraints = false
        previewCurve.heightAnchor.constraint(equalToConstant: 96).isActive = true
        fillLayer.fillColor = accent.withAlphaComponent(0.2).cgColor
        previewLayer.fillColor = nil
        previewLayer.strokeColor = accent.cgColor
        previewLayer.lineWidth = 2.4
        previewLayer.lineJoin = .round
        previewCurve.layer.addSublayer(fillLayer)
        previewCurve.layer.addSublayer(previewLayer)

        warningLabel.font = .scaled(.caption1, size: 12.5, weight: .regular)
        warningLabel.adjustsFontForContentSizeCategory = true
        warningLabel.textColor = EqualizerTheme.caution
        warningLabel.numberOfLines = 0

        nameField.placeholder = String(localized: "Name")
        nameField.textColor = .white
        nameField.font = .scaled(.body, size: 16, weight: .regular)
        nameField.backgroundColor = UIColor.white.withAlphaComponent(0.07)
        nameField.layer.cornerRadius = 14
        nameField.layer.cornerCurve = .continuous
        nameField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 14, height: 1))
        nameField.leftViewMode = .always
        nameField.clearButtonMode = .whileEditing
        nameField.autocapitalizationType = .words
        nameField.heightAnchor.constraint(equalToConstant: 48).isActive = true

        configure(addButton, title: String(localized: "Add to Presets"), filled: false)
        configure(useButton, title: String(localized: "Add and Use"), filled: true)
        addButton.addAction(UIAction { [weak self] _ in self?.commit(use: false) }, for: .touchUpInside)
        useButton.addAction(UIAction { [weak self] _ in self?.commit(use: true) }, for: .touchUpInside)
        let actions = UIStackView(arrangedSubviews: [addButton, useButton])
        actions.spacing = 8
        actions.distribution = .fillEqually

        let content = UIStackView(arrangedSubviews: [detectedLabel, previewCurve, warningLabel, nameField, actions])
        content.axis = .vertical
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        previewCard.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: previewCard.topAnchor, constant: 16),
            content.bottomAnchor.constraint(equalTo: previewCard.bottomAnchor, constant: -16),
            content.leadingAnchor.constraint(equalTo: previewCard.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: previewCard.trailingAnchor, constant: -16),
        ])
        return previewCard
    }

    private func configure(_ button: UIButton, title: String, filled: Bool) {
        var configuration = filled ? UIButton.Configuration.filled() : UIButton.Configuration.tinted()
        configuration.title = title
        configuration.cornerStyle = .capsule
        configuration.baseBackgroundColor = filled ? accent : .white
        configuration.baseForegroundColor = filled ? UIColor(red: 0.09, green: 0.04, blue: 0.08, alpha: 1) : .white
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 12, bottom: 14, trailing: 12)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = UIFont.scaled(.body, size: 15, weight: .bold, maxSize: 19)
            return outgoing
        }
        button.configuration = configuration
    }

    private func makeHelpBlock() -> UIView {
        let title = UILabel()
        title.text = String(localized: "Where do I get one?")
        title.font = .scaled(.body, size: 15, weight: .semibold)
        title.adjustsFontForContentSizeCategory = true
        title.textColor = .white
        let body = UILabel()
        body.text = String(localized: "AutoEq publishes corrections for hundreds of headphones. Copy a ParametricEQ.txt from autoeq.app, come back, and paste it here.")
        body.font = .scaled(.footnote, size: 13, weight: .regular)
        body.adjustsFontForContentSizeCategory = true
        body.textColor = UIColor.white.withAlphaComponent(0.66)
        body.numberOfLines = 0
        let block = UIStackView(arrangedSubviews: [title, body])
        block.axis = .vertical
        block.spacing = 4
        return block
    }

    // MARK: Parsing

    private func reparse() {
        let text = textView.text ?? ""
        placeholder.isHidden = !text.isEmpty
        parsed = EqualizerProfileText.parse(text, fallbackName: String(localized: "Imported profile"))
        previewCard.isHidden = parsed == nil
        guard let parsed else { return }
        let filters = parsed.profile.kind == .graphic ? GraphicSolver.centres.count : parsed.profile.bands.count
        detectedLabel.text = String(localized: "Profile detected · \(filters) filters")
        warningLabel.isHidden = parsed.droppedFilters == 0
        warningLabel.text = String(localized: "\(parsed.droppedFilters) filters could not be kept: a profile holds up to 10, and Flaccy kept the strongest.")
        if nameField.text?.isEmpty ?? true { nameField.text = parsed.profile.name }
        drawPreview()
    }

    private func drawPreview() {
        guard let parsed, previewCurve.bounds.width > 0 else { return }
        let rect = previewCurve.bounds
        let points = BiquadMath.curve(parsed.profile.resolvedBands(), points: 140)
        let line = UIBezierPath()
        let fill = UIBezierPath()
        fill.move(to: CGPoint(x: 0, y: rect.midY))
        for (index, decibels) in points.enumerated() {
            let x = rect.width * CGFloat(index) / CGFloat(points.count - 1)
            let y = CGFloat(EqualizerPlot.y(forDecibels: min(max(decibels, -12), 12), height: Double(rect.height)))
            index == 0 ? line.move(to: CGPoint(x: x, y: y)) : line.addLine(to: CGPoint(x: x, y: y))
            fill.addLine(to: CGPoint(x: x, y: y))
        }
        fill.addLine(to: CGPoint(x: rect.width, y: rect.midY))
        fill.close()
        previewLayer.path = line.cgPath
        fillLayer.path = fill.cgPath
        previewLayer.frame = rect
        fillLayer.frame = rect
    }

    private func pasteFromClipboard() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            ToastView.show(String(localized: "The clipboard has no text"), in: view)
            return
        }
        textView.text = text
        reparse()
    }

    private func chooseFile() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.plainText, .text], asCopy: true)
        picker.delegate = self
        present(picker, animated: true)
    }

    private func commit(use: Bool) {
        guard let parsed else { return }
        var name = nameField.text?.trimmingCharacters(in: .whitespaces) ?? ""
        if name.isEmpty { name = parsed.profile.name }
        let text = textView.text ?? ""
        let outcome = engine.importProfile(text: text, name: name, use: use)
        guard case .imported(let profile, _) = outcome else {
            ToastView.show(String(localized: "That isn’t a profile Flaccy can read. It understands Equalizer APO and AutoEq text."), in: view, style: .error)
            return
        }
        if profile.name != name { engine.rename(profileID: profile.id, to: name) }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        navigationController?.popViewController(animated: true)
    }
}

extension EqualizerImportViewController: UITextViewDelegate {

    func textViewDidChange(_ textView: UITextView) {
        reparse()
    }
}

extension EqualizerImportViewController: UIDocumentPickerDelegate {

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first, let text = try? String(contentsOf: url, encoding: .utf8) else {
            ToastView.show(String(localized: "Couldn't read that file as UTF-8 text. Equalizer APO and AutoEq profiles are plain text files."), in: view, style: .error)
            return
        }
        textView.text = text
        nameField.text = url.deletingPathExtension().lastPathComponent
        reparse()
    }
}
