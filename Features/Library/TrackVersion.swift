import FlaccyCore
import FlaccyEngine
import Foundation

/// What a song's re-exports left behind, as the interface shows it: how many
/// versions it has had, when the newest arrived, and when its file was written.
nonisolated struct TrackVersion: Sendable, Equatable {

    let revision: Int
    let revisedAt: Date?
    let exportedAt: Date?

    init(revision: Int, revisedAt: Date?, exportedAt: Date?) {
        self.revision = revision
        self.revisedAt = revisedAt
        self.exportedAt = exportedAt
    }

    /// The versions of a song that has been re-exported, nil for one still on
    /// its first version.
    init?(track: Track) {
        guard track.revision > 1 else { return nil }
        self.init(
            revision: track.revision,
            revisedAt: track.revisedAt,
            exportedAt: track.fileModifiedMs.map { Date(timeIntervalSince1970: Double($0) / 1000) }
        )
    }

    func showsNewMix(now: Date = Date()) -> Bool {
        TrackRevision.showsNewMix(revisedAt: revisedAt, now: now)
    }

    /// `Exported 25 Oct 2026 at 14:02`, in the person's language and calendar.
    var exportedLine: String? {
        guard let exportedAt else { return nil }
        return String(localized: "Exported \(Self.exportedFormatter.string(from: exportedAt))")
    }

    private static let exportedFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

/// The words of the version interface, shared by every client row.
enum TrackVersionCopy {

    static var newMix: String { String(localized: "New mix") }

    /// A row's spoken label with `, New mix` after it while the chip shows.
    static func accessibilityLabel(_ label: String, newMix shows: Bool) -> String {
        shows ? "\(label), \(newMix)" : label
    }
}

extension Track {

    /// Whether the library says this song's newest version arrived inside the
    /// new-mix window, whatever revision this copy of the song was read with.
    var showsNewMix: Bool {
        Library.shared.version(of: self)?.showsNewMix() ?? false
    }
}
