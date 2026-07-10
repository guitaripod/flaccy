#if canImport(UIKit)
import UIKit

public typealias PlatformImage = UIImage
public typealias PlatformColor = UIColor
#elseif canImport(AppKit)
import AppKit

public typealias PlatformImage = NSImage
public typealias PlatformColor = NSColor

nonisolated extension NSImage {

    var cgImage: CGImage? {
        cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    convenience init(cgImage: CGImage) {
        self.init(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    func jpegData(compressionQuality: CGFloat) -> Data? {
        guard let cgImage else { return nil }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: compressionQuality])
    }

    /// AppKit images need no decode pre-pass; decoding at target size already
    /// happens in the ImageIO paths, so this mirrors the UIKit API as identity.
    func preparingForDisplay() -> NSImage? {
        self
    }
}
#endif
