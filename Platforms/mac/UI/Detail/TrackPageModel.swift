import AppKit
import FlaccyCore

/// One song of a page with the number its row shows: the track number on an
/// album, the place in the list on a playlist.
struct TrackPageEntry {
    let track: Track
    let number: Int
    let rowID: Int64?
}

/// A disc or vinyl side of an album: a run of entries under one name.
struct TrackPageSection {
    let label: String
    let range: Range<Int>
    let duration: TimeInterval
}

/// What a song page shows and how its layouts reach back into the page: the
/// songs in their order, the discs they fall into, the filter in force and the
/// actions a row can ask for. Every layout reads one model, so a rebuild of
/// the page is one assignment.
final class TrackPageModel {

    let kind: TrackPageLayout.PageKind
    var entries: [TrackPageEntry] = []
    var sections: [TrackPageSection]?
    var query = ""
    var pageName: () -> String = { "" }
    var play: ([Track], Int) -> Void = { tracks, index in
        AudioPlayer.shared.play(tracks, startingAt: index)
    }
    var menu: (TrackPageEntry, NSView?) -> NSMenu = { entry, anchor in
        MacTrackMenuFactory.menu(for: entry.track, anchor: anchor)
    }
    var remove: (([TrackPageEntry]) -> Void)?
    var reorder: ((IndexSet, Int) -> Void)?

    init(kind: TrackPageLayout.PageKind) {
        self.kind = kind
    }

    /// Whether the performers vary, which is what earns an album's table an
    /// Artist column; a playlist always has one.
    var artistsVary: Bool {
        guard let first = entries.first?.track.artist else { return false }
        return kind == .playlist || entries.contains { $0.track.artist != first }
    }

    func discLabel(forEntry index: Int) -> String {
        sections?.first { $0.range.contains(index) }?.label ?? ""
    }

    func matches(_ index: Int) -> Bool {
        Self.matches(entries[index].track, needle: query)
    }

    /// Whether a song answers a page's filter; `needle` is already lowercase.
    static func matches(_ track: Track, needle: String) -> Bool {
        needle.isEmpty
            || track.title.lowercased().contains(needle)
            || track.artist.lowercased().contains(needle)
            || track.albumTitle.lowercased().contains(needle)
    }

    var matchCount: Int {
        query.isEmpty ? entries.count : entries.indices.filter(matches).count
    }
}

/// One way of drawing a page's songs. The page swaps surfaces without
/// rebuilding the others' data: a surface is built when first shown and
/// dropped when the songs change under it.
protocol TrackPageSurface: AnyObject {
    var view: NSView { get }
    func reload()
    func applyFilter()
    func refreshPlaying()
    func refreshLoved()
    func frame(ofEntry index: Int) -> NSRect?
}

/// A view that reports when its width changes, so a layout can follow the room
/// it has without owning a resize observer.
final class WidthReportingView: NSView {

    var onWidthChange: ((CGFloat) -> Void)?

    private var reportedWidth: CGFloat = -1

    override func layout() {
        super.layout()
        guard bounds.width != reportedWidth else { return }
        reportedWidth = bounds.width
        onWidthChange?(bounds.width)
    }
}

/// A scroll view that never scrolls on its own: a table inside it is as tall as
/// its rows and the page scrolls it, so the wheel belongs to the page.
final class PassthroughScrollView: NSScrollView {

    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}
