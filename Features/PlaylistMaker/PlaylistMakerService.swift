import FlaccyCore
import FlaccyEngine
import Foundation
import MidgarCore

/// Why no playlist came back, each with its own next step for the person.
nonisolated enum PlaylistMakerFailure: Error, Sendable, Equatable {
    case needsEntitlement
    case emptyLibrary
    case unreachable
    case quotaReached(resetsAt: Date)
    /// The library holds nothing for the request; the model's own sentence about what is missing, when it gave one.
    case nothingFits(note: String)
    case declined
    case unavailable

    /// Whether asking for something else is the way forward, so the example requests are worth showing again.
    var invitesAnotherRequest: Bool {
        switch self {
        case .nothingFits, .declined: true
        case .needsEntitlement, .emptyLibrary, .unreachable, .quotaReached, .unavailable: false
        }
    }
}

/// What Make a Playlist is doing, for the line under the spinner.
nonisolated enum PlaylistMakerStep: Sendable, Equatable {
    case readingLibrary
    case planning
    case choosing
}

/// A playlist as it was made and before it is saved: playable, changeable, and holding what a change needs.
nonisolated struct PlaylistDraft: Sendable {
    let request: String
    let title: String
    let note: String
    let tracks: [Track]
    fileprivate let plan: PlaylistPlan
    fileprivate let candidates: [MakerSong]
    fileprivate let songs: [MakerSong]
    fileprivate let tracksByID: [Int: Track]

    var seconds: Int { PlaylistMaker.seconds(of: songs) }
}

