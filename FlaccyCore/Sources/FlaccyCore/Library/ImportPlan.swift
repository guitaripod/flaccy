import Foundation

/// What an import copies and where each file lands, decided before a byte
/// moves so every client files a picked folder the same way.
///
/// A picked file lands at the top of the import root under its own name. A
/// picked folder keeps its own name as the top folder with its whole tree
/// beneath it: album credits are resolved per containing folder, so flattening
/// a compilation's folder into one directory would split it back into one
/// album per performer. Lyrics sidecars travel with the music they sit beside
/// and nothing else does. A file that already lives inside the library is
/// counted, never copied into it a second time.
///
/// Mirrored in Rust as `linux/shared/src/import_plan.rs`; both halves are
/// pinned by tests asserting the same placements. Cloud placeholders are the
/// one Apple-only branch, because only Apple file providers leave them.
public enum ImportPlan {

    public static let lyricsExtensions: Set<String> = ["lrc", "elrc"]

    public enum Kind: Equatable, Sendable {
        case audio
        case lyrics
    }

    public struct Item: Equatable, Sendable {
        public let source: URL
        /// Slash-separated path under the import root.
        public let destination: String
        public let kind: Kind
        /// Nil for a cloud placeholder whose bytes are not on this device yet.
        public let size: Int64?

        public init(source: URL, destination: String, kind: Kind, size: Int64?) {
            self.source = source
            self.destination = destination
            self.kind = kind
            self.size = size
        }
    }

    public struct Plan: Equatable, Sendable {
        public let items: [Item]
        /// Audio files among the picked sources that already live inside the library.
        public let alreadyInLibrary: Int

        public init(items: [Item], alreadyInLibrary: Int) {
            self.items = items
            self.alreadyInLibrary = alreadyInLibrary
        }
    }

    public enum Placement: Equatable, Sendable {
        case copy(to: String)
        case alreadyPresent
    }

    public struct Placed: Equatable, Sendable {
        public let item: Item
        public let placement: Placement

        public init(item: Item, placement: Placement) {
            self.item = item
            self.placement = placement
        }
    }

    /// Walks every picked source. Hidden files and folders are skipped, a
    /// folder reached twice through a symlink is walked once, and the order is
    /// stable so two runs over the same tree plan the same copies.
    public static func plan(
        picked: [URL],
        libraryRoot: URL,
        audioExtensions: Set<String>,
        fileManager: FileManager = .default
    ) -> Plan {
        var walk = Walk(
            libraryRoot: canonicalPath(libraryRoot),
            audioExtensions: Set(audioExtensions.map { $0.lowercased() }),
            fileManager: fileManager
        )
        for source in picked {
            let name = source.lastPathComponent
            let top = name.isEmpty || name == "/" ? [] : [name]
            if isDirectory(source, fileManager: fileManager) {
                walk.walk(folder: source, components: top)
            } else {
                walk.add(
                    file: source,
                    name: name,
                    components: top,
                    size: size(of: source),
                    allowsLyrics: false,
                    insideLibrary: isInside(canonicalPath(source), walk.libraryRoot)
                )
            }
        }
        return Plan(items: walk.items, alreadyInLibrary: walk.alreadyInLibrary)
    }

    /// Where each planned file goes under `importRoot`, in plan order.
    ///
    /// The same relative path at the same size is the same file and is left
    /// alone, which is also what makes an interrupted import resumable: running
    /// it again copies only what is missing. A different file under a taken
    /// name gets the first free `name_n.ext` beside it, and a `name_n` that
    /// already holds this very file counts as present, so importing one folder
    /// twice never breeds a second copy. Destinations claimed earlier in the
    /// same import are taken too, so two picked files that share a name cannot
    /// land on each other.
    public static func placements(
        for plan: Plan,
        in importRoot: URL,
        fileManager: FileManager = .default
    ) -> [Placed] {
        var claimed: [String: Int64?] = [:]
        return plan.items.map { item in
            let placement = place(item, in: importRoot, claimed: claimed, fileManager: fileManager)
            if case .copy(let destination) = placement {
                claimed.updateValue(item.size, forKey: destination)
            }
            return Placed(item: item, placement: placement)
        }
    }

    /// `.Song.flac.icloud` is iCloud Drive's stand-in for a `Song.flac` whose
    /// bytes were never downloaded; a coordinated read of the real name fetches it.
    public static func materializedName(ofPlaceholder name: String) -> String? {
        let suffix = ".icloud"
        guard name.hasPrefix("."), name.hasSuffix(suffix), name.count > suffix.count + 1 else { return nil }
        return String(name.dropFirst().dropLast(suffix.count))
    }

