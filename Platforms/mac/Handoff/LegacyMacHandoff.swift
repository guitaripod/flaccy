#if LEGACY_MAC_HANDOFF
import AppKit
import Combine
import FlaccyCore
import FlaccyEngine
import MidgarCore

/// The last update of the separate Mac app: it hands its library to the universal app through the app group and
/// points people to it. Every launch writes a fresh export, the newest wins, and the app's own data is never touched.
nonisolated enum LegacyMacHandoff {

    static let newAppURL = URL(string: "macappstore://apps.apple.com/app/id6787493695")!

    enum ExportFailure: Error {
        case noContainer
    }

    /// Exports off the main thread, so the first window never waits for a copy of the library.
    static func exportAtLaunch() {
        Task.detached(priority: .utility) {
            do {
                let manifest = try exportLibrary()
                MidgarLog.info(
                    "Handoff: exported the library at \(manifest.exportedAt), folder \(manifest.libraryFolderPath ?? "none")",
                    category: .general
                )
            } catch ExportFailure.noContainer {
                MidgarLog.notice("Handoff: no app group container, nothing exported", category: .general)
            } catch {
                MidgarLog.error("Handoff: export failed: \(error.localizedDescription)", category: .general)
            }
        }
    }

    @discardableResult
    static func exportLibrary() throws -> LibraryHandoffManifest {
        guard let container = HandoffContainer.url else { throw ExportFailure.noContainer }
        let root = LibraryRoot.shared
        let chosenFolder = root.chosenFolderPath
        let previousFolder = LibraryHandoff.manifest(in: container)?.libraryFolderPath
        let usesChosenFolder = chosenFolder != nil || root.isFallbackActive
        return try LibraryHandoff.export(
            dataFolder: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("flaccy", isDirectory: true),
            defaults: ownDefaults,
            libraryFolderPath: chosenFolder ?? (root.isFallbackActive ? previousFolder : nil),
            appVersion: appVersion,
            into: container,
            excluding: usesChosenFolder ? [LibraryRoot.defaultFolderName] : [],
            writeDatabase: { try DatabaseManager.shared.writeSnapshot(to: $0) }
        )
    }

    static func openNewApp() {
        MidgarLog.info("Move card: opening the new Flaccy in the App Store", category: .ui)
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        NSWorkspace.shared.open(newAppURL)
    }

    private static var ownDefaults: [String: Any] {
        guard let identifier = Bundle.main.bundleIdentifier else { return [:] }
        return UserDefaults.standard.persistentDomain(forName: identifier) ?? [:]
    }

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(version) (\(build))"
    }
}

/// The card that says the Mac app has moved: a title, one paragraph, the button that opens the App Store and the one
/// that leaves it for later. It is the whole of the sheet shown once per launch and sits in the paywall where the
/// purchase buttons were.
final class LegacyMoveCardView: NSView {

    private let width: CGFloat

    init(width: CGFloat, onGetNewApp: @escaping () -> Void, onNotNow: @escaping () -> Void) {
        self.width = width
        self.onGetNewApp = onGetNewApp
        self.onNotNow = onNotNow
        super.init(frame: .zero)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private let onGetNewApp: () -> Void
    private let onNotNow: () -> Void

    private func build() {
        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 56).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 56).isActive = true

        let title = NSTextField(wrappingLabelWithString: String(localized: "Flaccy for Mac is now part of Flaccy"))
        title.font = .systemFont(ofSize: 18, weight: .bold)
        title.textColor = MacColors.primaryLabel
        title.preferredMaxLayoutWidth = width

        let body = NSTextField(wrappingLabelWithString: String(localized: "The new Flaccy works on your iPhone, Mac and Apple Watch with one purchase. Your library, playlists and Pro come with you."))
        body.font = .systemFont(ofSize: 13)
        body.textColor = MacColors.secondaryLabel
        body.preferredMaxLayoutWidth = width

        let getButton = NSButton(title: String(localized: "Get the New Flaccy"), target: self, action: #selector(getTapped))
        getButton.bezelStyle = .rounded
        getButton.controlSize = .large
        getButton.keyEquivalent = "\r"
        let notNowButton = NSButton(title: String(localized: "Not Now"), target: self, action: #selector(notNowTapped))
        notNowButton.bezelStyle = .rounded
        notNowButton.controlSize = .large
        let buttons = NSStackView(views: [getButton, notNowButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let stack = NSStackView(views: [icon, title, body, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(14, after: icon)
        stack.setCustomSpacing(16, after: body)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @objc private func getTapped() {
        onGetNewApp()
    }

    @objc private func notNowTapped() {
        onNotNow()
    }
}

/// The move card as a sheet over the main window.
final class LegacyMoveCardViewController: NSViewController {

    private enum Metrics {
        static let inset: CGFloat = 28
        static let cardWidth: CGFloat = 400
    }

    override func loadView() {
        let card = LegacyMoveCardView(
            width: Metrics.cardWidth,
            onGetNewApp: { [weak self] in
                LegacyMacHandoff.openNewApp()
                self?.dismiss(nil)
            },
            onNotNow: { [weak self] in
                MidgarLog.info("Move card: not now", category: .ui)
                self?.dismiss(nil)
            }
        )
        let container = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: container.topAnchor, constant: Metrics.inset),
            card.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Metrics.inset),
            card.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Metrics.inset),
            card.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Metrics.inset),
        ])
        view = container
    }

    override func cancelOperation(_ sender: Any?) {
        dismiss(nil)
    }
}

/// Shows the move card once per launch, as soon as the main window is free of other sheets and of the Debut.
enum LegacyMoveCardPresenter {

    private static var hasPresented = false

    static func presentOncePerLaunch(over windowController: NSWindowController?) {
        guard !hasPresented, shouldPresentAtLaunch else { return }
        hasPresented = true
        Task { @MainActor in
            for _ in 0..<60 {
                try? await Task.sleep(for: .seconds(1))
                guard let window = windowController?.window, let host = window.contentViewController else { return }
                guard window.isVisible, window.sheets.isEmpty,
                      MacLibrarySurfaceModel.shared.state.value.surface != .debut
                else { continue }
                MidgarLog.info("Move card: presented", category: .ui)
                host.presentAsSheet(LegacyMoveCardViewController())
                return
            }
        }
    }

    private static var shouldPresentAtLaunch: Bool {
        #if DEBUG
        let arguments = CommandLine.arguments
        if arguments.contains("--shot-legacy-move") { return true }
        return !arguments.contains { $0.hasPrefix("--shot") || $0.hasPrefix("--exercise") }
        #else
        return true
        #endif
    }
}
#endif
