import CoreImage
import FlaccyCore
import UIKit

/// The hero's cover, enlarged and blurred once, fading into the page by about
/// 640 pt. The blur is rendered a single time per cover and cached, never per
/// frame.
final class HomeBackdropView: UIView {

    static let fadeHeight: CGFloat = 640
    nonisolated private static let blurSide: CGFloat = 96
    nonisolated private static let blurRadius: CGFloat = 10

    nonisolated(unsafe) private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 12
        return cache
    }()

    nonisolated private static let context = CIContext(options: [.useSoftwareRenderer: false])

    private let imageView = UIImageView()
    private let fade = CAGradientLayer()
    private var shownKey: String?
    private var token = UUID()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.alpha = 0
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        fade.colors = [UIColor.black.cgColor, UIColor.clear.cgColor]
        fade.startPoint = CGPoint(x: 0.5, y: 0)
        fade.endPoint = CGPoint(x: 0.5, y: 1)
        layer.mask = fade
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        fade.frame = bounds
    }

    /// Tints the page with `album`'s cover, or clears it with nil.
    func show(album: Album?) {
        guard let album else {
            shownKey = nil
            token = UUID()
            UIView.animate(withDuration: 0.3) { self.imageView.alpha = 0 }
            return
        }
        let key = album.id
        guard key != shownKey else { return }
        shownKey = key
        let current = UUID()
        token = current
        if let cached = Self.cache.object(forKey: key as NSString) {
            present(cached)
            return
        }
        AlbumArtworkCache.shared.loadThumbnail(forAlbum: album.title, artist: album.artist) { [weak self] image in
            guard let image else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                guard let blurred = Self.blurred(image) else { return }
                Self.cache.setObject(blurred, forKey: key as NSString)
                DispatchQueue.main.async {
                    guard let self, self.token == current else { return }
                    self.present(blurred)
                }
            }
        }
    }

    private func present(_ image: UIImage) {
        imageView.image = image
        let opacity: CGFloat = traitCollection.userInterfaceStyle == .dark ? 0.6 : 0.4
        UIView.animate(withDuration: 0.4) { self.imageView.alpha = opacity }
    }

    nonisolated private static func blurred(_ image: UIImage) -> UIImage? {
        let side = blurSide
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        let small = renderer.image { _ in image.draw(in: CGRect(x: 0, y: 0, width: side, height: side)) }
        guard let input = CIImage(image: small), let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(blurRadius, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage?.cropped(to: input.extent),
              let cgImage = context.createCGImage(output, from: input.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
