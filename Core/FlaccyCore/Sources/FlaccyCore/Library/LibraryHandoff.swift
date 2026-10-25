import Foundation

/// What the old separate Mac app writes into the app group so the universal app can pick the library up on its first
/// launch: the app's whole data folder, the defaults it owns and a manifest. The export is built in a sibling folder
/// and renamed into place, so a reader sees the previous export or the new one and never half of either. The manifest
/// is the last file written, so a folder without a readable manifest is not an export.
public struct LibraryHandoffManifest: Codable, Equatable, Sendable {
    public let exportedAt: Date
    public let appVersion: String
    public let libraryFolderPath: String?

    public init(exportedAt: Date, appVersion: String, libraryFolderPath: String?) {
        self.exportedAt = exportedAt
        self.appVersion = appVersion
        self.libraryFolderPath = libraryFolderPath
    }
}

public enum LibraryHandoff {

    public static let folderName = "Handoff"
    public static let manifestName = "manifest.json"
    public static let defaultsName = "defaults.plist"
    public static let dataFolderPath = "Application Support/flaccy"
    public static let databaseName = "library.sqlite"
    public static let completionMarkerName = ".handoff-complete"

    private static let stagingPrefix = "\(folderName).tmp-"
    private static let importStagingInfix = ".handoff-import-"
    private static let databaseCompanions = ["-wal", "-shm"]
    private static let appleOwnedPrefixes = ["Apple", "NS", "AK", "com.apple.", "WebKit", "PayloadEvent"]

    public enum ImportOutcome {
        case noExport
        case databaseExists
        case imported(manifest: LibraryHandoffManifest, defaults: [String: Any])
    }

    public static func exportFolder(in container: URL) -> URL {
        container.appendingPathComponent(folderName, isDirectory: true)
    }

    /// The defaults worth carrying over: the app's own domain without the keys Apple's frameworks keep in it.
    public static func ownedDefaults(_ domain: [String: Any]) -> [String: Any] {
        domain.filter { key, value in
            !appleOwnedPrefixes.contains { key.hasPrefix($0) }
                && PropertyListSerialization.propertyList(value, isValidFor: .binary)
        }
    }

