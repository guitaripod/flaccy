import MidgarCore
#if DEBUG
import FlaccyCore
import FlaccyEngine
import ImageIO
import UIKit

/// Drives the playlist cover sheet the way a person does on a phone: a picture
/// already in the frame and pinched, then a landscape photo through the same
/// decode path the photo picker hands its bytes to, Save, the playlist page's
/// cover, and the sheet again over the saved cover with a portrait photo. Each
/// check logs `PlaylistCoverExercise PASS/FAIL`, the run ends with
/// `PLAYLIST COVER EXERCISE PASSED` or `FAILED`, and the playlist it made is
/// deleted. Launch with `--exercise-playlist-cover` over a library
/// (`--seed-screenshots` gives a simulator one).
@MainActor
enum PlaylistCoverExercise {

    static let launchArgument = "--exercise-playlist-cover"

    private static let photoLongSide = 4032
    private static let photoShortSide = 3024
    private static var results: [Bool] = []

    static func runIfRequested(window: UIWindow?) {
        guard CommandLine.arguments.contains(launchArgument) else { return }
        Task { await run(window: window) }
    }

    private static func run(window: UIWindow?) async {
        guard await libraryArrived() else { return finish(failure: "the library never loaded") }
        try? await Task.sleep(for: .seconds(2))
        guard let host = topController(of: window) else { return finish(failure: "no screen to present from") }
        let tracks = Library.shared.albums.prefix(3).compactMap { $0.tracks.first }
        guard !tracks.isEmpty else { return finish(failure: "the library has no tracks") }

        let database = DatabaseManager.shared
        let name = "Cover Exercise \(UUID().uuidString.prefix(6))"
        guard let playlist = try? database.createPlaylist(name: name), let id = playlist.id else {
            return finish(failure: "a playlist could not be created")
        }
        for track in tracks {
            try? database.addTrackToPlaylist(playlistId: id, trackFileURL: TrackContextMenu.relativePath(for: track))
        }
        let subject = ArtworkSubject(playlistId: id, name: name, tracks: tracks)
        let detail = PlaylistDetailViewController(playlistId: id, playlistName: name)
        let navigation = UINavigationController(rootViewController: detail)
        navigation.modalPresentationStyle = .fullScreen
        host.present(navigation, animated: true)
        await waitUntil { detail.view.window != nil }
        try? await Task.sleep(for: .seconds(1))

        await exerciseFirstCover(subject: subject, detail: detail)
        await exerciseReplacingSavedCover(subject: subject, detail: detail)

        navigation.dismiss(animated: true)
        try? database.deletePlaylist(id: id)
        let passed = results.allSatisfy { $0 }
        let line = "PLAYLIST COVER EXERCISE \(passed ? "PASSED" : "FAILED"): \(results.filter { $0 }.count) of \(results.count)"
        if passed { MidgarLog.info(line, category: .general) } else { MidgarLog.error(line, category: .general) }
    }

