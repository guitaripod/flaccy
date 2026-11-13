import FlaccyCore
import Foundation
import MidgarCore
import UIKit

/// One opening of Wi-Fi Transfer: the server while the screen is up, the address it shows, and the imports of what
/// arrived, one drop at a time. The imports outlive the screen, because each import task holds the session until it is
/// done: a drop still arriving when the screen closes keeps the songs that finished, the session imports them, then
/// deletes its staging folder.
@MainActor
final class WiFiTransferSession {

    enum Activity: Equatable {
        case idle
        case receiving(fileName: String, fraction: Double)
        case importing(count: Int)
        /// An import ended; `playable` counts the songs it brought in that can be played straight away.
        case reported(message: String, isFailure: Bool, playable: Int)
    }

    struct State: Equatable {
        /// What to type into the computer's browser, nil until the server listens on a local network.
        var address: String?
        var isOffline = false
        var listenerFailed = false
        var outOfSpace = false
        var received = 0
        var activity = Activity.idle
    }

    private(set) var state = State() {
        didSet { if state != oldValue { onChange?(state) } }
    }

    var onChange: ((State) -> Void)?
    /// The songs the last import brought in, in path order, for the screen's Play button.
    private(set) var lastImported: [Track] = []
    /// Where the question about replacing newer versions of songs is asked; nil once the screen is gone, and then both
    /// versions are kept.
    weak var presenter: UIViewController?

    private let token = WiFiTransferProtocol.makeToken()
    private let stagingRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("WiFiTransfer", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    private var server: WiFiTransferServer?
    private var monitor: WiFiAddressMonitor?
    private var host: String?
    private var port: UInt16?
    private var imports: Task<Void, Never>?
    private var queuedFolders: Set<String> = []
    private var isClosed = false

    func start() {
        guard monitor == nil, !isClosed else { return }
        let monitor = WiFiAddressMonitor { [weak self] address in self?.hostChanged(address) }
        self.monitor = monitor
        monitor.start()
        MidgarLog.info("Wi-Fi Transfer opened", category: .ui)
    }

    /// Listens again if the system closed the listener while the app was in the background.
    func resume() {
        server?.restartIfNeeded()
    }

    /// Stops the server, then imports whatever arrived whole in drops the page never finished, and deletes the staging
    /// folder once every import is done.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        monitor?.stop()
        server?.stop()
        let root = stagingRoot
        let previous = imports
        imports = Task {
            await previous?.value
            for folder in Self.stagedFolders(in: root) where !queuedFolders.contains(folder.path) {
                await importFolder(folder)
            }
            try? FileManager.default.removeItem(at: root)
            MidgarLog.info("Wi-Fi Transfer closed after \(state.received) songs", category: .ui)
        }
    }

    private func hostChanged(_ address: String?) {
        host = address
        state.isOffline = address == nil
        if address != nil, server == nil, !isClosed {
            startServer()
        }
        publishAddress()
    }

    private func startServer() {
        let server = WiFiTransferServer(
            token: token,
            stagingRoot: stagingRoot,
            page: Self.page(),
            acceptedExtensions: Library.audioExtensions.union(ImportPlan.lyricsExtensions),
            onEvent: { [weak self] event in self?.handle(event) }
        )
        self.server = server
        server.start()
    }

    private func publishAddress() {
        guard let host, let port else {
            state.address = nil
            return
        }
        state.address = WiFiTransferProtocol.address(host: host, port: port, token: token)
    }

    private func handle(_ event: WiFiTransferEvent) {
        switch event {
        case .listening(let port):
            self.port = port
            state.listenerFailed = false
            publishAddress()
        case .failed:
            port = nil
            state.listenerFailed = true
            publishAddress()
        case .receiving(let fileName, let received, let expected):
            let fraction = expected > 0 ? Double(received) / Double(expected) : 1
            state.activity = .receiving(fileName: fileName, fraction: fraction)
        case .received(let fileName):
            if Self.isSong(fileName) { state.received += 1 }
            state.outOfSpace = false
        case .dropped(_, let reason):
            if reason == .noSpace { state.outOfSpace = true }
            if case .receiving = state.activity { state.activity = .idle }
        case .batchFinished(let folder):
            enqueueImport(of: folder)
        }
    }

