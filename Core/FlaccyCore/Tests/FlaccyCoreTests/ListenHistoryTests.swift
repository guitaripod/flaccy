import XCTest
@testable import FlaccyCore

final class ListenHistoryTests: XCTestCase {

    private let now = 1_800_000_000

    func testTitleKeysFoldFeaturedCreditsAndRemastersButKeepVersionsApart() {
        let vectors = [
            ("Song", "song"),
            ("SONG", "song"),
            ("Sóng!", "song"),
            ("Song (feat. Someone)", "song"),
            ("Song [ft. Someone]", "song"),
            ("Song feat. Someone", "song"),
            ("Song Featuring Someone", "song"),
            ("Song (with Someone)", "song"),
            ("Song - 2011 Remaster", "song"),
            ("Song - Remastered 2009", "song"),
            ("Song (Remastered)", "song"),
            ("Song (Explicit)", "song"),
            ("Song (Live)", "songlive"),
            ("Song (Acoustic Version)", "songacousticversion"),
            ("Song - Radio Edit", "songradioedit"),
            ("(feat. Someone)", "featsomeone"),
            ("日本語の歌", "日本語の歌"),
        ]
        for (raw, key) in vectors {
            XCTAssertEqual(ListenHistory.titleKey(raw), key, raw)
        }
    }

    func testArtistAndAlbumKeysFollowTheLibraryGrouping() {
        XCTAssertEqual(ListenHistory.artistKey("Beyoncé"), "beyonce")
        XCTAssertEqual(ListenHistory.artistKey("deadmau5 feat. Kaskade"), "deadmau5")
        XCTAssertEqual(ListenHistory.artistKey("Sigur Rós"), "sigurros")
        XCTAssertEqual(ListenHistory.albumKey("Abbey Road (2019 Remaster)"), "abbeyroad")
        XCTAssertEqual(ListenHistory.albumKey("OK Computer [Deluxe Edition]"), "okcomputer")
        XCTAssertEqual(ListenHistory.albumKey(""), "")
        XCTAssertEqual(
            ListenHistory.trackKey(title: "Song (feat. B)", artist: "A feat. B"),
            ListenHistory.trackKey(title: "song", artist: "a")
        )
    }

    private func keys(_ title: String, _ artist: String) -> ListenHistory.Keys {
        ListenHistory.Keys(title: title, artist: artist, album: "")
    }

    private func stored(_ timestamp: Int, _ title: String, _ artist: String, playedHere: Bool) -> ListenHistory.StoredListen {
        ListenHistory.StoredListen(
            timestamp: timestamp,
            titleKey: ListenHistory.titleKey(title),
            artistKey: ListenHistory.artistKey(artist),
            playedHere: playedHere
        )
    }

    func testTheLedgerAdmitsEachPulledPlayOnce() {
        var ledger = ListenHistory.Ledger([stored(100, "Song", "A", playedHere: false)])
        XCTAssertFalse(ledger.admit(timestamp: 100, keys: keys("song", "A")))
        XCTAssertFalse(ledger.admit(timestamp: 100, keys: keys("Song (Remastered)", "Other")))
        XCTAssertTrue(ledger.admit(timestamp: 101, keys: keys("Song", "A")))
        XCTAssertFalse(ledger.admit(timestamp: 101, keys: keys("Song", "A")))
    }

    func testPulledPlaysSharingASecondStayApart() {
        var ledger = ListenHistory.Ledger([])
        XCTAssertTrue(ledger.admit(timestamp: 500, keys: keys("Parabola", "Tool")))
        XCTAssertTrue(ledger.admit(timestamp: 500, keys: keys("Lateralus", "Tool")))
        XCTAssertTrue(ledger.admit(timestamp: 500, keys: keys("Triad", "Tool")))
    }

    func testACorrectedTitleIsThePlayFlaccyRecorded() {
        var ledger = ListenHistory.Ledger([stored(900, "Song (Album Mix)", "Artist", playedHere: true)])
        XCTAssertFalse(ledger.admit(timestamp: 900, keys: keys("Song", "Artist")))
        XCTAssertTrue(ledger.admit(timestamp: 900, keys: keys("Song", "Somebody Else")))
        XCTAssertTrue(ledger.admit(timestamp: 901, keys: keys("Song", "Artist")))
    }

    func testSpellingsFoldUnderTheOneHeardMostThenLast() {
        func spelling(_ key: String, _ name: String, _ plays: Int, _ latest: Int) -> ListenHistory.Spelling<String> {
            .init(key: key, name: name, plays: plays, seconds: plays * 10, latest: latest)
        }
        let folded = ListenHistory.foldSpellings([
            spelling("sigurros", "Sigur Ros", 3, 900),
            spelling("sigurros", "Sigur Rós", 5, 100),
            spelling("bjork", "Björk", 8, 100),
            spelling("abba", "ABBA", 2, 100),
            spelling("abba", "Abba", 2, 300),
            spelling("tool", "Tool", 1, 50),
            spelling("tool", "TOOL", 1, 50),
        ])
        XCTAssertEqual(folded.map(\.name), ["Björk", "Sigur Rós", "Abba", "TOOL"])
        XCTAssertEqual(folded.map(\.plays), [8, 8, 4, 2])
        XCTAssertEqual(folded.map(\.seconds), [80, 80, 40, 20])
    }