/// Make a Playlist on the Apple clients: a sentence becomes a playlist from the person's own library through two
/// calls to flaccy-api, whose model only ever chooses among numbers this device sent. Code gathers the candidates
/// and enforces the length and the spacing (`PlaylistMaker` in FlaccyCore).
nonisolated final class PlaylistMakerService: Sendable {

    static let shared = PlaylistMakerService()

    /// Makes a playlist for `request`. `progress` is called as each step begins.
    func make(_ request: String, progress: @escaping @Sendable (PlaylistMakerStep) -> Void) async -> Result<PlaylistDraft, PlaylistMakerFailure> {
        guard await MainActor.run(body: { PurchaseManager.shared.allowsPlayback }) else { return .failure(.needsEntitlement) }
        progress(.readingLibrary)
        let (songs, tracksByID) = await librarySongs()
        guard !songs.isEmpty else { return .failure(.emptyLibrary) }
        let library = PlaylistMakerLibrary(songs: songs)
        progress(.planning)
        let planned: Result<PlanReply, PlaylistMakerFailure> = await ask("plan", library.planRequest(request, language: LyricsMeaningService.languageName))
        guard case .success(let reply) = planned else { return .failure(planned.failure ?? .unavailable) }
        let candidates = PlaylistMaker.candidates(for: reply.plan, in: library, now: Date())
        guard !candidates.isEmpty else { return .failure(.nothingFits(note: reply.plan.note)) }
        progress(.choosing)
        return await pick(request: request, plan: reply.plan, candidates: candidates, tracksByID: tracksByID, change: nil, current: [])
    }

    /// Changes a playlist that was made, as `instruction` asks, choosing again among the same candidates.
    func change(_ draft: PlaylistDraft, to instruction: String, progress: @escaping @Sendable (PlaylistMakerStep) -> Void) async -> Result<PlaylistDraft, PlaylistMakerFailure> {
        guard await MainActor.run(body: { PurchaseManager.shared.allowsPlayback }) else { return .failure(.needsEntitlement) }
        progress(.choosing)
        return await pick(
            request: draft.request, plan: draft.plan, candidates: draft.candidates, tracksByID: draft.tracksByID,
            change: String(instruction.prefix(Self.longestChange)), current: draft.songs)
    }

    /// Saves a made playlist as an ordinary one, named after it with a number when the name is taken, and returns it.
    func save(_ draft: PlaylistDraft, path: (Track) -> String) throws -> PlaylistRecord {
        let database = DatabaseManager.shared
        let taken = Set(try database.fetchAllPlaylists().map(\.name))
        let playlist = try database.createPlaylist(name: Self.freeName(draft.title, taken: taken))
        if let id = playlist.id {
            try database.addTracksToPlaylist(playlistId: id, trackFileURLs: draft.tracks.map(path))
        }
        return playlist
    }

    /// The longest request and change sent, which flaccy-api enforces at 400 and 300.
    static let longestRequest = 400
    static let longestChange = 300

    /// `title`, or `title 2`, `title 3` and so on when playlists already carry the names before it.
    static func freeName(_ title: String, taken: Set<String>) -> String {
        guard taken.contains(title) else { return title }
        var number = 2
        while taken.contains("\(title) \(number)") { number += 1 }
        return "\(title) \(number)"
    }

    private func pick(
        request: String, plan: PlaylistPlan, candidates: [MakerSong], tracksByID: [Int: Track], change: String?, current: [MakerSong]
    ) async -> Result<PlaylistDraft, PlaylistMakerFailure> {
        let body = PlaylistMaker.pickRequest(
            request, language: LyricsMeaningService.languageName, plan: plan, candidates: candidates, change: change, current: current)
        let picked: Result<PickReply, PlaylistMakerFailure> = await ask("pick", body)
        guard case .success(let reply) = picked else { return .failure(picked.failure ?? .unavailable) }
        let songs = PlaylistMaker.settle(picked: reply.songs, candidates: candidates, plan: plan)
        let tracks = songs.compactMap { tracksByID[$0.id] }
        guard !tracks.isEmpty else { return .failure(.nothingFits(note: plan.note)) }
        MidgarLog.info("Made a playlist of \(tracks.count) songs from \(candidates.count) candidates", category: .content)
        return .success(
            PlaylistDraft(
                request: request, title: plan.title, note: plan.note, tracks: tracks, plan: plan, candidates: candidates,
                songs: songs.filter { tracksByID[$0.id] != nil }, tracksByID: tracksByID))
    }

    /// Every song of the library as Make a Playlist reads it, with the track each stands for.
    private func librarySongs() async -> ([MakerSong], [Int: Track]) {
        let albums = await MainActor.run { Library.shared.albums }
        let lastPlayed = (try? DatabaseManager.shared.lastPlayedByTrackID()) ?? [:]
        var songs: [MakerSong] = []
        var tracksByID: [Int: Track] = [:]
        for album in albums {
            let year = album.year.flatMap { Int($0.prefix(4)) }
            for track in album.tracks {
                guard let row = track.dbID, tracksByID[Int(row)] == nil else { continue }
                tracksByID[Int(row)] = track
                songs.append(
                    MakerSong(
                        id: Int(row), title: track.title, artist: track.artist, credit: album.artist, album: album.title, year: year,
                        genre: album.genre, seconds: Int(track.duration), loved: track.loved, plays: track.playCount,
                        lastPlayed: lastPlayed[row]))
            }
        }
        return (songs, tracksByID)
    }

    private func ask<Reply: Decodable>(_ step: String, _ body: some Encodable & Sendable) async -> Result<Reply, PlaylistMakerFailure> {
        let reply: FlaccyAPIClient.ProxyReply
        do {
            reply = try await FlaccyMidgar.shared.api.postPlaylist(step: step, body)
        } catch {
            MidgarLog.notice("Playlist \(step) request failed: \(error.localizedDescription)", category: .content)
            return .failure(error is URLError ? .unreachable : .unavailable)
        }
        let errorCode = (try? JSONDecoder().decode(ProxyError.self, from: reply.body))?.error
        switch AIProxyReply.classify(status: reply.status, errorCode: errorCode, retryAfter: reply.retryAfter, now: Date()) {
        case .answer:
            break
        case .quotaReached(let resetsAt):
            return .failure(.quotaReached(resetsAt: resetsAt))
        case .busy, .payloadTooLarge, .unavailable:
            MidgarLog.notice("Playlist \(step) answered \(reply.status) \(errorCode ?? "")", category: .content)
            return .failure(errorCode == "request_declined" ? .declined : .unavailable)
        }
        guard let decoded = try? JSONDecoder().decode(Reply.self, from: reply.body) else {
            MidgarLog.notice("Playlist \(step) reply could not be read", category: .content)
            return .failure(.unavailable)
        }
        return .success(decoded)
    }
}

private nonisolated struct PlanReply: Decodable {
    let plan: PlaylistPlan
}

private nonisolated struct PickReply: Decodable {
    let songs: [Int]
}

private nonisolated struct ProxyError: Decodable {
    let error: String?
}

private extension Result {
    nonisolated var failure: Failure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}
