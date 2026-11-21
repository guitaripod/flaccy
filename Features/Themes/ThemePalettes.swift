import FlaccyCore
import os

/// The palettes the app's dynamic colors read. A dynamic color is resolved on
/// whatever thread is drawing, so the palettes sit behind a lock where any
/// thread may read them, apart from the main-actor runtime that sets them.
nonisolated enum ThemePalettes {

    private struct Worn: Sendable {
        var dark: ThemePalette?
        var light: ThemePalette?
        var hasPainted = false
    }

    private static let worn = OSAllocatedUnfairLock(initialState: Worn())

    /// Sets the palettes to paint with; `nil` for both leaves every surface
    /// to the system, which is how Flaccy's own theme looks.
    static func wear(dark: ThemePalette?, light: ThemePalette?) {
        worn.withLock {
            $0 = Worn(dark: dark, light: light, hasPainted: $0.hasPainted || dark != nil || light != nil)
        }
    }

    static func palette(dark: Bool) -> ThemePalette? {
        worn.withLock { dark ? $0.dark : $0.light }
    }

    /// Whether a theme other than Flaccy's own is painting.
    static var isPainting: Bool {
        worn.withLock { $0.dark != nil || $0.light != nil }
    }

    /// Whether a theme has painted since the app was opened. Until one has,
    /// the app draws with the system's own colors and nothing stands between.
    static var hasPainted: Bool {
        worn.withLock { $0.hasPainted }
    }
}
