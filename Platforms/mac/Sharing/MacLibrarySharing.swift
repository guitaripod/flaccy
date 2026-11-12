import FlaccyServerEmbed
import Foundation
import SystemConfiguration

/// The one controller of "Share this Mac's library" for the app.
@MainActor
enum MacLibrarySharing {

    static let shared = LibrarySharing(
        host: FlaccyServerHost(),
        folder: LibraryFolderAccess(),
        enroller: ThisMacEnroller(),
        machineName: { Host.current().localizedName ?? "Mac" },
        localHostName: { SCDynamicStoreCopyLocalHostName(nil) as String? },
        isPortFree: PortProbe.isFree
    )
}
