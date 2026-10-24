import FlaccyCore
import SwiftUI

/// How the watch's storage divides, from its last heartbeat. Mirrors the
/// phone's meter: Flaccy's music, everything else, and what is left, clamped so
/// the three always add up to the capacity.
struct StorageBreakdown: Equatable {

    let flaccy: Int64
    let other: Int64
    let free: Int64
    let total: Int64

    init?(_ storage: WatchStorage) {
        guard storage.totalBytes > 0 else { return nil }
        total = storage.totalBytes
        free = min(max(0, storage.freeBytes), total)
        flaccy = min(max(0, storage.usedBytes), total - free)
        other = max(0, total - free - flaccy)
    }
}

struct StorageView: View {

    @Environment(WatchLibraryStore.self) private var store
    @Environment(WatchSyncStatus.self) private var syncStatus
    @Environment(PendingRemovals.self) private var pending
    @Environment(\.isLuminanceReduced) private var isDimmed
    @Environment(\.dynamicTypeSize) private var typeSize

    let onRemovedAll: () -> Void

    @State private var isConfirmingRemoveAll = false
    @State private var removeAllBytes: Int64 = 0

    var body: some View {
        let albums = pending.visible(store.albums)
        let songCount = albums.reduce(0) { $0 + $1.items.count }
        screen(albums: albums, songCount: songCount)
        .navigationTitle("Storage")
        .confirmationDialog(
            "Remove all music?",
            isPresented: $isConfirmingRemoveAll,
            titleVisibility: .visible
        ) {
            Button("Remove All Music", role: .destructive) { removeAll(albums) }
        } message: {
            Text("Frees \(WatchFormat.bytes(removeAllBytes)). Your music stays on your iPhone.")
        }
    }

    private func screen(albums: [MediaAlbum], songCount: Int) -> some View {
        ScrollView {
            VStack(spacing: 10) {
                if let breakdown = StorageBreakdown(syncStatus.storage) {
                    summary(breakdown)
                    StorageGauge(breakdown: breakdown)
                    legend(breakdown)
                }
                Text(WatchFormat.inventory(albums: albums.count, songs: songCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .monospacedDigit()
                if syncStatus.lastErrorReason == .diskFull, let notice = SyncErrorNotice(reason: .diskFull) {
                    Label(notice.message, systemImage: notice.symbol)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button(role: .destructive) {
                    removeAllBytes = AlbumRemoval.footprint(of: albums)
                    isConfirmingRemoveAll = true
                } label: {
                    Label("Remove All Music", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .tint(.red)
                .disabled(albums.isEmpty)
                .padding(.top, 4)
                .id("end")
            }
            .padding(.vertical, 4)
        }
        .screenshotScroll(anchor: .bottom)
    }

    private func summary(_ breakdown: StorageBreakdown) -> some View {
        VStack(spacing: 0) {
            Text(WatchFormat.bytes(breakdown.flaccy))
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text("of music")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func legend(_ breakdown: StorageBreakdown) -> some View {
        VStack(spacing: 4) {
            LegendRow(style: StorageGauge.flaccyStyle(isDimmed: isDimmed), name: "Flaccy", bytes: breakdown.flaccy)
            LegendRow(style: StorageGauge.otherStyle, name: "Other", bytes: breakdown.other)
            LegendRow(style: StorageGauge.freeStyle, name: "Free", bytes: breakdown.free)
        }
    }

    private func removeAll(_ albums: [MediaAlbum]) {
        AlbumRemoval.remove(albums, hiding: pending)
        onRemovedAll()
    }
}

private struct LegendRow: View {

    @Environment(\.dynamicTypeSize) private var typeSize

    let style: AnyShapeStyle
    let name: LocalizedStringKey
    let bytes: Int64

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                dot
                Text(name).font(.footnote)
                Spacer(minLength: 4)
                Text(WatchFormat.bytes(bytes))
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    dot
                    Text(name).font(.footnote)
                }
                Text(WatchFormat.bytes(bytes))
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(name))
        .accessibilityValue(Text(verbatim: WatchFormat.bytes(bytes)))
    }

    private var dot: some View {
        Circle().fill(style).frame(width: 8, height: 8)
    }
}

/// The three-way bar: Flaccy in the accent, everything else in grey, free as
/// the empty track. A segment that exists is never thinner than its own height,
/// so 40 MB of music on a 32 GB watch is still visible as a sliver.
struct StorageGauge: View {

    @Environment(\.isLuminanceReduced) private var isDimmed

    private static let height: CGFloat = 12
    private static let gap: CGFloat = 2

    let breakdown: StorageBreakdown

    static func flaccyStyle(isDimmed: Bool) -> AnyShapeStyle {
        isDimmed ? AnyShapeStyle(Color.white.opacity(0.8)) : AnyShapeStyle(WatchTheme.accentGradient)
    }

    static let otherStyle = AnyShapeStyle(Color.gray.opacity(0.7))
    static let freeStyle = AnyShapeStyle(Color.white.opacity(0.18))

    var body: some View {
        GeometryReader { proxy in
            let widths = segmentWidths(in: proxy.size.width)
            HStack(spacing: Self.gap) {
                segment(Self.flaccyStyle(isDimmed: isDimmed), width: widths.flaccy)
                segment(Self.otherStyle, width: widths.other)
                segment(Self.freeStyle, width: widths.free)
            }
        }
        .frame(height: Self.height)
        .clipShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Storage"))
        .accessibilityValue(Text(verbatim: spokenValue))
    }

    @ViewBuilder private func segment(_ style: AnyShapeStyle, width: CGFloat) -> some View {
        if width > 0 {
            Rectangle().fill(style).frame(width: width)
        }
    }

    /// Splits the bar by byte share after reserving the gaps, then lifts any
    /// non-empty segment to a visible minimum, taking the difference from free.
    private func segmentWidths(in available: CGFloat) -> (flaccy: CGFloat, other: CGFloat, free: CGFloat) {
        let parts = [breakdown.flaccy, breakdown.other, breakdown.free]
        let gaps = Self.gap * CGFloat(max(0, parts.filter { $0 > 0 }.count - 1))
        let usable = max(0, available - gaps)
        let total = CGFloat(max(1, breakdown.total))
        var widths = parts.map { usable * CGFloat($0) / total }
        for index in 0..<2 where parts[index] > 0 && widths[index] < Self.height {
            widths[2] = max(0, widths[2] - (Self.height - widths[index]))
            widths[index] = Self.height
        }
        return (widths[0], widths[1], widths[2])
    }

    private var spokenValue: String {
        String(localized: "Flaccy \(WatchFormat.bytes(breakdown.flaccy)), other \(WatchFormat.bytes(breakdown.other)), free \(WatchFormat.bytes(breakdown.free))")
    }
}
