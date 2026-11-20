import XCTest
@testable import FlaccyCore

final class PlaylistSuggestionsTests: XCTestCase {

    private func song(
        _ file: String, _ title: String, _ artist: String, _ album: String, loved: Bool = false, plays: Int = 0
    ) -> PlaylistSuggestions.Song {
        PlaylistSuggestions.Song(file: file, title: title, artist: artist, album: album, loved: loved, playCount: plays)
    }

    private var playlist: [PlaylistSuggestions.Song] {
        [
            song("p1", "Glass", "Nova Bloom", "Tides"),
            song("p2", "Shore", "Nova Bloom", "Tides"),
            song("p3", "Ember", "Ash Coast", "Kiln"),
        ]
    }

    private var library: [PlaylistSuggestions.Song] {
        playlist + [
            song("n1", "Undertow", "Nova Bloom", "Tides"),
            song("n2", "Harbor", "Nova Bloom", "Lanterns", loved: true),
            song("n3", "Reef", "Nova Bloom", "Lanterns", plays: 40),
            song("a1", "Cinder", "Ash Coast", "Kiln"),
            song("s1", "Drift", "Pale Orchard", "Low Sun"),
            song("s2", "Glass", "nova bloom ", "Tides (Deluxe)"),
            song("x1", "Elsewhere", "Unrelated", "Other"),
        ]
    }

    func testS1AnEmptyPlaylistSuggestsNothing() {
        XCTAssertEqual(PlaylistSuggestions.suggest(for: [], library: library, similar: [:]), [])
    }

    func testS2TheRankingWeighsShareAlbumLoveAndPlays() {
        let ranked = PlaylistSuggestions.ranking(for: playlist, library: library, similar: [:])
        XCTAssertEqual(ranked, ["n2", "n1", "a1", "n3"])
    }

    func testS3SimilarArtistsJoinByTheirMatch() {
        let similar = ["NOVA BLOOM": [PlaylistSuggestions.SimilarArtist(name: "Pale Orchard", match: 0.5)]]
        let ranked = PlaylistSuggestions.ranking(for: playlist, library: library, similar: similar)
        XCTAssertEqual(ranked, ["n2", "n1", "a1", "s1", "n3"])
    }

    func testS4TheSameSongFromAnotherReleaseIsLeftOut() {
        let ranked = PlaylistSuggestions.ranking(for: playlist, library: library, similar: [:])
        XCTAssertFalse(ranked.contains("s2"))
    }

    func testS5PagesWalkTheRankingAndWrapRound() {
        let similar = ["Nova Bloom": [PlaylistSuggestions.SimilarArtist(name: "Pale Orchard", match: 0.5)]]
        XCTAssertEqual(PlaylistSuggestions.suggest(for: playlist, library: library, similar: similar, page: 0, limit: 3), ["n2", "n1", "a1"])
        XCTAssertEqual(PlaylistSuggestions.suggest(for: playlist, library: library, similar: similar, page: 1, limit: 3), ["s1", "n3"])
        XCTAssertEqual(PlaylistSuggestions.suggest(for: playlist, library: library, similar: similar, page: 2, limit: 3), ["n1", "a1", "s1"])
    }

    func testS6NoArtistOrAlbumCrowdsTheTopOfTheList() {
        let crowd = (0..<4).map { song("c\($0)", "Song \($0)", "Nova Bloom", "Tides", plays: 50 - $0) }
        let other = song("a1", "Cinder", "Ash Coast", "Kiln")
        let ranked = PlaylistSuggestions.ranking(for: playlist, library: playlist + crowd + [other], similar: [:])
        XCTAssertEqual(ranked, ["c0", "c1", "a1", "c2", "c3"])
    }

    func testS7SeedArtistsComeMostFrequentFirst() {
        XCTAssertEqual(PlaylistSuggestions.seedArtists(playlist, limit: 5), ["Nova Bloom", "Ash Coast"])
        XCTAssertEqual(PlaylistSuggestions.seedArtists(playlist, limit: 1), ["Nova Bloom"])
    }
}
