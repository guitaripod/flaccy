import XCTest
@testable import FlaccyCore

/// Mirrored by the tests in `linux/shared/src/remote/subsonic_response.rs`, which decode the same
/// Navidrome 0.64.2 fixtures in `Fixtures/Subsonic` and assert the same values.
final class SubsonicResponseTests: XCTestCase {

    private func decodeFixture(_ name: String) throws -> SubsonicResponse.Envelope {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Subsonic/\(name).json")
        return try SubsonicResponse.decode(Data(contentsOf: url))
    }

    func testPingIsOKWithNavidromeServerVersion() throws {
        let envelope = try decodeFixture("ping")

        XCTAssertEqual(envelope.status, "ok")
        XCTAssertEqual(envelope.type, "navidrome")
        XCTAssertEqual(envelope.serverVersion, "0.64.2 (10114574)")
        XCTAssertEqual(envelope.openSubsonic, true)
        XCTAssertNil(envelope.failure)
    }

    func testExtensionsListSongLyricsVersionsAndSupportsChecksByName() throws {
        let envelope = try decodeFixture("extensions")

        let lyrics = envelope.openSubsonicExtensions?.first { $0.name == "songLyrics" }
        XCTAssertEqual(lyrics?.versions, [1, 2])
        XCTAssertTrue(envelope.supports(extension: "transcoding"))
        XCTAssertFalse(envelope.supports(extension: "apiKeyAuthentication"))
    }

    func testMusicFoldersDecode() throws {
        let envelope = try decodeFixture("musicFolders")

        XCTAssertEqual(envelope.musicFolders?.musicFolder?.first?.name, "Music Library")
    }

    func testArtistsDecodeIndexAndArtistIDs() throws {
        let envelope = try decodeFixture("artists")

        let indexes = try XCTUnwrap(envelope.artists?.index)
        XCTAssertEqual(indexes.map(\.name), ["S", "T"])
        XCTAssertEqual(indexes.last?.artist?.first?.id, "4kqFOAfzcbEE22Bin8jHjV")
        XCTAssertEqual(indexes.last?.artist?.first?.albumCount, 1)
    }

    func testAlbumList2HasThreeAlbums() throws {
        let envelope = try decodeFixture("albumList2")

        let albums = try XCTUnwrap(envelope.albumList2?.album)
        XCTAssertEqual(albums.count, 3)
        XCTAssertEqual(albums.first?.name, "First Light")
        XCTAssertEqual(albums.first?.songCount, 3)
    }

    func testAlbumDecodesItsSongsInTrackOrder() throws {
        let envelope = try decodeFixture("album")

        let album = try XCTUnwrap(envelope.album)
        XCTAssertEqual(album.album.id, "3VJh1vLoeqzHRu7d7CGEO3")
        XCTAssertEqual(album.album.name, "First Light")
        XCTAssertEqual(album.song?.map(\.track), [1, 2, 3])
        XCTAssertEqual(album.song?.first?.title, "Opening")
    }

    func testSongDecodesTheFileFacts() throws {
        let envelope = try decodeFixture("song")

        let song = try XCTUnwrap(envelope.song)
        XCTAssertEqual(song.id, "4vVKvXswBtHVzMYeWVqhKo")
        XCTAssertEqual(song.title, "Opening")
        XCTAssertEqual(song.size, 313_276)
        XCTAssertEqual(song.suffix, "flac")
        XCTAssertEqual(song.bitDepth, 16)
        XCTAssertEqual(song.samplingRate, 44_100)
        XCTAssertEqual(song.channelCount, 2)
        XCTAssertEqual(song.duration, 20)
        XCTAssertNil(song.flaccyRevision)
    }

    func testSearch3AllHasSixSongs() throws {
        let envelope = try decodeFixture("search3All")

        XCTAssertEqual(envelope.searchResult3?.song?.count, 6)
    }

    func testPlaylistsWithoutEntriesDecodeAsEmpty() throws {
        let envelope = try decodeFixture("playlists")

        XCTAssertEqual(envelope.status, "ok")
        XCTAssertNil(envelope.playlists?.playlist)
    }

