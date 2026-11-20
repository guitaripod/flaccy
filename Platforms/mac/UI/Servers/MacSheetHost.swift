import AppKit

/// The window a sheet that opens by itself hangs from: the main window, also while Flaccy is in the background, when
/// AppKit reports no main or key window.
@MainActor
enum MacSheetHost {

    static var window: NSWindow? {
        NSApp.mainWindow ?? NSApp.keyWindow ?? NSApp.windows.first {
            $0.isVisible && $0.sheetParent == nil && !($0 is NSPanel) && $0.contentViewController != nil
        }
    }
}