    func testANewAccountBackfillsFromNowAndKeepsItsAnchor() {
        var state = ListenHistory.SyncState().forAccount("listener")
        XCTAssertEqual(state.nextStep(now: now), .backfill(page: 1, to: now))
        state.recordBackfillPage(page: 1, totalPages: 3, anchor: now, newest: now - 10, now: now)
        XCTAssertEqual(state.nextStep(now: now + 500), .backfill(page: 2, to: now))
        state.recordBackfillPage(page: 2, totalPages: 3, anchor: now, newest: now - 9_000, now: now + 600)
        state.recordBackfillPage(page: 3, totalPages: 3, anchor: now, newest: nil, now: now + 700)
        XCTAssertTrue(state.backfillComplete)
        XCTAssertEqual(state.newestRemote, now)
        XCTAssertEqual(state.nextStep(now: now + 800), .settle(from: now + 800 - ListenHistory.lateScrobbleWindow))
    }

    func testASettledHistoryCatchesUpFromJustBeforeTheNewestPlay() {
        var state = ListenHistory.SyncState().forAccount("listener")
        state.backfillComplete = true
        state.newestRemote = now - 50
        state.recordPull(.settle(from: now - ListenHistory.lateScrobbleWindow), newest: now - 20, now: now)
        XCTAssertEqual(state.newestRemote, now - 20)
        XCTAssertEqual(state.nextStep(now: now + 300), .catchUp(from: now - 20 - ListenHistory.catchUpOverlap))
        XCTAssertEqual(
            state.nextStep(now: now + ListenHistory.settleInterval),
            .settle(from: now + ListenHistory.settleInterval - ListenHistory.lateScrobbleWindow)
        )
    }

    func testALongAbsenceCatchesUpFromTheNewestPlayAndCountsAsSettled() {
        var state = ListenHistory.SyncState().forAccount("listener")
        state.backfillComplete = true
        state.newestRemote = now - 90 * 86_400
        let step = state.nextStep(now: now)
        XCTAssertEqual(step, .catchUp(from: now - 90 * 86_400 - ListenHistory.catchUpOverlap))
        state.recordPull(step, newest: now - 60, now: now)
        XCTAssertEqual(state.lastSettleAt, now)
        XCTAssertEqual(state.newestRemote, now - 60)
    }

    func testAPullThatFindsNothingStillMovesTheClock() {
        var state = ListenHistory.SyncState().forAccount("listener")
        state.backfillComplete = true
        state.recordPull(.settle(from: 0), newest: nil, now: now)
        XCTAssertEqual(state.newestRemote, now)
        XCTAssertEqual(state.lastSyncAt, now)
    }

    func testAutomaticSyncsAreSpacedOut() {
        var state = ListenHistory.SyncState().forAccount("listener")
        XCTAssertTrue(state.automaticSyncDue(now: now))
        state.lastSyncAt = now
        XCTAssertFalse(state.automaticSyncDue(now: now + ListenHistory.automaticSyncSpacing - 1))
        XCTAssertTrue(state.automaticSyncDue(now: now + ListenHistory.automaticSyncSpacing))
        XCTAssertTrue(state.automaticSyncDue(now: now - 10))
    }

    func testSwitchingAccountsStartsOverAndTheSameAccountKeepsItsPlace() {
        var state = ListenHistory.SyncState().forAccount("first")
        state.backfillComplete = true
        state.newestRemote = now
        XCTAssertEqual(state.forAccount("first"), state)
        let other = state.forAccount("second")
        XCTAssertFalse(other.backfillComplete)
        XCTAssertEqual(other.nextStep(now: now), .backfill(page: 1, to: now))
    }

    func testAnEarlierImportIsAdopted() {
        let finished = ListenHistory.SyncState.adopting(
            account: "listener", legacyComplete: true, legacyPage: 1, newestImported: now - 5_000, now: now
        )
        XCTAssertTrue(finished.backfillComplete)
        XCTAssertEqual(finished.newestRemote, now - 5_000)

        let stopped = ListenHistory.SyncState.adopting(
            account: "listener", legacyComplete: false, legacyPage: 190, newestImported: now - 5_000, now: now
        )
        XCTAssertFalse(stopped.backfillComplete)
        XCTAssertEqual(stopped.nextStep(now: now + 60), .backfill(page: 189, to: now))

        let never = ListenHistory.SyncState.adopting(
            account: "listener", legacyComplete: false, legacyPage: 1, newestImported: nil, now: now
        )
        XCTAssertEqual(never.nextStep(now: now), .backfill(page: 1, to: now))
    }
}
