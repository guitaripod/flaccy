import MidgarCore
#if DEBUG && os(iOS)
import FlaccyCore
import UIKit

/// Presents one equalizer screen over a seeded, fictional library and saves a
/// PNG of the window to tmp/eqshots, for checking the design on a device and
/// for the store captures. Launch with `--shot-equalizer <scene>` where scene
/// is simple, advanced, presets, outputs or import.
@MainActor
enum EqualizerShots {

    static let launchArgument = "--shot-equalizer"

    static let importSample = """
    # Flaccy Equalizer: Over-ear correction
    Preamp: -6.2 dB
    Filter 1: ON LSC Fc 105 Hz Gain 5.5 dB Q 0.70
    Filter 2: ON PK Fc 210 Hz Gain -2.4 dB Q 0.80
    Filter 3: ON PK Fc 780 Hz Gain 1.3 dB Q 0.90
    Filter 4: ON PK Fc 1900 Hz Gain -1.8 dB Q 1.60
    Filter 5: ON PK Fc 3100 Hz Gain 4.1 dB Q 2.10
    Filter 6: ON PK Fc 4800 Hz Gain -2.6 dB Q 3.00
    Filter 7: ON PK Fc 6400 Hz Gain 2.2 dB Q 4.00
    Filter 8: ON PK Fc 9200 Hz Gain -4.3 dB Q 3.40
    Filter 9: ON PK Fc 12500 Hz Gain 1.9 dB Q 1.20
    Filter 10: ON HSC Fc 15500 Hz Gain -1.5 dB Q 0.70
    """

    static func runIfRequested(in window: UIWindow) {
        guard let index = CommandLine.arguments.firstIndex(of: launchArgument) else { return }
        let scene = CommandLine.arguments.dropFirst(index + 1).first ?? "simple"
        Task { await run(scene: scene, window: window) }
    }

    private static func run(scene: String, window: UIWindow) async {
        try? await Task.sleep(for: .seconds(2.5))
        let engine = EqualizerEngine.shared
        engine.start()
        engine.isDemoSignal = true
        let airPods = EqualizerOutput(id: "bluetooth.demo", name: "AirPods Pro", kind: .bluetooth)
        let headphones = EqualizerOutput(id: "wired.headphones", name: "Headphones", kind: .headphones)
        let isSimple = scene == "simple"
        engine.seedDemo(
            activeProfileID: isSimple ? EqualizerPresets.id(forKey: "bassBoost") : "demo.warm",
            pretendOutput: isSimple ? headphones : airPods
        )

        let nav = EqualizerViewController.makePresented()
        var presenter: UIViewController = window.rootViewController ?? UIViewController()
        while let top = presenter.presentedViewController { presenter = top }
        presenter.present(nav, animated: false)
        try? await Task.sleep(for: .seconds(1))

        let accent = EqualizerTheme.fallbackAccent
        switch scene {
        case "presets":
            nav.pushViewController(EqualizerPresetsViewController(startingOn: .presets, accent: accent), animated: false)
        case "outputs":
            nav.pushViewController(EqualizerPresetsViewController(startingOn: .outputs, accent: accent), animated: false)
        case "import":
            nav.pushViewController(EqualizerImportViewController(accent: accent, initialText: importSample), animated: false)
        default:
            break
        }
        try? await Task.sleep(for: .seconds(2))
        save(window: window, name: scene)
    }

    private static func save(window: UIWindow, name: String) {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("eqshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let url = folder.appendingPathComponent("\(name).png")
        try? image.pngData()?.write(to: url)
        MidgarLog.info("EqualizerShots saved \(url.path)", category: .ui)
    }
}
#endif
