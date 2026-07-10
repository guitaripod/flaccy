import AppKit

/// Square artwork tile that resolves through the local album cache, then a
/// remote URL via the shared ImageCache, and finally the deterministic
/// placeholder gradient. Reuse-safe via a load token.
final class RemoteArtworkView: NSView {

    private let imageView = NSImageView()
    private let placeholder = CAGradientLayer()
    private var loadToken = UUID()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.addSublayer(placeholder)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var cornerRadius: CGFloat = 8 {
        didSet { layer?.cornerRadius = cornerRadius }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        placeholder.frame = bounds
        CATransaction.commit()
    }

    func configure(localAlbum: String?, localArtist: String?, remoteURL: String?, placeholderSeed: String) {
        let token = UUID()
        loadToken = token
        showPlaceholder(seed: placeholderSeed)

        if let localAlbum, let localArtist,
           let cached = AlbumArtworkCache.shared.thumbnail(forAlbum: localAlbum, artist: localArtist) {
            show(cached)
            return
        }
        if let remoteURL, let cached = ImageCache.shared.image(forKey: remoteURL) {
            show(cached)
            return
        }
        if let localAlbum, let localArtist {
            AlbumArtworkCache.shared.loadThumbnail(forAlbum: localAlbum, artist: localArtist) { [weak self] image in
                guard let self, self.loadToken == token else { return }
                if let image {
                    self.show(image)
                } else {
                    self.loadRemote(remoteURL, token: token)
                }
            }
            return
        }
        loadRemote(remoteURL, token: token)
    }

    private func loadRemote(_ urlString: String?, token: UUID) {
        guard let urlString, !urlString.isEmpty, let url = URL(string: urlString) else { return }
        Task { [weak self] in
            var image = await ImageCache.shared.loadImage(forKey: urlString)
            if image == nil,
               let (data, response) = try? await URLSession.shared.data(from: url),
               (response as? HTTPURLResponse)?.statusCode == 200,
               let fetched = NSImage(data: data) {
                ImageCache.shared.store(fetched, forKey: urlString)
                image = fetched
            }
            guard let self, self.loadToken == token, let image else { return }
            self.show(image)
        }
    }

    private func show(_ image: NSImage) {
        imageView.image = image
        placeholder.isHidden = true
    }

    private func showPlaceholder(seed: String) {
        imageView.image = nil
        placeholder.isHidden = false
        let (base, second) = PlaceholderGradient.colors(seed: seed)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        placeholder.colors = [base.cgColor, second.cgColor]
        placeholder.startPoint = CGPoint(x: 0, y: 1)
        placeholder.endPoint = CGPoint(x: 1, y: 0)
        placeholder.frame = bounds
        CATransaction.commit()
    }
}
