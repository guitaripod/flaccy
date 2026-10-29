import AppKit
import FlaccyCore

/// A view that takes a `flaccy://server` link dropped on it, as text or as a URL, and outlines itself while one hovers.
final class LinkDropView: NSView {

    var onLink: ((ParsedServerLink) -> Void)?

    private var isTargeted = false {
        didSet {
            guard isTargeted != oldValue else { return }
            layer?.borderWidth = isTargeted ? 2 : 0
            layer?.borderColor = NSColor.controlAccentColor.cgColor
            layer?.cornerRadius = 10
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        registerForDraggedTypes([.URL, .string])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static func link(in pasteboard: NSPasteboard) -> ParsedServerLink? {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.map(\.absoluteString) ?? []
        let texts = [pasteboard.string(forType: .string)].compactMap { $0 }
        return (urls + texts).lazy.compactMap { ParsedServerLink(text: $0) }.first
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard Self.link(in: sender.draggingPasteboard) != nil else { return [] }
        isTargeted = true
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        isTargeted = false
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        isTargeted = false
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        isTargeted = false
        guard let link = Self.link(in: sender.draggingPasteboard) else { return false }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        onLink?(link)
        return true
    }
}