    /// A first cover for a playlist with none: a square picture, a pinch, then
    /// a landscape photo that must arrive framed edge to edge and save as the
    /// photo's centre, which the playlist page then shows.
    private static func exerciseFirstCover(subject: ArtworkSubject, detail: PlaylistDetailViewController) async {
        let editor = ArtworkEditorViewController.present(for: subject, from: detail)
        await waitUntil { editor.view.window != nil && editor.debugCrop.debugSide > 0 }
        try? await Task.sleep(for: .milliseconds(600))
        let crop = editor.debugCrop
        report("a playlist with no cover opens on an empty frame", !crop.hasImage)

        editor.debugLoad(pngData(squareImage(side: 1600)), source: "exercise square")
        report("a square picture fills the frame (\(describe(crop)))", fills(crop, aspect: 1))
        crop.debugPinch(by: 1.6)
        report("a pinch zooms in (\(describe(crop)))", crop.debugDisplayedSize.width > crop.debugSide * 1.5)

        editor.debugLoad(jpegData(quadrantImage(width: photoLongSide, height: photoShortSide)), source: "exercise photo")
        let aspect = CGFloat(photoLongSide) / CGFloat(photoShortSide)
        report("a landscape photo after it arrives framed edge to edge, not zoomed in (\(describe(crop)))", fills(crop, aspect: aspect))
        report("the photo starts at its smallest zoom, so pinching out stops at the frame", crop.debugAtMinimumZoom)
        report("Save is enabled", editor.debugSaveEnabled)

        editor.debugSave()
        await waitUntil { AlbumArtworkEditor.hasCustomCover(subject) }
        let saved = (try? DatabaseManager.shared.playlistCover(id: playlistId(of: subject))).flatMap(decode)
        report("Save stores a square cover (\(saved.map { "\($0.width) × \($0.height)" } ?? "none"))", saved.map { $0.width == $0.height } == true)
        report("the stored cover is the photo's centre, not black (\(saved.map(quadrantReport) ?? "none"))", saved.map(showsQuadrants) == true)

        await waitUntil { editor.view.window == nil }
        await waitUntil(seconds: 6) { detail.debugCoverSnapshot().map(showsQuadrants) == true }
        report(
            "the playlist page shows the chosen cover (\(detail.debugCoverSnapshot().map(quadrantReport) ?? "none"))",
            detail.debugCoverSnapshot().map(showsQuadrants) == true
        )
    }

    /// The sheet again over the saved cover, which loads into the frame first,
    /// then a portrait photo that must still arrive framed edge to edge and
    /// replace the cover on Save.
    private static func exerciseReplacingSavedCover(subject: ArtworkSubject, detail: PlaylistDetailViewController) async {
        let editor = ArtworkEditorViewController.present(for: subject, from: detail)
        await waitUntil { editor.view.window != nil && editor.debugCrop.hasImage }
        try? await Task.sleep(for: .milliseconds(600))
        let crop = editor.debugCrop
        report("reopening shows the saved cover in the frame (\(describe(crop)))", crop.hasImage && fills(crop, aspect: 1))

        editor.debugLoad(jpegData(quadrantImage(width: photoShortSide, height: photoLongSide)), source: "exercise portrait")
        let aspect = CGFloat(photoShortSide) / CGFloat(photoLongSide)
        report("a portrait photo over the saved cover arrives framed edge to edge (\(describe(crop)))", fills(crop, aspect: aspect))
        report("the portrait photo starts at its smallest zoom", crop.debugAtMinimumZoom)

        let previous = try? DatabaseManager.shared.playlistCover(id: playlistId(of: subject))
        editor.debugSave()
        await waitUntil { (try? DatabaseManager.shared.playlistCover(id: playlistId(of: subject))) != previous }
        let saved = (try? DatabaseManager.shared.playlistCover(id: playlistId(of: subject))).flatMap(decode)
        report("the replacement saves the portrait's centre, not black (\(saved.map(quadrantReport) ?? "none"))", saved.map(showsQuadrants) == true)
        await waitUntil { editor.view.window == nil }
        await waitUntil(seconds: 6) { detail.debugCoverSnapshot().map(showsQuadrants) == true }
        report(
            "the playlist page shows the replacement (\(detail.debugCoverSnapshot().map(quadrantReport) ?? "none"))",
            detail.debugCoverSnapshot().map(showsQuadrants) == true
        )
    }

    /// Whether the picture covers the square exactly along its short side and
    /// runs past it along the long side by the picture's own proportions.
    private static func fills(_ crop: ArtworkCropView, aspect: CGFloat) -> Bool {
        let side = crop.debugSide
        let shown = crop.debugDisplayedSize
        let expected = aspect >= 1
            ? CGSize(width: side * aspect, height: side)
            : CGSize(width: side, height: side / aspect)
        return abs(shown.width - expected.width) < 2 && abs(shown.height - expected.height) < 2
    }

    private static func describe(_ crop: ArtworkCropView) -> String {
        let shown = crop.debugDisplayedSize
        return "frame \(Int(crop.debugSide)) pt, picture \(Int(shown.width)) × \(Int(shown.height)) pt"
    }

