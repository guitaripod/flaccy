import FlaccyCore
import SwiftUI

/// The destructive button at the foot of an album. It lives in its own view so
/// it reads the removal request from inside the screen's `albumRemovalFlow`
/// rather than from above it, where nothing would answer.
struct RemoveAlbumButton: View {

    @Environment(\.requestAlbumRemoval) private var requestRemoval

    let album: MediaAlbum

    var body: some View {
        Button(role: .destructive) {
            requestRemoval(album)
        } label: {
            Label("Remove from Watch", systemImage: "trash")
                .frame(maxWidth: .infinity)
        }
        .tint(.red)
        .id("end")
    }
}
