import FlaccyCore
import Foundation
import Observation
import SwiftUI
import WatchKit

/// Albums the person has just removed but the library has not yet rescanned
/// away. The receiver deletes the files at once, yet the store only republishes
/// after its debounced rescan, so without this the row would sit on screen for
/// a second or two after the confirmation. Entries expire on their own, so a
/// removal that somehow failed brings the album back instead of hiding it.
@MainActor
@Observable
final class PendingRemovals {

    private static let lifetime: Duration = .seconds(8)

    private(set) var hiddenIDs: Set<String> = []

    @ObservationIgnored private var releases: [String: Task<Void, Never>] = [:]

    func hide(_ albums: [MediaAlbum]) {
        for album in albums {
            hiddenIDs.insert(album.id)
            scheduleRelease(of: album.id)
        }
    }

    func visible(_ albums: [MediaAlbum]) -> [MediaAlbum] {
        hiddenIDs.isEmpty ? albums : albums.filter { !hiddenIDs.contains($0.id) }
    }

    private func scheduleRelease(of id: String) {
        releases[id]?.cancel()
        releases[id] = Task { [weak self] in
            try? await Task.sleep(for: Self.lifetime)
            guard !Task.isCancelled else { return }
            self?.release(id)
        }
    }

    private func release(_ id: String) {
        hiddenIDs.remove(id)
        releases[id] = nil
    }
}

@MainActor
enum AlbumRemoval {

    static func remove(_ albums: [MediaAlbum], hiding pending: PendingRemovals) {
        guard !albums.isEmpty else { return }
        pending.hide(albums)
        WatchSyncReceiver.shared.removeFromWatch(paths: albums.flatMap { $0.items.map(\.relativePath) })
        WKInterfaceDevice.current().play(.success)
    }

    /// What the albums' files occupy in Documents right now; it is the figure the
    /// confirmation promises, so it is read from disk rather than estimated.
    static func footprint(of albums: [MediaAlbum]) -> Int64 {
        albums
            .flatMap(\.items)
            .reduce(Int64(0)) { total, item in
                let url = AppPaths.documents.appendingPathComponent(item.relativePath)
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                return total + Int64(size)
            }
    }
}

struct AlbumRemovalRequest: Identifiable, Equatable {
    let album: MediaAlbum
    let bytes: Int64

    var id: String { album.id }
}

private struct RequestAlbumRemovalKey: EnvironmentKey {
    static let defaultValue: (MediaAlbum) -> Void = { _ in }
}

extension EnvironmentValues {

    /// Asks the nearest `albumRemovalFlow` to confirm removing an album from the
    /// watch. Rows call it from a swipe, a long press or a VoiceOver action
    /// without owning any dialog state of their own.
    var requestAlbumRemoval: (MediaAlbum) -> Void {
        get { self[RequestAlbumRemovalKey.self] }
        set { self[RequestAlbumRemovalKey.self] = newValue }
    }
}

extension View {

    func albumRemovalFlow(onRemoved: @escaping () -> Void = {}) -> some View {
        modifier(AlbumRemovalFlow(onRemoved: onRemoved))
    }
}

/// One confirmation dialog per screen, shared by every row on it: naming the
/// album and the space it frees, then deleting and reporting back.
private struct AlbumRemovalFlow: ViewModifier {

    @Environment(PendingRemovals.self) private var pending
    @State private var request: AlbumRemovalRequest?

    let onRemoved: () -> Void

    func body(content: Content) -> some View {
        content
            .environment(\.requestAlbumRemoval, ask)
            .task(id: request) {
                guard LibraryShots.confirmsRemoval, request != nil else { return }
                try? await Task.sleep(for: .seconds(2))
                confirm()
            }
            .confirmationDialog(
                title,
                isPresented: isPresented,
                titleVisibility: .visible
            ) {
                Button("Remove from Watch", role: .destructive, action: confirm)
            } message: {
                Text(message)
            }
    }

    private var isPresented: Binding<Bool> {
        Binding(
            get: { request != nil },
            set: { if !$0 { request = nil } }
        )
    }

    private var title: String {
        guard let request else { return "" }
        return String(localized: "Remove “\(request.album.title)”?")
    }

    private var message: String {
        guard let request else { return "" }
        return String(localized: "Frees \(WatchFormat.bytes(request.bytes)). It stays on your iPhone.")
    }

    private func ask(_ album: MediaAlbum) {
        request = AlbumRemovalRequest(album: album, bytes: AlbumRemoval.footprint(of: [album]))
    }

    private func confirm() {
        guard let request else { return }
        self.request = nil
        AlbumRemoval.remove([request.album], hiding: pending)
        onRemoved()
    }
}