    private static func playlistId(of subject: ArtworkSubject) -> Int64 {
        if case .playlist(let id) = subject.kind { return id }
        return -1
    }

    private static func showsQuadrants(_ image: CGImage) -> Bool {
        let near = Int(Double(image.width) * 0.3)
        let far = Int(Double(image.width) * 0.65)
        let nearY = Int(Double(image.height) * 0.3)
        let farY = Int(Double(image.height) * 0.65)
        return isColor(pixel(image, near, nearY), .red) && isColor(pixel(image, far, nearY), .green)
            && isColor(pixel(image, near, farY), .blue) && isColor(pixel(image, far, farY), .yellow)
    }

    private static func quadrantReport(_ image: CGImage) -> String {
        let near = Int(Double(image.width) * 0.3)
        let far = Int(Double(image.width) * 0.65)
        let nearY = Int(Double(image.height) * 0.3)
        let farY = Int(Double(image.height) * 0.65)
        return [(near, nearY), (far, nearY), (near, farY), (far, farY)]
            .map { pixel(image, $0.0, $0.1) }
            .map { "\($0.0),\($0.1),\($0.2)" }
            .joined(separator: " | ")
    }

    private enum Swatch { case red, green, blue, yellow }

    private static func isColor(_ rgb: (Int, Int, Int), _ swatch: Swatch) -> Bool {
        let (r, g, b) = rgb
        switch swatch {
        case .red: return r > 170 && g < 90 && b < 90
        case .green: return g > 140 && r < 90 && b < 90
        case .blue: return b > 170 && r < 90 && g < 90
        case .yellow: return r > 190 && g > 170 && b < 90
        }
    }

    /// One pixel, counted from the top-left corner.
    private static func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (Int, Int, Int) {
        var bytes = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return (0, 0, 0) }
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
    }

    /// Red top left, green top right, blue bottom left, yellow bottom right.
    private static func quadrantImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        let quarters: [(CGColor, CGRect)] = [
            (CGColor(red: 0.9, green: 0.12, blue: 0.12, alpha: 1), CGRect(x: 0, y: height / 2, width: width / 2, height: height - height / 2)),
            (CGColor(red: 0.12, green: 0.78, blue: 0.12, alpha: 1), CGRect(x: width / 2, y: height / 2, width: width - width / 2, height: height - height / 2)),
            (CGColor(red: 0.12, green: 0.12, blue: 0.9, alpha: 1), CGRect(x: 0, y: 0, width: width / 2, height: height / 2)),
            (CGColor(red: 0.94, green: 0.86, blue: 0.12, alpha: 1), CGRect(x: width / 2, y: 0, width: width - width / 2, height: height / 2)),
        ]
        for (color, rect) in quarters {
            context.setFillColor(color)
            context.fill(rect)
        }
        return context.makeImage()!
    }

    private static func squareImage(side: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.5, green: 0.3, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return context.makeImage()!
    }

    private static func pngData(_ image: CGImage) -> Data {
        UIImage(cgImage: image).pngData() ?? Data()
    }

    private static func jpegData(_ image: CGImage) -> Data {
        UIImage(cgImage: image).jpegData(compressionQuality: 0.92) ?? Data()
    }

    private static func decode(_ data: Data) -> CGImage? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    }

    private static func topController(of window: UIWindow?) -> UIViewController? {
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }

    private static func libraryArrived() async -> Bool {
        for _ in 0..<120 {
            if !Library.shared.albums.isEmpty { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }

    private static func waitUntil(seconds: Double = 8, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func report(_ expectation: String, _ passed: Bool) {
        results.append(passed)
        let line = "PlaylistCoverExercise \(passed ? "PASS" : "FAIL"): \(expectation)"
        if passed { MidgarLog.info(line, category: .general) } else { MidgarLog.error(line, category: .general) }
    }

    private static func finish(failure: String) {
        MidgarLog.error("PLAYLIST COVER EXERCISE FAILED: \(failure)", category: .general)
    }
}
#endif
