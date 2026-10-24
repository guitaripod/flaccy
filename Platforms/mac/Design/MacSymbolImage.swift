import AppKit

/// Shares symbol images across surfaces. AppKit caches the underlying glyphs,
/// but every call still creates an image object and a configuration; the same
/// play, shuffle and settings symbols are rebuilt by every screen.
enum MacSymbolImage {

    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 256
        return cache
    }()

    static func image(_ name: String, accessibilityDescription: String? = nil) -> NSImage? {
        let key = "\(name)\0\(accessibilityDescription ?? "")" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = NSImage(
            systemSymbolName: name, accessibilityDescription: accessibilityDescription
        ) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    static func configured(
        _ name: String,
        pointSize: CGFloat,
        weight: NSFont.Weight,
        accessibilityDescription: String? = nil
    ) -> NSImage? {
        let key = "\(name)\0\(pointSize)\0\(weight.rawValue)\0\(accessibilityDescription ?? "")" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        guard let image = image(name, accessibilityDescription: accessibilityDescription)?
            .withSymbolConfiguration(configuration) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}
