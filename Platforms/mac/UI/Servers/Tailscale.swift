import AppKit

/// What the Mac side of Flaccy Server knows about Tailscale: whether its app is installed, how to open it, and where to get it.
enum Tailscale {

    private static let bundleIdentifiers = ["io.tailscale.ipn.macos", "io.tailscale.ipn.macsys"]

    static var applicationURL: URL? {
        bundleIdentifiers.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
    }

    static var isInstalled: Bool {
        applicationURL != nil
    }

    static func open() {
        if let app = applicationURL {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            openDownloadPage()
        }
    }

    static func openDownloadPage() {
        guard let url = SharingCopy.tailscaleDownload else { return }
        NSWorkspace.shared.open(url)
    }
}
