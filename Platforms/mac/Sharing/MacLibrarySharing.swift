import FlaccyServerEmbed
import Foundation

/// The one controller of "Share this Mac's library" for the app.
@MainActor
enum MacLibrarySharing {

    static let shared = LibrarySharing(
        host: FlaccyServerHost(),
        folder: LibraryFolderAccess(),
        enroller: ThisMacEnroller(),
        machineName: { Host.current().localizedName ?? "Mac" },
        isPortFree: PortProbe.isFree
    )
}