    func testWrongCredentialsFailure() throws {
        let envelope = try decodeFixture("errorWrongCredentials")

        XCTAssertEqual(envelope.status, "failed")
        XCTAssertEqual(envelope.failure, .wrongCredentials)
        XCTAssertEqual(envelope.error?.message, "Wrong username or password")
    }

    func testNotFoundFailure() throws {
        let envelope = try decodeFixture("errorNotFound")

        XCTAssertEqual(envelope.failure, .notFound)
    }

    func testFlaccyExtensionFieldsDecodeWhenPresent() throws {
        let json = """
        {"subsonic-response": {"status": "ok", "version": "1.16.1", "song": {
            "id": "s1", "title": "Opening", "size": 10,
            "flaccyFingerprint": "flac:abc", "flaccyRevision": 3, "flaccyRevisedAt": "2026-10-20T10:00:00Z"
        }}}
        """

        let song = try XCTUnwrap(SubsonicResponse.decode(Data(json.utf8)).song)

        XCTAssertEqual(song.flaccyFingerprint, "flac:abc")
        XCTAssertEqual(song.flaccyRevision, 3)
        XCTAssertEqual(song.flaccyRevisedAt, "2026-10-20T10:00:00Z")
    }

    func testBodyThatIsNotAnEnvelopeThrows() {
        XCTAssertThrowsError(try SubsonicResponse.decode(Data("{\"other\": 1}".utf8)))
    }

    func testFailureCodesMapToNamedCases() {
        XCTAssertEqual(SubsonicFailure(code: 10), .missingParameter)
        XCTAssertEqual(SubsonicFailure(code: 20), .incompatibleVersion)
        XCTAssertEqual(SubsonicFailure(code: 30), .incompatibleVersion)
        XCTAssertEqual(SubsonicFailure(code: 41), .tokenAuthUnsupported)
        XCTAssertEqual(SubsonicFailure(code: 42), .authMechanismUnsupported)
        XCTAssertEqual(SubsonicFailure(code: 43), .conflictingAuth)
        XCTAssertEqual(SubsonicFailure(code: 44), .invalidAPIKey)
        XCTAssertEqual(SubsonicFailure(code: 50), .notAuthorized)
        XCTAssertEqual(SubsonicFailure(code: 60), .trialExpired)
        XCTAssertEqual(SubsonicFailure(code: 99), .other(99))
    }

    func testPlaylistDecodesItsFieldsAndEntries() throws {
        let json = """
        {"subsonic-response": {"status": "ok", "version": "1.16.1", "playlist": {
            "id": "p1", "name": "Road", "songCount": 2, "duration": 40, "public": false, "owner": "flaccy",
            "entry": [{"id": "s1", "title": "Opening"}, {"id": "s2", "title": "Middle"}]
        }}}
        """

        let playlist = try XCTUnwrap(SubsonicResponse.decode(Data(json.utf8)).playlist)

        XCTAssertEqual(playlist.playlist.name, "Road")
        XCTAssertEqual(playlist.playlist.isPublic, false)
        XCTAssertEqual(playlist.entry?.map(\.id), ["s1", "s2"])
    }

    func testPlaylistWithoutEntriesDecodesWithNone() throws {
        let json = #"{"subsonic-response": {"status": "ok", "version": "1.16.1", "playlist": {"id": "p1", "name": "Empty"}}}"#

        let playlist = try XCTUnwrap(SubsonicResponse.decode(Data(json.utf8)).playlist)

        XCTAssertNil(playlist.entry)
    }

    func testSongCarriesThePersonsStateOnTheServer() throws {
        let envelope = try decodeFixture("search3State")

        let songs = try XCTUnwrap(envelope.searchResult3?.song)
        XCTAssertEqual(songs[0].starred, "2026-10-25T15:40:34.817723644+02:00")
        XCTAssertEqual(songs[0].playCount, 3)
        XCTAssertEqual(songs[0].played, "2026-10-24T09:15:00Z")
        XCTAssertNil(songs[1].starred)
        XCTAssertNil(songs[1].playCount)
        XCTAssertNil(songs[1].played)
    }
}
