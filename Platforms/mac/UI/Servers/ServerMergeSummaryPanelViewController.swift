import AppKit
import MidgarCore

/// The one summary sheet after the first sync with data on both sides (docs/server/UX.md section 4): what the server
/// combined, in a sentence or two, and OK.
final class ServerMergeSummaryPanelViewController: NSViewController {

    private let summary: ServerMergeSummary

    init(summary: ServerMergeSummary) {
        self.summary = summary
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        if !summary.playlistNames.isEmpty {
            stack.addArrangedSubview(heading(String(localized: "We combined your playlists.")))
            stack.addArrangedSubview(line(Self.playlistsLine(summary.playlistNames), id: "mergeSummary.playlists"))
        }
        if summary.lovesAdded > 0 {
            stack.addArrangedSubview(line(Self.lovesLine(summary.lovesAdded), id: "mergeSummary.loves"))
        }
        let ok = PanelButton(title: String(localized: "OK")) { [weak self] in
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            self?.dismiss(nil)
        }
        ok.bezelStyle = .rounded
        ok.keyEquivalent = "\r"
        ok.setAccessibilityIdentifier("mergeSummary.ok")
        let buttons = NSStackView(views: [NSView(), ok])
        buttons.orientation = .horizontal
        stack.addArrangedSubview(buttons)
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            view.widthAnchor.constraint(equalToConstant: 420),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48),
        ])
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    private func heading(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.setAccessibilityRole(.staticText)
        return label
    }

    private func line(_ text: String, id: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 13)
        label.preferredMaxLayoutWidth = 372
        label.setAccessibilityIdentifier(id)
        return label
    }

    static func playlistsLine(_ names: [String]) -> String {
        let list = ListFormatter.localizedString(byJoining: names)
        return names.count == 1
            ? String(localized: "\(list) was on both devices and is now one.")
            : String(localized: "\(list) were on both devices and are now one each.")
    }

    static func lovesLine(_ count: Int) -> String {
        count == 1
            ? String(localized: "1 song is now loved here, from your other devices.")
            : String(localized: "\(count) songs are now loved here, from your other devices.")
    }
}

/// Shows the merge summary over the window in front when the reporter has one, once, after any sheet already on screen ends.
@MainActor
final class MacServerMergePresenter {

    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: ServerMergeReporter.didFinish, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.present() }
        }
    }

    private func present(attempt: Int = 0) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow, let host = window.contentViewController, window.attachedSheet == nil else {
            guard attempt < 20 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.present(attempt: attempt + 1) }
            return
        }
        guard let summary = ServerMergeReporter.shared.take() else { return }
        host.presentAsSheet(ServerMergeSummaryPanelViewController(summary: summary))
    }
}
