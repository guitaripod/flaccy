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
        MacToast.show(String(localized: "Finding links…"), style: .info, in: window)
        Task {
            let outcome = await lookup(subject)
            guard let result = outcome.result else {
                if let message = outcome.failureMessage(title: subject.title) {
                    MacToast.show(message, style: .error, in: window)
                }
                return
            }
            let anchor = view ?? window?.contentView
            guard let anchor else { return }
            let text = String(localized: "\(result.title) by \(result.artist)")
            let picker = NSSharingServicePicker(items: [text, result.pageURL])
            picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        }
    }

    static func copyLink(_ subject: Subject, from view: NSView?) {
        let window = view?.window ?? NSApp.keyWindow
        MacToast.show(String(localized: "Finding links…"), style: .info, in: window)
        Task {
            let outcome = await lookup(subject)
            guard let result = outcome.result else {
                if let message = outcome.failureMessage(title: subject.title) {
                    MacToast.show(message, style: .error, in: window)
                }
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(result.pageURL.absoluteString, forType: .string)
            MacToast.show(String(localized: "Link copied"), style: .success, in: window)
        }
    }

    private static func lookup(_ subject: Subject) async -> SonglinkOutcome {
        switch subject {
        case .track(let title, let artist):
            await SonglinkService.shared.lookup(title: title, artist: artist)
        case .album(let title, let artist):
            await SonglinkService.shared.lookupAlbum(title: title, artist: artist)
        }
    }
}
