import FlaccyCore
import Foundation

/// The song identity every Flaccy client shares: the key Flaccy Server files loves, playlist entries and plays under.
public enum ServerSongIdentity {

    /// The key of a song, from the title and artist exactly as the library holds them.
    public static func songKey(title: String, artist: String) throws -> String {
        try SyncSongRefs.songKey(title: title, artist: artist)
    }

    /// The reference a mutation carries for a song known by what a play recorded.
    public static func ref(title: String, artist: String, album: String) throws -> ServerSongRef {
        try SyncSongRefs.ref(title: title, artist: artist, album: album)
    }
}
