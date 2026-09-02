#if DEBUG && os(iOS)
import UIKit

/// Headless capture of the live paywall — real store prices, real device —
/// for the App Store subscription review screenshot. Launch with
/// `--shot-paywall`; the PNG lands in the app's Documents folder where
/// `devicectl device copy from` can fetch it. Pair it with `--trial-day N`
/// to capture any day of the runway — day 7 for the "less than a day left" status,
/// day 9 for the expired, welcome-back state — without touching the Keychain.
@MainActor
enum PaywallShot {

    static let launchArgument = "--shot-paywall"

    static func runIfRequested(in window: UIWindow) {
        guard CommandLine.arguments.contains(launchArgument) else { return }
        Task {
            try? await Task.sleep(for: .seconds(6))
            guard var top = window.rootViewController else { return }
            while let presented = top.presentedViewController { top = presented }
            PaywallViewController.presentSheet(from: top)
            try? await Task.sleep(for: .seconds(3))
            capture(window)
        }
    }

    private static func capture(_ window: UIWindow) {
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds, format: .init(for: window.traitCollection))
        let image = renderer.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        guard let data = image.pngData(),
              let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        else { return }
        let url = documents.appendingPathComponent("paywall.png")
        do {
            try data.write(to: url)
            AppLogger.info("PaywallShot: wrote \(url.path) (\(Int(image.size.width))×\(Int(image.size.height)) @\(image.scale)x)", category: .ui)
        } catch {
            AppLogger.error("PaywallShot: write failed: \(error.localizedDescription)", category: .ui)
        }
    }
}
#endif