    private enum Slot {
        case free
        case taken(size: Int64?)
    }

    private static func place(
        _ item: Item,
        in importRoot: URL,
        claimed: [String: Int64?],
        fileManager: FileManager
    ) -> Placement {
        let parent = (item.destination as NSString).deletingLastPathComponent
        let name = (item.destination as NSString).lastPathComponent
        let stem = (name as NSString).deletingPathExtension
        let pathExtension = (name as NSString).pathExtension
        var candidate = item.destination
        var counter = 0
        while true {
            switch slot(candidate, in: importRoot, claimed: claimed, fileManager: fileManager) {
            case .free:
                return .copy(to: candidate)
            case .taken(let occupant):
                guard let size = item.size, let occupant else { return .alreadyPresent }
                if occupant == size { return .alreadyPresent }
            }
            counter += 1
            let renamed = pathExtension.isEmpty ? "\(stem)_\(counter)" : "\(stem)_\(counter).\(pathExtension)"
            candidate = parent.isEmpty ? renamed : "\(parent)/\(renamed)"
        }
    }

    private static func slot(
        _ destination: String,
        in importRoot: URL,
        claimed: [String: Int64?],
        fileManager: FileManager
    ) -> Slot {
        if let size = claimed[destination] { return .taken(size: size) }
        let target = importRoot.appendingPathComponent(destination)
        guard fileManager.fileExists(atPath: target.path) else { return .free }
        return .taken(size: size(of: target))
    }

    private struct Walk {
        let libraryRoot: String
        let audioExtensions: Set<String>
        let fileManager: FileManager
        var items: [Item] = []
        var alreadyInLibrary = 0
        var visited: Set<String> = []

        init(libraryRoot: String, audioExtensions: Set<String>, fileManager: FileManager) {
            self.libraryRoot = libraryRoot
            self.audioExtensions = audioExtensions
            self.fileManager = fileManager
        }

        mutating func add(
            file: URL,
            name: String,
            components: [String],
            size: Int64?,
            allowsLyrics: Bool,
            insideLibrary: Bool
        ) {
            let pathExtension = (name as NSString).pathExtension.lowercased()
            let kind: Kind
            if audioExtensions.contains(pathExtension) {
                kind = .audio
            } else if allowsLyrics, ImportPlan.lyricsExtensions.contains(pathExtension) {
                kind = .lyrics
            } else {
                return
            }
            guard !insideLibrary else {
                if kind == .audio { alreadyInLibrary += 1 }
                return
            }
            items.append(Item(source: file, destination: components.joined(separator: "/"), kind: kind, size: size))
        }

        /// Whether a folder sits inside the library is decided once per folder
        /// rather than per file, because resolving a path costs a round trip
        /// per component on a network share.
        mutating func walk(folder: URL, components: [String]) {
            let canonical = ImportPlan.canonicalPath(folder)
            guard visited.insert(canonical).inserted else { return }
            let insideLibrary = ImportPlan.isInside(canonical, libraryRoot)
            let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
            guard let children = try? fileManager.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: keys, options: []
            ) else { return }
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = child.lastPathComponent
                if let realName = ImportPlan.materializedName(ofPlaceholder: name) {
                    add(
                        file: folder.appendingPathComponent(realName),
                        name: realName,
                        components: components + [realName],
                        size: nil,
                        allowsLyrics: true,
                        insideLibrary: insideLibrary
                    )
                    continue
                }
                guard !name.hasPrefix(".") else { continue }
                if ImportPlan.isDirectory(child, fileManager: fileManager) {
                    walk(folder: child, components: components + [name])
                } else {
                    add(
                        file: child,
                        name: name,
                        components: components + [name],
                        size: ImportPlan.size(of: child),
                        allowsLyrics: true,
                        insideLibrary: insideLibrary
                    )
                }
            }
        }
    }

    /// Reads the values `contentsOfDirectory` already fetched, and only asks
    /// the file system again for a symlink, whose target decides.
    private static func isDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        if let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
           values.isSymbolicLink != true,
           let isDirectory = values.isDirectory {
            return isDirectory
        }
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func size(of url: URL) -> Int64? {
        if let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey]),
           values.isSymbolicLink != true,
           let size = values.fileSize {
            return Int64(size)
        }
        guard let size = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            return nil
        }
        return Int64(size)
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func isInside(_ path: String, _ root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}