    private func enqueueImport(of folder: URL) {
        queuedFolders.insert(folder.path)
        let previous = imports
        imports = Task {
            await previous?.value
            await self.importFolder(folder)
        }
    }

    /// Imports a drop's songs as if they had been picked in Files: the drop's top-level files and folders, so a dropped
    /// album folder keeps its name in the library. The staged copies are deleted afterwards.
    private func importFolder(_ folder: URL) async {
        let items = Self.visibleItems(in: folder)
        guard !items.isEmpty else {
            try? FileManager.default.removeItem(at: folder)
            return
        }
        let count = Self.fileCount(in: folder)
        state.activity = .importing(count: count)
        let outcome = await Library.shared.importFiles(
            from: items,
            progress: { _ in },
            decideReplacements: { [weak self] prompt in
                await ImportReplacementAlert.ask(prompt, from: self?.presenter?.viewIfLoaded?.window == nil ? nil : self?.presenter)
            }
        )
        try? FileManager.default.removeItem(at: folder)
        lastImported = outcome.imported > 0 ? Self.tracks(placedBy: items) : []
        let report = ImportOutcomeCopy.report(outcome)
        state.activity = .reported(message: report.message, isFailure: report.isFailure, playable: lastImported.count)
        MidgarLog.info("Wi-Fi Transfer imported \(outcome.imported) of \(count), \(outcome.failed) failed", category: .ui)
    }

    /// The library's songs at the places an import put `items`: a dropped folder lands under its own name in the
    /// library root, a loose file at its own name there. The library has reloaded by the time the import returns.
    private static func tracks(placedBy items: [URL]) -> [Track] {
        guard let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return [] }
        let places = items.map { root.appendingPathComponent($0.lastPathComponent).standardizedFileURL.path }
        return Library.shared.allTracks
            .filter { track in
                let path = track.fileURL.standardizedFileURL.path
                return places.contains { path == $0 || path.hasPrefix($0 + "/") }
            }
            .sorted { $0.fileURL.path.localizedStandardCompare($1.fileURL.path) == .orderedAscending }
    }

    private static func stagedFolders(in root: URL) -> [URL] {
        visibleItems(in: root).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    private static func visibleItems(in folder: URL) -> [URL] {
        let items = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )
        return (items ?? []).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func fileCount(in folder: URL) -> Int {
        guard let walker = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        ) else { return 0 }
        return walker.allObjects.compactMap { $0 as? URL }.filter {
            isSong($0.lastPathComponent) && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }.count
    }

    /// Lyrics travel with the songs but are not songs, so they stay out of every count the screen shows.
    private static func isSong(_ fileName: String) -> Bool {
        Library.audioExtensions.contains((fileName as NSString).pathExtension.lowercased())
    }

    /// The upload page with the iPhone's language, its strings and the formats Flaccy imports filled in.
    static func page() -> Data {
        guard let url = Bundle.main.url(forResource: "WiFiTransferPage", withExtension: "html"),
              let template = try? String(contentsOf: url, encoding: .utf8)
        else {
            MidgarLog.error("Wi-Fi Transfer page is missing from the bundle", category: .ui)
            return Data()
        }
        let strings = (try? JSONSerialization.data(withJSONObject: WiFiTransferCopy.page, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let extensions = Library.audioExtensions.union(ImportPlan.lyricsExtensions).sorted()
        let list = (try? JSONSerialization.data(withJSONObject: extensions)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        let html = template
            .replacingOccurrences(of: "__FLACCY_STRINGS__", with: scriptSafe(strings))
            .replacingOccurrences(of: "__FLACCY_EXTENSIONS__", with: list)
            .replacingOccurrences(of: "__FLACCY_LANG__", with: language)
        return Data(html.utf8)
    }

    /// JSON is valid JavaScript, but a `</` inside a string would end the script element.
    private static func scriptSafe(_ json: String) -> String {
        json.replacingOccurrences(of: "</", with: "<\\/")
    }
}
