import Foundation

/// Every theme a client can wear: the built-in ones first, then the person's
/// own in folder order. Mirrored in Rust by `linux/src/theme/store.rs`.
public struct ThemeLibrary: Sendable {

    /// The id of Flaccy's own theme, the one an empty or unknown choice lands on.
    public static let defaultID = "flaccy"

    public static let documentName = "theme.toml"

    /// A folder in the themes folder that could not be used, and why.
    public struct Problem: Equatable, Sendable {
        public let folder: String
        public let reason: String

        public init(folder: String, reason: String) {
            self.folder = folder
            self.reason = reason
        }
    }

    public private(set) var packs: [ThemePack]
    public private(set) var problems: [Problem]

    /// Every built-in theme, parsed. A built-in that failed to parse would be
    /// a build mistake, which the golden test catches before it ships.
    public static let builtin: [ThemePack] = builtinDocuments.compactMap { entry in
        guard var pack = try? ThemePack.parse(id: entry.id, document: entry.document) else { return nil }
        pack.isBuiltin = true
        return pack
    }

    /// The built-in themes and every folder of `themesDirectory`. A folder
    /// named like a built-in theme does not replace it; it is listed as a
    /// problem so the person can rename it.
    public init(themesDirectory: URL? = nil) {
        packs = ThemeLibrary.builtin
        problems = []
        guard let themesDirectory else { return }
        for folder in ThemeLibrary.folders(in: themesDirectory) {
            let name = folder.lastPathComponent
            if has(id: name) {
                problems.append(
                    Problem(folder: name, reason: "Flaccy already has a theme with the id \"\(name)\". Rename the folder.")
                )
                continue
            }
            let file = folder.appendingPathComponent(ThemeLibrary.documentName)
            guard FileManager.default.fileExists(atPath: file.path) else {
                problems.append(Problem(folder: name, reason: "There is no \(ThemeLibrary.documentName) in this folder."))
                continue
            }
            do {
                let document = try String(contentsOf: file, encoding: .utf8)
                packs.append(try ThemePack.parse(id: name, document: document))
            } catch let refusal as ThemePack.Refusal {
                problems.append(Problem(folder: name, reason: refusal.reason))
            } catch {
                problems.append(
                    Problem(
                        folder: name,
                        reason: "\(ThemeLibrary.documentName) could not be read: \(error.localizedDescription)."
                    )
                )
            }
        }
    }

    private static func folders(in directory: URL) -> [URL] {
        let entries =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: []
            )) ?? []
        return entries
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    public func has(id: String) -> Bool {
        packs.contains { $0.id == id }
    }

    /// The theme with this id, or Flaccy's own when there is none: a theme
    /// folder that was deleted or renamed must not leave the app unstyled.
    public func pack(id: String) -> ThemePack {
        packs.first { $0.id == id } ?? packs.first { $0.id == ThemeLibrary.defaultID } ?? packs[0]
    }
}

extension ThemeLibrary {

    /// Why a copy of a theme could not be made.
    public struct CopyFailure: Error, Equatable, Sendable {
        public let reason: String
    }

    /// `document` with its top-level `name` replaced, leaving every other
    /// line and comment as the author wrote it.
    static func renamed(_ document: String, to name: String) -> String {
        let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var done = false
        var inTable = false
        var lines: [String] = []
        for line in document.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            if trimmed.hasPrefix("[") { inTable = true }
            let afterName = trimmed.hasPrefix("name") ? trimmed.dropFirst(4).drop { $0 == " " || $0 == "\t" } : nil
            if !done, !inTable, afterName?.hasPrefix("=") == true {
                lines.append("name = \"\(escaped)\"")
                done = true
            } else {
                lines.append(String(line))
            }
        }
        while lines.last == "" { lines.removeLast() }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A folder name no theme in `directory` or among the built-ins has yet.
    private func freeFolder(_ wanted: String, in directory: URL) -> String {
        var candidate = wanted
        var round = 2
        while has(id: candidate) || FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            candidate = "\(wanted)-\(round)"
            round += 1
        }
        return candidate
    }

    /// Writes a copy of the theme with this id into `directory` for the
    /// person to change: the same document under a "My …" name, with
    /// everything else its folder held. Returns the new theme's id.
    public func makeEditableCopy(of id: String, in directory: URL) throws(CopyFailure) -> String {
        let pack = pack(id: id)
        let name = "My \(pack.name)"
        let slug = ThemePack.slug(name)
        let copyID = freeFolder(slug.isEmpty ? "my-theme" : slug, in: directory)
        let folder = directory.appendingPathComponent(copyID)
        let source = directory.appendingPathComponent(pack.id)
        do {
            let document: String
            if let builtin = ThemeLibrary.builtinDocuments.first(where: { $0.id == pack.id }), pack.isBuiltin {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                document = builtin.document
            } else {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: source, to: folder)
                document = try String(contentsOf: source.appendingPathComponent(ThemeLibrary.documentName), encoding: .utf8)
            }
            try ThemeLibrary.renamed(document, to: name)
                .write(to: folder.appendingPathComponent(ThemeLibrary.documentName), atomically: true, encoding: .utf8)
        } catch {
            throw CopyFailure(reason: "The copy could not be written to \(folder.path): \(error.localizedDescription)")
        }
        return copyID
    }
}
