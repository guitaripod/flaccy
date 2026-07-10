import AppKit

/// Desktop Songlink actions: resolve a track or album to its song.link page,
/// then hand it to the system share picker or the pasteboard, with toast
/// feedback for the lookup states.
enum MacSonglinkSharing {

    enum Subject {
        case track(title: String, artist: String)
        case album(title: String, artist: String)

        var title: String {
            switch self {
            case .track(let title, _), .album(let title, _): title
            }
        }

        var artist: String {
            switch self {
            case .track(_, let artist), .album(_, let artist): artist
            }
        }
    }

    static func share(_ subject: Subject, from view: NSView?) {
        let window = view?.window ?? NSApp.keyWindow
        MacToast.show("Finding links…", style: .info, in: window)
        Task {
            guard let result = await lookup(subject) else {
                MacToast.show(failureMessage(for: subject), style: .error, in: window)
                return
            }
            let anchor = view ?? window?.contentView
            guard let anchor else { return }
            let text = "\(result.title) by \(result.artist)"
            let picker = NSSharingServicePicker(items: [text, result.pageURL])
            picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        }
    }

    static func copyLink(_ subject: Subject, from view: NSView?) {
        let window = view?.window ?? NSApp.keyWindow
        MacToast.show("Finding links…", style: .info, in: window)
        Task {
            guard let result = await lookup(subject) else {
                MacToast.show(failureMessage(for: subject), style: .error, in: window)
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(result.pageURL.absoluteString, forType: .string)
            MacToast.show("Link copied", style: .success, in: window)
        }
    }

    private static func lookup(_ subject: Subject) async -> SonglinkResult? {
        switch subject {
        case .track(let title, let artist):
            await SonglinkService.shared.lookup(title: title, artist: artist)
        case .album(let title, let artist):
            await SonglinkService.shared.lookupAlbum(title: title, artist: artist)
        }
    }

    private static func failureMessage(for subject: Subject) -> String {
        switch subject {
        case .track: "Couldn't find links for this track."
        case .album: "Couldn't find links for this album."
        }
    }
}
