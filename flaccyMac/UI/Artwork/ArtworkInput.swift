import AppKit
import FlaccyCore
import UniformTypeIdentifiers

/// A picture a person handed the editor, before it has been read: a file on
/// disk, raw image bytes, or an address to fetch.
nonisolated enum ArtworkInput {
    case file(URL)
    case data(Data, label: String)
    case remote(URL)
}

nonisolated enum ArtworkInputError: Error {
    case tooLarge
    case unreadable
}

/// Reads what is on a pasteboard — the clipboard or a drag — as one artwork
/// input, preferring a real file over raw image bytes over an address, which is
/// the order that loses the least: a browser drag carries both the bytes and
/// the address, a Finder copy carries a file and a thumbnail.
nonisolated enum ArtworkInputReader {

    static let pasteboardTypes: [NSPasteboard.PasteboardType] = [.fileURL, .URL, .tiff, .png, .string]

    static func input(from pasteboard: NSPasteboard) -> ArtworkInput? {
        if let file = imageFile(in: pasteboard) { return .file(file) }
        if let data = imageData(in: pasteboard) {
            return .data(data, label: String(localized: "Clipboard"))
        }
        if let address = webAddress(in: pasteboard) { return .remote(address) }
        return textInput(in: pasteboard)
    }

    static func input(fromText text: String) -> ArtworkInput? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\n") else { return nil }
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() {
            if scheme == "https" || scheme == "http" { return .remote(url) }
            if scheme == "file", isImageFile(url) { return .file(url) }
        }
        let expanded = (trimmed as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: expanded)
        return isImageFile(url) ? .file(url) : nil
    }

    static func isImageFile(_ url: URL) -> Bool {
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else { return false }
        return UTType(filenameExtension: url.pathExtension.lowercased())?.conforms(to: .image) == true
    }

    /// Bytes and a name for the picture, with every address limited the way the
    /// online catalogs are: HTTPS only, timed out, and capped in size.
    static func load(_ input: ArtworkInput) async throws -> (data: Data, label: String) {
        switch input {
        case .file(let url):
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
            guard size <= ArtworkLocalRules.maximumFileBytes else { throw ArtworkInputError.tooLarge }
            let data = try await Task.detached { try Data(contentsOf: url) }.value
            return (data, url.deletingPathExtension().lastPathComponent)
        case .data(let data, let label):
            return (data, label)
        case .remote(let url):
            let data = try await OnlineArtworkSearch.fetchData(from: url)
            return (data, url.host ?? String(localized: "Web image"))
        }
    }

    private static func imageFile(in pasteboard: NSPasteboard) -> URL? {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return urls?.first(where: isImageFile)
    }

    private static func imageData(in pasteboard: NSPasteboard) -> Data? {
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pasteboard.data(forType: type), !data.isEmpty { return data }
        }
        return nil
    }

    private static func webAddress(in pasteboard: NSPasteboard) -> URL? {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: false]) as? [URL]
        return urls?.first { ["https", "http"].contains($0.scheme?.lowercased() ?? "") }
    }

    private static func textInput(in pasteboard: NSPasteboard) -> ArtworkInput? {
        pasteboard.string(forType: .string).flatMap(input(fromText:))
    }
}

/// Keeps a surface listening for a changed cover for exactly as long as it
/// holds this object, so a view that goes away never leaves an observer behind.
@MainActor
final class ArtworkChangeObserver {

    private var token: NSObjectProtocol?

    init(_ handler: @escaping @MainActor () -> Void) {
        token = NotificationCenter.default.addObserver(
            forName: AlbumArtworkCache.didChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { handler() }
        }
    }

    isolated deinit {
        if let token { NotificationCenter.default.removeObserver(token) }
    }
}