    /// Replaces the export in `container` with a copy of `dataFolder`, the defaults and a manifest. Never touches
    /// `dataFolder`. `excluding` names top-level items of the data folder to leave out. With `writeDatabase`, the
    /// database is not copied as files: the closure writes a consistent snapshot to the URL it is given.
    @discardableResult
    public static func export(
        dataFolder: URL,
        defaults: [String: Any],
        libraryFolderPath: String?,
        appVersion: String,
        into container: URL,
        excluding: Set<String> = [],
        writeDatabase: ((URL) throws -> Void)? = nil,
        now: Date = Date()
    ) throws -> LibraryHandoffManifest {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: container, withIntermediateDirectories: true)
        removeStaleStagingFolders(in: container)
        let staging = container.appendingPathComponent(stagingPrefix + UUID().uuidString, isDirectory: true)
        let stagedData = staging.appendingPathComponent(dataFolderPath, isDirectory: true)
        let final = exportFolder(in: container)
        do {
            try fileManager.createDirectory(at: stagedData, withIntermediateDirectories: true)
            var skipped = excluding
            if writeDatabase != nil {
                skipped.insert(databaseName)
                for companion in databaseCompanions { skipped.insert(databaseName + companion) }
            }
            try copyTree(
                from: dataFolder, to: stagedData, previous: exportFolder(in: container)
                    .appendingPathComponent(dataFolderPath, isDirectory: true),
                skipping: skipped
            )
            try writeDatabase?(stagedData.appendingPathComponent(databaseName))
            let defaultsData = try PropertyListSerialization.data(
                fromPropertyList: ownedDefaults(defaults), format: .binary, options: 0
            )
            try defaultsData.write(to: staging.appendingPathComponent(defaultsName))
            let manifest = LibraryHandoffManifest(
                exportedAt: now, appVersion: appVersion, libraryFolderPath: libraryFolderPath
            )
            try encoder.encode(manifest).write(to: staging.appendingPathComponent(manifestName))
            if fileManager.fileExists(atPath: final.path) {
                _ = try fileManager.replaceItemAt(final, withItemAt: staging)
            } else {
                try fileManager.moveItem(at: staging, to: final)
            }
            return manifest
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    /// The manifest of the export in `container`, nil when there is none or it cannot be read.
    public static func manifest(in container: URL) -> LibraryHandoffManifest? {
        let url = exportFolder(in: container).appendingPathComponent(manifestName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(LibraryHandoffManifest.self, from: data)
    }

    /// Copies the export's data folder into `dataFolder` and returns the exported defaults, unless the app already
    /// has its library: an existing library is never imported over. The copy is built in a sibling staging folder and
    /// moved into place only when it is complete, the database last, and the completion marker is written after
    /// that. A launch that finds an export, no marker and a database `libraryIsEmpty` calls empty (the empty one the
    /// app opens after a failed import) imports again; files already in `dataFolder` are kept.
    public static func importExport(
        from container: URL,
        into dataFolder: URL,
        libraryIsEmpty: (URL) -> Bool = { _ in false }
    ) throws -> ImportOutcome {
        guard let manifest = manifest(in: container) else { return .noExport }
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: completionMarker(in: dataFolder).path) { return .databaseExists }
        let database = dataFolder.appendingPathComponent(databaseName)
        if fileManager.fileExists(atPath: database.path) {
            guard libraryIsEmpty(database) else {
                recordCompletion(in: dataFolder, of: manifest)
                return .databaseExists
            }
        }
        let source = exportFolder(in: container).appendingPathComponent(dataFolderPath, isDirectory: true)
        let staging = try stageImport(of: source, beside: dataFolder)
        do {
            try moveIntoPlace(staging, dataFolder: dataFolder)
            try recordCompletionOrThrow(in: dataFolder, of: manifest)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
        try? fileManager.removeItem(at: staging)
        return .imported(manifest: manifest, defaults: readDefaults(in: container))
    }

    /// Whether the data folder records that its library came from an export or was already in use when one was found.
    public static func completionMarker(in dataFolder: URL) -> URL {
        dataFolder.appendingPathComponent(completionMarkerName)
    }

    private static func stageImport(of source: URL, beside dataFolder: URL) throws -> URL {
        let fileManager = FileManager.default
        let parent = dataFolder.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let prefix = importStagingPrefix(for: dataFolder)
        for name in (try? fileManager.contentsOfDirectory(atPath: parent.path)) ?? [] where name.hasPrefix(prefix) {
            try? fileManager.removeItem(at: parent.appendingPathComponent(name))
        }
        let staging = parent.appendingPathComponent(prefix + UUID().uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            try copyTree(from: source, to: staging, previous: nil, skipping: [])
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
        return staging
    }

    private static func importStagingPrefix(for dataFolder: URL) -> String {
        dataFolder.lastPathComponent + importStagingInfix
    }

    /// A data folder that does not exist yet is replaced by the staging folder in one rename. Otherwise the staged
    /// items that are missing move across one by one, the database files after the old ones are removed and the
    /// database itself last, so a launch that dies half way has no database and imports again.
    private static func moveIntoPlace(_ staging: URL, dataFolder: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: dataFolder.path) else {
            try fileManager.moveItem(at: staging, to: dataFolder)
            return
        }
        let databaseFiles = [databaseName] + databaseCompanions.map { databaseName + $0 }
        try mergeMissing(from: staging, into: dataFolder, skipping: Set(databaseFiles))
        for name in databaseFiles {
            try? fileManager.removeItem(at: dataFolder.appendingPathComponent(name))
        }
        for name in databaseFiles.reversed() {
            let staged = staging.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: staged.path) else { continue }
            try fileManager.moveItem(at: staged, to: dataFolder.appendingPathComponent(name))
        }
    }

    private static func mergeMissing(from staged: URL, into destination: URL, skipping: Set<String>) throws {
        let fileManager = FileManager.default
        for name in try fileManager.contentsOfDirectory(atPath: staged.path) where !skipping.contains(name) {
            let item = staged.appendingPathComponent(name)
            let target = destination.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            var targetIsDirectory: ObjCBool = false
            let targetExists = fileManager.fileExists(atPath: target.path, isDirectory: &targetIsDirectory)
            _ = fileManager.fileExists(atPath: item.path, isDirectory: &isDirectory)
            if !targetExists {
                try fileManager.moveItem(at: item, to: target)
            } else if isDirectory.boolValue && targetIsDirectory.boolValue {
                try mergeMissing(from: item, into: target, skipping: [])
            }
        }
    }

    private static func recordCompletionOrThrow(in dataFolder: URL, of manifest: LibraryHandoffManifest) throws {
        let stamp = ISO8601DateFormatter().string(from: manifest.exportedAt)
        try Data(stamp.utf8).write(to: completionMarker(in: dataFolder), options: .atomic)
    }

    private static func recordCompletion(in dataFolder: URL, of manifest: LibraryHandoffManifest) {
        try? recordCompletionOrThrow(in: dataFolder, of: manifest)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func readDefaults(in container: URL) -> [String: Any] {
        let url = exportFolder(in: container).appendingPathComponent(defaultsName)
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        else { return [:] }
        return plist as? [String: Any] ?? [:]
    }

    /// An export that died before its rename leaves its staging folder behind; nothing reads those, and the next
    /// export clears them.
    private static func removeStaleStagingFolders(in container: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: container.path)) ?? []
        for name in names where name.hasPrefix(stagingPrefix) {
            try? FileManager.default.removeItem(at: container.appendingPathComponent(name))
        }
    }

    /// Copies what is missing from `source` into `destination`, directory by directory. A file the previous export
    /// holds unchanged (same size, not older than the source) is hard-linked from it instead of copied again, so a
    /// library kept in the data folder is not rewritten at every launch. Items named in `skipping` are left out at the
    /// top level.
    private static func copyTree(from source: URL, to destination: URL, previous: URL?, skipping: Set<String>) throws {
        let fileManager = FileManager.default
        let names = try fileManager.contentsOfDirectory(atPath: source.path)
        for name in names where !skipping.contains(name) {
            let item = source.appendingPathComponent(name)
            let target = destination.appendingPathComponent(name)
            let earlier = previous?.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: item.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
                try copyTree(from: item, to: target, previous: earlier, skipping: [])
            } else if !fileManager.fileExists(atPath: target.path) {
                try placeFile(item, at: target, reusing: earlier)
            }
        }
    }

    private static func placeFile(_ item: URL, at target: URL, reusing earlier: URL?) throws {
        let fileManager = FileManager.default
        if let earlier, isUnchanged(item, since: earlier),
           (try? fileManager.linkItem(at: earlier, to: target)) != nil {
            return
        }
        try fileManager.copyItem(at: item, to: target)
    }

    private static func isUnchanged(_ item: URL, since earlier: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        guard let now = try? item.resourceValues(forKeys: keys),
              let then = try? earlier.resourceValues(forKeys: keys),
              let size = now.fileSize, size == then.fileSize,
              let modified = now.contentModificationDate, let exported = then.contentModificationDate
        else { return false }
        return exported >= modified
    }
}
