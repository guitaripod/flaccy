import FlaccyCore
import SwiftUI

struct LibraryView: View {

    @Environment(WatchLibraryStore.self) private var store
    @Environment(WatchAudioPlayer.self) private var player
    @Environment(WatchSyncStatus.self) private var syncStatus

    @Environment(PendingRemovals.self) private var pending
    @Environment(\.isLuminanceReduced) private var isDimmed
    @Environment(\.dynamicTypeSize) private var typeSize

    let onOpen: (Route) -> Void
    let onShowNowPlaying: () -> Void

    @AppStorage(WatchDebutSummaryView.storageKey) private var debutShown = false
    @State private var isShowingDebut = false

    var body: some View {
        Group {
            if store.isLoading && store.albums.isEmpty {
                ScanProgressView(progress: store.loadProgress, fraction: store.loadFraction)
            } else if isLibraryEmpty {
                emptyState
            } else {
                content
            }
        }
        .navigationTitle("On Watch")
        .toolbar {
            if player.currentItem != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onShowNowPlaying) {
                        Image(systemName: "waveform")
                            .foregroundStyle(.white)
                    }
                    .accessibilityLabel("Now Playing")
                }
            }
        }
        .onAppear(perform: presentDebutIfEarned)
        .onChange(of: store.isLoading) { presentDebutIfEarned() }
        .onChange(of: store.albums.count) { presentDebutIfEarned() }
        .sheet(isPresented: $isShowingDebut) {
            WatchDebutSummaryView(
                trackCount: store.allTracks.count,
                albums: store.albums,
                onDismiss: { isShowingDebut = false }
            )
        }
    }

    /// The wrist's Debut is earned the first time this watch finishes a scan
    /// that actually found music — never while a scan is still running, and
    /// never for an empty library, exactly as the phone withholds it when the
    /// first build produced no albums.
    private func presentDebutIfEarned() {
        guard !debutShown, !isShowingDebut, !store.isLoading, !store.albums.isEmpty, !LibraryShots.forcesEmptyLibrary else { return }
        isShowingDebut = true
    }

    private var visibleAlbums: [MediaAlbum] { pending.visible(store.albums) }

    private var isLibraryEmpty: Bool {
        LibraryShots.forcesEmptyLibrary || store.isEmpty || visibleAlbums.isEmpty
    }

    private var showsBatchBanner: Bool {
        syncStatus.incoming.isActive || syncStatus.incoming.preparing
    }

    @ViewBuilder private var emptyState: some View {
        if showsBatchBanner {
            ScrollView { ReceivingBanner(batch: syncStatus.incoming, style: .prominent) }
        } else if syncStatus.isReceiving {
            ReceivingLibraryView()
        } else {
            EmptyLibraryView(errorReason: syncStatus.lastErrorReason)
        }
    }

    private var content: some View {
        list(visibleAlbums)
    }

    private func list(_ albums: [MediaAlbum]) -> some View {
        List {
            Section {
                Button(action: shuffleAll) {
                    Label("Shuffle All", systemImage: "shuffle")
                        .font(.headline)
                }
                .listRowBackground(shuffleBackground)
                .accessibilityHint(Text("Plays everything on this watch in random order"))
            } header: {
                jobHeader
            }

            if showsBatchBanner {
                Section { ReceivingBanner(batch: syncStatus.incoming) }
            }

            if let newest = newestAlbum(in: albums) {
                Section {
                    NewAlbumRow(album: newest) { onOpen(.album(newest)) }
                }
            }

            Section {
                Button { onOpen(.artists) } label: {
                    BrowseRow(
                        symbol: "music.mic",
                        title: "Artists",
                        detail: WatchFormat.artists(ArtistGroup.groups(from: albums).count)
                    )
                }
                .buttonStyle(.plain)
            }

            Section("Albums") {
                Color.clear.frame(height: 0).id("albums").listRowBackground(Color.clear).accessibilityHidden(true)
                ForEach(albums) { album in
                    AlbumListRow(album: album) { onOpen(.album(album)) }
                        .id(rowIdentity(of: album, in: albums))
                }
            }

            if syncStatus.isReceiving && !showsBatchBanner {
                Section {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Receiving from iPhone…")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let notice = SyncErrorNotice(reason: syncStatus.lastErrorReason) {
                Section {
                    Label(notice.message, systemImage: notice.symbol)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if syncStatus.storage.totalBytes > 0 {
                Section {
                    Button { onOpen(.storage) } label: { storageRow }
                        .buttonStyle(.plain)
                        .id("end")
                }
            }
        }
        .listStyle(.carousel)
        .albumRemovalFlow()
        .screenshotScroll()
    }

    /// The first album answers to the `firstalbum` landmark of `--shot-scroll`;
    /// every other row keeps its own identity.
    private func rowIdentity(of album: MediaAlbum, in albums: [MediaAlbum]) -> String {
        album.id == albums.first?.id ? "firstalbum" : album.id
    }

    private var shuffleBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(isDimmed ? AnyShapeStyle(Color.white.opacity(0.12)) : AnyShapeStyle(WatchTheme.accentGradient))
    }

    private var storageRow: some View {
        let storage = syncStatus.storage
        return BrowseRow(
            symbol: syncStatus.lastErrorReason == .diskFull ? "exclamationmark.triangle.fill" : "internaldrive",
            title: "Storage",
            detail: String(localized: "\(WatchFormat.bytes(storage.usedBytes)) of music\u{00A0}· \(WatchFormat.bytes(storage.freeBytes)) free"),
            tint: syncStatus.lastErrorReason == .diskFull ? .orange : nil
        )
    }

    private func newestAlbum(in albums: [MediaAlbum]) -> MediaAlbum? {
        guard let newest = store.newestAlbum else { return nil }
        return albums.first { $0.id == newest.id }
    }

    /// The phone's job, above the shuffle row: present only while the phone is
    /// genuinely working on metadata, gone the moment it stops.
    @ViewBuilder private var jobHeader: some View {
        if let content = EnrichmentStatusRow.Content(syncStatus.jobProgress) {
            EnrichmentStatusRow(content: content)
        }
    }

    private func shuffleAll() {
        guard !store.allTracks.isEmpty else { return }
        player.shuffleAll(store.allTracks)
        onShowNowPlaying()
    }
}

struct SyncErrorNotice {
    let message: String
    let symbol: String

    init?(reason: StoreFailureReason?) {
        switch reason {
        case .diskFull:
            message = "Storage full — remove music from your iPhone's Watch screen."
            symbol = "exclamationmark.triangle.fill"
        case .writeFailed:
            message = "Couldn't save a track. It will be retried."
            symbol = "exclamationmark.circle.fill"
        case .sourceMissing, nil:
            return nil
        }
    }
}
