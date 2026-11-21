import Foundation

/// When each part of the showcase's first page arrives, in seconds from the start of its entrance. The views and
/// the haptics both read this, so what the hand feels lands on what the eye sees.
nonisolated enum ShowcaseTiming {
    static let icon: TimeInterval = 0
    static let name: TimeInterval = 0.10
    static let version: TimeInterval = 0.16
    static let versionLands: TimeInterval = 0.34
    static let tagline: TimeInterval = 0.42
    static let firstRow: TimeInterval = 0.56
    static let rowStep: TimeInterval = 0.08
    static let buttonsAfterRows: TimeInterval = 0.14
    static let settle: TimeInterval = 0.36

    static func row(_ index: Int) -> TimeInterval {
        firstRow + Double(index) * rowStep
    }

    static func buttons(rowCount: Int) -> TimeInterval {
        row(max(rowCount - 1, 0)) + buttonsAfterRows
    }
}
