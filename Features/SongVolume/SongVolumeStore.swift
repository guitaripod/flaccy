import FlaccyCore
import FlaccyEngine
import Foundation
import MidgarCore

/// Each song's own volume as the app uses it: read from the library database
/// once, kept by song key, written back through `DatabaseManager.setSongGain`
/// (which queues it for Flaccy Server) and handed to the equalizer's taps so
/// the playing song changes at once.
@MainActor
final class SongVolumeStore {

    static let shared = SongVolumeStore()

    static let didChange = Notification.Name("com.midgarcorp.flaccy.SongVolumeDidChange")

    private var levels: [String: Int] = [:]
    private var keys: [String: String] = [:]
    private var hasLoaded = false

    private init() {}

    /// The song key Flaccy Server files the song under, remembered per spelling.
    func key(for track: Track) -> String? {
        let spelling = "\(track.title)\u{0}\(track.artist)"
        if let known = keys[spelling] { return known }
        guard let key = try? ServerSongIdentity.songKey(title: track.title, artist: track.artist) else { return nil }
        keys[spelling] = key
        return key
    }

    /// The song's own volume in tenths of a decibel; 0 when the person never set one.
    func level(for track: Track) -> Int {
        loadIfNeeded()
        return key(for: track).flatMap { levels[$0] } ?? 0
    }

    /// Plays the song at `tenths` without saving it, while a control is still moving.
    func preview(_ tenths: Int, for track: Track) {
        guard let key = key(for: track) else { return }
        EqualizerEngine.shared.setSongGain(SongGain.clamped(tenths), songKey: key)
    }

    /// Saves a song's own volume: the sound changes at once, the library keeps
    /// it and every Flaccy that syncs with the same Flaccy Server follows.
    /// Answers the level in force, which is the old one when the save failed.
    @discardableResult
    func set(_ tenths: Int, for track: Track) throws -> Int {
        loadIfNeeded()
        guard let key = key(for: track) else { return 0 }
        do {
            let level = try DatabaseManager.shared.setSongGain(title: track.title, artist: track.artist, tenths: tenths)
            levels[key] = level == 0 ? nil : level
            EqualizerEngine.shared.setSongGain(level, songKey: key)
            MidgarLog.info("Song volume \(SongGain.label(level, locale: Locale(identifier: "en_US"))) for \(track.title) — \(track.artist)", category: .playback)
            NotificationCenter.default.post(name: Self.didChange, object: self)
            return level
        } catch {
            EqualizerEngine.shared.setSongGain(levels[key] ?? 0, songKey: key)
            MidgarLog.error("Song volume save failed for \(track.title): \(error.localizedDescription)", category: .database)
            throw error
        }
    }

    /// Reads every level again, after Flaccy Server brought new ones, and moves the songs already queued to them.
    func reload() {
        let previous = levels
        levels = (try? DatabaseManager.shared.songGains()) ?? [:]
        hasLoaded = true
        for key in Set(previous.keys).union(levels.keys) where previous[key] != levels[key] {
            EqualizerEngine.shared.setSongGain(levels[key] ?? 0, songKey: key)
        }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    private func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        do {
            levels = try DatabaseManager.shared.songGains()
        } catch {
            MidgarLog.error("Song volumes could not be read: \(error.localizedDescription)", category: .database)
        }
    }
}
