import XCTest
@testable import FlaccyCore

final class PlaylistMakerTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_794_000_000)

    private func song(
        _ id: Int, _ artist: String, title: String? = nil, credit: String? = nil, year: Int? = nil, genre: String? = nil,
        seconds: Int = 200, loved: Bool = false, plays: Int = 0, playedDaysAgo: Int? = nil
    ) -> MakerSong {
        MakerSong(
            id: id, title: title ?? "Song \(id)", artist: artist, credit: credit ?? artist, album: "Album", year: year, genre: genre,
            seconds: seconds, loved: loved, plays: plays,
            lastPlayed: playedDaysAgo.map { now.addingTimeInterval(-Double($0) * 86_400) })
    }

    private func catalogue(_ artist: String, from first: Int, count: Int, year: Int? = nil) -> [MakerSong] {
        (0..<count).map { song(first + $0, artist, year: year, plays: count - $0) }
    }

    func testArtistsAreNumberedLargestFirstWithWhatTheLibraryKnows() {
        let songs = catalogue("Nick Drake", from: 1, count: 3, year: 1972)
            + [song(10, "Boards of Canada", year: 1998, genre: "idm", loved: true), song(11, "Boards of Canada", year: 2002, genre: "idm"), song(12, "Boards of Canada", genre: "ambient")]
            + [song(20, "Guest", credit: "Various Artists"), song(21, "Zed")]
        let library = PlaylistMakerLibrary(songs: songs)
        XCTAssertEqual(library.artists.map(\.name), ["Boards of Canada", "Nick Drake", "Various Artists", "Zed"])
        XCTAssertEqual(library.artists[0], MakerArtist(id: 1, name: "Boards of Canada", genre: "idm", years: "1998-2002", songs: 3, loved: 1))
        XCTAssertEqual(library.artists[1], MakerArtist(id: 2, name: "Nick Drake", genre: nil, years: "1972", songs: 3, loved: nil))
        XCTAssertEqual(library.songs(ofArtists: [2, 99, 1]).map { $0.map(\.id) }, [[1, 2, 3], [10, 11, 12]])
    }

    func testALibraryWithMoreArtistsThanARequestCarriesSendsItsLargest() {
        let songs = (1...PlaylistMakerLibrary.artistLimit + 20).map { song($0, "Artist \($0)") } + [song(9_000, "Artist 7"), song(9_001, String(repeating: "x", count: 400))]
        let library = PlaylistMakerLibrary(songs: songs)
        XCTAssertEqual(library.artists.count, PlaylistMakerLibrary.artistLimit)
        XCTAssertEqual(library.artists[0].name, "Artist 7")
        XCTAssertTrue(library.artists.allSatisfy { $0.name.count <= PlaylistMakerLibrary.nameLimit })
    }

    func testThePlanDecodesFromTheWorkersReply() throws {
        let json = #"{"title":"Rainy Sunday","artists":[2,1],"minutes":40,"count":null,"from_year":1990,"to_year":null,"rest_days":30,"loved_only":false,"note":""}"#
        let plan = try JSONDecoder().decode(PlaylistPlan.self, from: Data(json.utf8))
        XCTAssertEqual(plan, PlaylistPlan(title: "Rainy Sunday", artists: [2, 1], minutes: 40, fromYear: 1990, restDays: 30))
    }

    func testCandidatesComeFromTheChosenArtistsInsideTheEraAndTheRest() {
        let songs = [
            song(1, "A", year: 1994), song(2, "A", year: 2004), song(3, "A"), song(4, "A", year: 1995, seconds: 30),
            song(5, "A", year: 1996, playedDaysAgo: 3), song(6, "A", year: 1997, playedDaysAgo: 60), song(7, "B", year: 1995),
        ]
        let library = PlaylistMakerLibrary(songs: songs)
        let plan = PlaylistPlan(title: "T", artists: [1], fromYear: 1990, toYear: 1999, restDays: 30)
        XCTAssertEqual(Set(PlaylistMaker.candidates(for: plan, in: library, now: now).map(\.id)), [1, 3, 6])
    }

    func testALargeCatalogueGivesItsKnownSongsAndAnEvenSpreadOfTheRest() {
        let library = PlaylistMakerLibrary(songs: catalogue("A", from: 1, count: 100) + catalogue("B", from: 200, count: 100))
        let pool = PlaylistMaker.candidates(for: PlaylistPlan(title: "T", artists: [1, 2]), in: library, now: now, limit: 40)
        XCTAssertEqual(pool.count, 40)
        let fromA = pool.filter { $0.artist == "A" }.map(\.id)
        XCTAssertEqual(fromA.count, 20)
        XCTAssertEqual(Array(fromA.prefix(10)), Array(1...10))
        XCTAssertTrue(fromA.contains { $0 > 60 })
    }

    func testLovedOnlyBecomesAPreferenceWhenTooFewAreLoved() {
        let fewLoved = [song(1, "A", loved: true), song(2, "A"), song(3, "A"), song(4, "A"), song(5, "A")]
        let plan = PlaylistPlan(title: "T", artists: [1], count: 4, lovedOnly: true)
        XCTAssertEqual(PlaylistMaker.candidates(for: plan, in: PlaylistMakerLibrary(songs: fewLoved), now: now).map(\.id), [1, 2, 3, 4, 5])
        let manyLoved = (1...10).map { song($0, "A", loved: $0 <= 8) }
        XCTAssertEqual(PlaylistMaker.candidates(for: plan, in: PlaylistMakerLibrary(songs: manyLoved), now: now).count, 8)
    }

    func testThePickRequestCarriesTheTargetAndForAChangeTheListAsItStands() {
        let candidates = [song(1, "A", title: String(repeating: "t", count: 300), year: 1994, loved: true), song(2, "B")]
        let plan = PlaylistPlan(title: "T", artists: [1], minutes: 40)
        let first = PlaylistMaker.pickRequest("calm", language: "Finnish", plan: plan, candidates: candidates)
        XCTAssertEqual(first.minutes, 40)
        XCTAssertNil(first.current)
        XCTAssertEqual(first.songs[0].title.count, PlaylistMakerLibrary.nameLimit)
        XCTAssertEqual(first.songs.map(\.loved), [true, nil])
        let change = PlaylistMaker.pickRequest("calm", language: "Finnish", plan: plan, candidates: candidates, change: "less A", current: [candidates[1]])
        XCTAssertEqual(change.current, [2])
        XCTAssertEqual(change.change, "less A")
    }

    func testTheSettledListDropsWhatTheLibraryDoesNotHoldAndMeetsTheCount() {
        let candidates = [song(1, "A"), song(2, "B"), song(3, "C"), song(4, "D"), song(5, "A")]
        let plan = PlaylistPlan(title: "T", artists: [1], count: 4)
        XCTAssertEqual(PlaylistMaker.settle(picked: [3, 99, 3, 1], candidates: candidates, plan: plan).map(\.id), [3, 1, 2, 4])
        XCTAssertEqual(PlaylistMaker.settle(picked: [5, 4, 3, 2, 1], candidates: candidates, plan: plan).map(\.id), [5, 4, 3, 2])
    }

    func testTheSettledListRunsCloseToTheMinutesAskedFor() {
        let candidates = (1...30).map { song($0, "Artist \($0 % 6)", seconds: 240) }
        let plan = PlaylistPlan(title: "T", artists: [1], minutes: 40)
        let tooLong = PlaylistMaker.settle(picked: Array(1...20), candidates: candidates, plan: plan)
        XCTAssertLessThanOrEqual(Double(PlaylistMaker.seconds(of: tooLong)), 40 * 60 * 1.15)
        XCTAssertEqual(tooLong.map(\.id), Array(1...11))
        let tooShort = PlaylistMaker.settle(picked: [1, 2, 3], candidates: candidates, plan: plan)
        XCTAssertGreaterThanOrEqual(Double(PlaylistMaker.seconds(of: tooShort)), 40 * 60 * 0.85)
        XCTAssertEqual(Array(tooShort.map(\.id).prefix(3)), [1, 2, 3])
    }

    func testAModelThatChoseNothingStillMakesAPlaylistOneArtistAtATime() {
        let candidates = catalogue("A", from: 1, count: 30) + catalogue("B", from: 100, count: 30)
        let made = PlaylistMaker.settle(picked: [], candidates: candidates, plan: PlaylistPlan(title: "T", artists: [1]))
        XCTAssertEqual(made.count, PlaylistMaker.usualCount)
        XCTAssertEqual(Array(made.map(\.artist).prefix(4)), ["A", "B", "A", "B"])
        let kept = PlaylistMaker.settle(picked: [1, 100], candidates: candidates, plan: PlaylistPlan(title: "T", artists: [1]))
        XCTAssertEqual(kept.map(\.id), [1, 100])
    }

    func testNoArtistPlaysThreeTimesInARowWhereAnotherOrderAllowsIt() {
        let run = [song(1, "A"), song(2, "A"), song(3, "A"), song(4, "A"), song(5, "B"), song(6, "C")]
        let spaced = PlaylistMaker.spaced(run)
        XCTAssertEqual(Set(spaced.map(\.id)), Set(1...6))
        for index in 2..<spaced.count {
            XCTAssertFalse(spaced[index].artist == spaced[index - 1].artist && spaced[index].artist == spaced[index - 2].artist, "three in a row at \(index)")
        }
        let onlyOne = [song(1, "A"), song(2, "A"), song(3, "A")]
        XCTAssertEqual(PlaylistMaker.spaced(onlyOne), onlyOne)
    }
}
