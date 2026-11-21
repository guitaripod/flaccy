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
