import Foundation

/// Who a *release* is filed under, as opposed to who performs each track.
///
/// Grouping albums by the per-track artist credit shatters every compilation,
/// soundtrack and split record into one album per performer: a 31-track score
/// written by seven composers becomes seven albums of four. The tag that exists
/// to prevent this is `ALBUMARTIST`, but most rips in the wild carry only
/// `ARTIST`, so honouring the tag alone fixes nothing for the libraries that
/// actually have the problem. This decides the credit from both — the tag when
/// it is there, and the shape of the release when it is not.
///
/// Mirrored in Rust as `linux/shared/src/album_credit.rs`; both halves are
/// pinned by tests asserting the same verdicts.
public enum AlbumCredit {

    /// The conventional credit for a release no single artist carries. Left
    /// unlocalized on purpose: it is also the literal string taggers write into
    /// `ALBUMARTIST`, so a derived credit and a tagged one have to collide.
    public static let variousArtists = "Various Artists"

    /// The share of a release's tracks one artist must exceed to be credited
    /// with the whole of it. At or below this, the release is a compilation.
    ///
    /// A strict majority is the line that separates "an album with a guest
    /// track" from "an album by several people": eleven of twelve tracks is
    /// plainly one artist's record, a six-six split plainly is not.
    public static let dominantShare = 0.5

    /// One track's claim on its release's credit.
    public struct Member: Sendable, Equatable {

        /// The `ALBUMARTIST` tag, already trimmed; nil or empty when absent.
        public let albumArtistTag: String?

        /// The performing credit as it should be displayed.
        public let artistDisplay: String

        /// The normalized key two performing credits share when they are the
        /// same artist — supplied by the caller because the clients fold
        /// collaborations and diacritics in their own (mirrored) hygiene code.
        public let artistKey: String

        public init(albumArtistTag: String?, artistDisplay: String, artistKey: String) {
            self.albumArtistTag = albumArtistTag
            self.artistDisplay = artistDisplay
            self.artistKey = artistKey
        }
    }

    /// The credit for one release's worth of tracks.
    ///
    /// A tag wins outright wherever one exists: a half-tagged album is best
    /// served by the answer somebody actually wrote down. Otherwise a single
    /// dominant performer takes the release and anything less concentrated is
    /// `variousArtists`.
    public static func credit(for members: [Member]) -> String {
        guard !members.isEmpty else { return variousArtists }

        let tags = members.compactMap { member -> String? in
            guard let tag = member.albumArtistTag?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !tag.isEmpty else { return nil }
            return tag
        }
        if !tags.isEmpty { return majority(of: tags) }

        var counts: [String: Int] = [:]
        for member in members { counts[member.artistKey, default: 0] += 1 }
        guard let (leadKey, leadCount) = counts.max(by: { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            return lhs.key > rhs.key
        }) else { return variousArtists }

        guard Double(leadCount) > Double(members.count) * dominantShare else { return variousArtists }
        return majority(of: members.filter { $0.artistKey == leadKey }.map(\.artistDisplay))
    }

    /// The folder a release occupies, which is the boundary a compilation's
    /// tracks share when their tags do not.
    ///
    /// Nil for a file sitting at the library root: a flat folder is not a
    /// release, and treating it as one would fuse two unrelated "Greatest Hits"
    /// into a single bogus compilation. Callers fall back to the performing
    /// artist there, which is the behaviour that predates this type.
    public static func releaseScope(relativePath: String) -> String? {
        let parent = (relativePath as NSString).deletingLastPathComponent
        return parent.isEmpty || parent == "/" ? nil : parent
    }

    /// One track as the resolver sees it: where it lives, what release it
    /// claims, and who plays on it.
    public struct Row<ID: Hashable>: Sendable where ID: Sendable {
        public let id: ID
        /// The album title, already normalized by the caller — album-title
        /// folding is app-side hygiene, not this type's business.
        public let albumTitleKey: String
        public let relativePath: String
        public let member: Member

        public init(id: ID, albumTitleKey: String, relativePath: String, member: Member) {
            self.id = id
            self.albumTitleKey = albumTitleKey
            self.relativePath = relativePath
            self.member = member
        }
    }

    /// The credit for every row, decided one release at a time.
    ///
    /// A credit cannot be decided per file — "eleven of thirty-one tracks" is
    /// only a fact about a whole release — so rows cluster by normalized album
    /// title within their containing folder. `Album/CD1` and `Album/CD2` resolve
    /// separately and then group back together under the one credit they agree
    /// on, while two unrelated "Greatest Hits" loose at the library root stay
    /// apart: `releaseScope` is nil there, so the performing artist scopes the
    /// cluster instead, which is the grouping that predates compilations.
    ///
    /// Mirrored in Rust by `Db::resolve_album_credits`.
    public static func resolve<ID>(_ rows: [Row<ID>]) -> [ID: String] {
        var clusters: [String: [Row<ID>]] = [:]
        for row in rows {
            let scope = releaseScope(relativePath: row.relativePath)
                ?? "\u{1}\(row.member.artistKey)"
            clusters["\(row.albumTitleKey)\u{0}\(scope)", default: []].append(row)
        }

        var credits: [ID: String] = [:]
        for cluster in clusters.values {
            let credit = self.credit(for: cluster.map(\.member))
            for row in cluster { credits[row.id] = credit }
        }
        return credits
    }

    private static func majority(of values: [String]) -> String {
        var counts: [String: Int] = [:]
        for value in values { counts[value, default: 0] += 1 }
        return counts.max { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            return lhs.key.count > rhs.key.count
        }?.key ?? values[0]
    }
}
