import FlaccyCore
import SwiftUI

/// An artist as the library knows them: the release credit on one or more
/// albums. Derived on demand from the albums, so it can never disagree with
/// them about who is on the watch.
struct ArtistGroup: Identifiable, Hashable {

    let name: String
    let albums: [MediaAlbum]

    var id: String { name }

    static func groups(from albums: [MediaAlbum]) -> [ArtistGroup] {
        Dictionary(grouping: albums, by: \.artist)
            .map { name, albums in
                ArtistGroup(name: name, albums: albums.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending })
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

struct ArtistsView: View {

    @Environment(WatchLibraryStore.self) private var store
    @Environment(PendingRemovals.self) private var pending

    let onOpen: (Route) -> Void

    var body: some View {
        let groups = ArtistGroup.groups(from: pending.visible(store.albums))
        Group {
            if groups.isEmpty {
                ContentUnavailableView {
                    Label("No Artists", systemImage: "music.mic")
                }
            } else {
                List {
                    ForEach(groups) { group in
                        Button { onOpen(.artist(group.name)) } label: {
                            ArtistRow(group: group)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listStyle(.carousel)
            }
        }
        .navigationTitle("Artists")
    }
}

struct ArtistRow: View {

    @Environment(\.dynamicTypeSize) private var typeSize

    let group: ArtistGroup

    var body: some View {
        HStack(spacing: 10) {
            if !typeSize.isAccessibilitySize {
                ArtworkView(data: group.albums.lazy.compactMap(\.artworkData).first, seed: group.name, cornerRadius: 20)
                    .frame(width: 40, height: 40)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(group.name)
                    .font(.headline)
                    .lineLimit(typeSize.isAccessibilitySize ? 4 : 2)
                Text(WatchFormat.albums(group.albums.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: group.name))
        .accessibilityValue(Text(verbatim: WatchFormat.albums(group.albums.count)))
    }
}

struct ArtistAlbumsView: View {

    @Environment(WatchLibraryStore.self) private var store
    @Environment(PendingRemovals.self) private var pending
    @Environment(\.dismiss) private var dismiss

    let artist: String
    let onOpen: (Route) -> Void

    var body: some View {
        let albums = ArtistGroup.groups(from: pending.visible(store.albums)).first { $0.name == artist }?.albums ?? []
        List {
            ForEach(albums) { album in
                AlbumListRow(album: album) { onOpen(.album(album)) }
            }
        }
        .listStyle(.carousel)
        .navigationTitle(artist)
        .albumRemovalFlow()
        .onChange(of: albums.isEmpty) { _, isEmpty in
            if isEmpty { dismiss() }
        }
    }
}
