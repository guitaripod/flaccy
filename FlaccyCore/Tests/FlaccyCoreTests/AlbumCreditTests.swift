import XCTest
@testable import FlaccyCore

/// The Swift half of the album-credit parity proof. Every case here is
/// asserted again, with the same verdicts, in
/// `linux/shared/src/album_credit.rs` — a change to one language that forgets
/// the other fails in `scripts/test-shared.sh` rather than in a library.
final class AlbumCreditTests: XCTestCase {

    private func untagged(_ display: String, _ key: String) -> AlbumCredit.Member {
        AlbumCredit.Member(albumArtistTag: nil, artistDisplay: display, artistKey: key)
    }

    func testASoundtrackBySevenComposersIsVariousArtists() {
        let composers: [(String, Int)] = [
            ("Gerard K. Marino", 11),
            ("Mike Reagan", 6),
            ("Cris Velasco", 5),
            ("Ron Fish", 6),
            ("Junkie XL", 1),
            ("Shadows Fall", 1),
            ("George \"TraGiC\" Doman", 1),
        ]
        let members = composers.flatMap { name, count in
            (0..<count).map { _ in untagged(name, name.lowercased()) }
        }
        XCTAssertEqual(members.count, 31)
        XCTAssertEqual(AlbumCredit.credit(for: members), AlbumCredit.variousArtists)
    }

    func testOneGuestTrackDoesNotMakeACompilation() {
        var members = (0..<11).map { _ in untagged("50 Cent", "50cent") }
        members.append(untagged("Eminem", "eminem"))
        XCTAssertEqual(AlbumCredit.credit(for: members), "50 Cent")
    }

    func testAnEvenSplitIsACompilation() {
        var members = (0..<6).map { _ in untagged("Artist A", "artista") }
        members += (0..<6).map { _ in untagged("Artist B", "artistb") }
        XCTAssertEqual(AlbumCredit.credit(for: members), AlbumCredit.variousArtists)
    }

    func testTheAlbumArtistTagWinsOverTheDerivedCredit() {
        let members = [
            AlbumCredit.Member(
                albumArtistTag: "Various Artists", artistDisplay: "Aphex Twin", artistKey: "aphextwin"
            ),
            untagged("Aphex Twin", "aphextwin"),
            untagged("Aphex Twin", "aphextwin"),
        ]
        XCTAssertEqual(AlbumCredit.credit(for: members), AlbumCredit.variousArtists)
    }

    func testABlankAlbumArtistTagIsNotATag() {
        let members = [
            AlbumCredit.Member(
                albumArtistTag: "   ", artistDisplay: "Boards of Canada", artistKey: "boardsofcanada"
            ),
            untagged("Boards of Canada", "boardsofcanada"),
        ]
        XCTAssertEqual(AlbumCredit.credit(for: members), "Boards of Canada")
    }

    func testASingleArtistReleaseKeepsItsArtist() {
        let members = (0..<9).map { _ in untagged("Sigur Rós", "sigurros") }
        XCTAssertEqual(AlbumCredit.credit(for: members), "Sigur Rós")
    }

    func testNoMembersIsVariousArtists() {
        XCTAssertEqual(AlbumCredit.credit(for: []), AlbumCredit.variousArtists)
    }

    func testReleaseScopeIsTheContainingFolderAndNothingAtTheRoot() {
        XCTAssertEqual(
            AlbumCredit.releaseScope(relativePath: "God of War II/01.Main Titles.flac"),
            "God of War II"
        )
        XCTAssertEqual(
            AlbumCredit.releaseScope(relativePath: "Scores/God of War II/CD1/01.flac"),
            "Scores/God of War II/CD1"
        )
        XCTAssertNil(AlbumCredit.releaseScope(relativePath: "loose-track.flac"))
    }

    func testTheDominantShareMatchesTheLinuxClient() {
        XCTAssertEqual(AlbumCredit.dominantShare, 0.5)
        XCTAssertEqual(AlbumCredit.variousArtists, "Various Artists")
    }
}

/// The clustering half of the resolver: which tracks are even considered one
/// release. Mirrored in Rust by `db::cleanup_tests`' `resolve_album_credits`
/// cases, which run the same three shapes against a real database.
final class AlbumCreditResolveTests: XCTestCase {

    private func row(_ path: String, _ album: String, _ artist: String, tag: String? = nil)
        -> AlbumCredit.Row<String> {
        AlbumCredit.Row(
            id: path,
            albumTitleKey: album.lowercased(),
            relativePath: path,
            member: AlbumCredit.Member(
                albumArtistTag: tag, artistDisplay: artist, artistKey: artist.lowercased()
            )
        )
    }

    func testAFolderOfOneAlbumByManyArtistsResolvesToVariousArtists() {
        let composers = ["Gerard K. Marino", "Mike Reagan", "Cris Velasco", "Ron Fish", "Junkie XL"]
        let rows = (0..<20).map { index in
            row("God of War II/\(index).flac", "God Of War II", composers[index % composers.count])
        }
        let credits = AlbumCredit.resolve(rows)
        XCTAssertEqual(credits.count, 20)
        XCTAssertEqual(Set(credits.values), [AlbumCredit.variousArtists])
    }

    func testDiscsInSeparateFoldersResolveToTheSameCredit() {
        var rows: [AlbumCredit.Row<String>] = []
        for disc in 1...2 {
            for index in 0..<6 {
                rows.append(row(
                    "Anthology/CD\(disc)/\(index).flac",
                    "Anthology",
                    index.isMultiple(of: 2) ? "Artist A" : "Artist B"
                ))
            }
        }
        XCTAssertEqual(Set(AlbumCredit.resolve(rows).values), [AlbumCredit.variousArtists])
    }

    func testLooseFilesAtTheRootAreScopedByArtistNotByFolder() {
        let credits = AlbumCredit.resolve([
            row("a.flac", "Greatest Hits", "Artist A"),
            row("b.flac", "Greatest Hits", "Artist B"),
        ])
        XCTAssertEqual(credits["a.flac"], "Artist A")
        XCTAssertEqual(credits["b.flac"], "Artist B")
    }

    func testAnAlbumArtistTagBeatsTheDerivedCredit() {
        let rows = (0..<4).map { index in
            row("Split/\(index).flac", "Split", index < 2 ? "Artist A" : "Artist B", tag: "The Duo")
        }
        XCTAssertEqual(Set(AlbumCredit.resolve(rows).values), ["The Duo"])
    }

    func testTheWatchGroupsACompilationAsOneAlbum() {
        let composers = ["Composer A", "Composer B", "Composer C", "Composer D"]
        let items = composers.enumerated().map { index, name in
            MediaItem(
                relativePath: "Score/\(index).flac",
                title: "Track \(index)",
                artist: name,
                albumTitle: "Score",
                trackNumber: index + 1,
                duration: 100
            )
        }
        XCTAssertEqual(LibraryScanner.albums(from: items).count, 4)

        let albums = LibraryScanner.albums(from: LibraryScanner.resolvingCredits(items))
        XCTAssertEqual(albums.count, 1)
        XCTAssertEqual(albums.first?.artist, AlbumCredit.variousArtists)
        XCTAssertEqual(albums.first?.items.count, 4)
    }
}
