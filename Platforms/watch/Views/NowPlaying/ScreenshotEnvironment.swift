import SwiftUI

extension View {

    /// Applies the simulator-only screenshot overrides below; a no-op in
    /// device builds.
    func screenshotEnvironment() -> some View {
        modifier(ScreenshotEnvironment())
    }
}

/// `--shot-type-size large|xxxLarge|accessibility1…accessibility5` forces a
/// Dynamic Type size and `--shot-dim` the Always-On (reduced luminance)
/// appearance. The watchOS simulator can be told neither from the command
/// line, and both change layout decisions that need to be seen.
private struct ScreenshotEnvironment: ViewModifier {

    func body(content: Content) -> some View {
        content
            .transformEnvironment(\.dynamicTypeSize) { size in
                if let forced = Self.typeSize { size = forced }
            }
            .transformEnvironment(\.isLuminanceReduced) { reduced in
                if Self.reducesLuminance { reduced = true }
            }
    }

    private static var typeSize: DynamicTypeSize? {
        #if targetEnvironment(simulator)
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "--shot-type-size"), flag + 1 < arguments.count else { return nil }
        return DynamicTypeSize.allCases.first { String(describing: $0) == arguments[flag + 1] }
        #else
        nil
        #endif
    }

    private static var reducesLuminance: Bool {
        #if targetEnvironment(simulator)
        ProcessInfo.processInfo.arguments.contains("--shot-dim")
        #else
        false
        #endif
    }
}
