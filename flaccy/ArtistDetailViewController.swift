import UIKit

nonisolated enum ArtistDetailSection: Int, CaseIterable, Sendable {
    case header
    case albums
}

nonisolated enum ArtistDetailItem: Hashable, Sendable {
    case header(ArtistHeaderInfo)
    case album(Album)
}

nonisolated struct ArtistHeaderInfo: Hashable, Sendable {
    let name: String
    let bio: String?
    let genre: String?
    let albumCount: Int
    let trackCount: Int
    let artwork: UIImage?

    nonisolated static func == (lhs: ArtistHeaderInfo, rhs: ArtistHeaderInfo) -> Bool {
        lhs.name == rhs.name
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(name)
    }
}

final class ArtistDetailViewController: UIViewController {

    private let artistName: String
    private var albums: [Album]
    private var bio: String?
    private var artistImageURL: String?
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<ArtistDetailSection, ArtistDetailItem>!
    private let impactLight = UIImpactFeedbackGenerator(style: .light)

    init(artistName: String, albums: [Album]) {
        self.artistName = artistName
        self.albums = albums
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.largeTitleDisplayMode = .never

        fetchArtistInfo()
        setupCollectionView()
        configureDataSource()
        applySnapshot()
    }

    private func fetchArtistInfo() {
        guard let artist = try? DatabaseManager.shared.fetchArtist(name: artistName) else { return }
        if let rawBio = artist.bio, !rawBio.isEmpty {
            bio = rawBio
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        artistImageURL = artist.imageURL
    }

    private func setupCollectionView() {
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: createLayout())
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.delegate = self
        collectionView.backgroundColor = .clear
        view.addSubview(collectionView)

        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func createLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { sectionIndex, _ in
            guard let section = ArtistDetailSection(rawValue: sectionIndex) else { return nil }

            switch section {
            case .header:
                let itemSize = NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1.0),
                    heightDimension: .estimated(200)
                )
                let item = NSCollectionLayoutItem(layoutSize: itemSize)
                let groupSize = NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1.0),
                    heightDimension: .estimated(200)
                )
                let group = NSCollectionLayoutGroup.vertical(layoutSize: groupSize, subitems: [item])
                let layoutSection = NSCollectionLayoutSection(group: group)
                layoutSection.contentInsets = NSDirectionalEdgeInsets(top: 16, leading: 24, bottom: 8, trailing: 24)
                return layoutSection

            case .albums:
                let itemSize = NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(0.5),
                    heightDimension: .estimated(240)
                )
                let item = NSCollectionLayoutItem(layoutSize: itemSize)
                let groupSize = NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1.0),
                    heightDimension: .estimated(240)
                )
                let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [item, item])
                group.interItemSpacing = .fixed(12)
                let layoutSection = NSCollectionLayoutSection(group: group)
                layoutSection.interGroupSpacing = 16
                layoutSection.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 16, trailing: 16)

                let headerSize = NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1.0),
                    heightDimension: .estimated(32)
                )
                let sectionHeader = NSCollectionLayoutBoundarySupplementaryItem(
                    layoutSize: headerSize,
                    elementKind: UICollectionView.elementKindSectionHeader,
                    alignment: .top
                )
                layoutSection.boundarySupplementaryItems = [sectionHeader]
                return layoutSection
            }
        }
    }

    private func configureDataSource() {
        let headerCellRegistration = UICollectionView.CellRegistration<ArtistHeaderCell, ArtistHeaderInfo> { [weak self] cell, _, info in
            cell.configure(with: info)
            cell.onBioToggle = {
                self?.collectionView.collectionViewLayout.invalidateLayout()
            }
        }

        let albumCellRegistration = UICollectionView.CellRegistration<AlbumCell, Album> { cell, _, album in
            cell.configure(with: album)
        }

        let sectionHeaderRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { supplementaryView, _, _ in
            var config = UIListContentConfiguration.plainHeader()
            config.text = "Albums"
            config.textProperties.font = .systemFont(ofSize: 20, weight: .bold)
            config.textProperties.color = .label
            supplementaryView.contentConfiguration = config
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) {
            collectionView, indexPath, item in
            switch item {
            case .header(let info):
                return collectionView.dequeueConfiguredReusableCell(using: headerCellRegistration, for: indexPath, item: info)
            case .album(let album):
                return collectionView.dequeueConfiguredReusableCell(using: albumCellRegistration, for: indexPath, item: album)
            }
        }

        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            guard ArtistDetailSection(rawValue: indexPath.section) == .albums else { return nil }
            return collectionView.dequeueConfiguredReusableSupplementary(using: sectionHeaderRegistration, for: indexPath)
        }
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<ArtistDetailSection, ArtistDetailItem>()
        snapshot.appendSections(ArtistDetailSection.allCases)

        let totalTracks = albums.reduce(0) { $0 + $1.tracks.count }
        let genre = albums.compactMap(\.genre).first
        let artwork = albums.first?.artwork

        let headerInfo = ArtistHeaderInfo(
            name: artistName,
            bio: bio,
            genre: genre,
            albumCount: albums.count,
            trackCount: totalTracks,
            artwork: artwork
        )
        snapshot.appendItems([.header(headerInfo)], toSection: .header)
        snapshot.appendItems(albums.map { .album($0) }, toSection: .albums)
        dataSource.apply(snapshot, animatingDifferences: false)
    }
}

extension ArtistDetailViewController: UICollectionViewDelegate {

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        switch item {
        case .album(let album):
            impactLight.impactOccurred()
            let vc = AlbumDetailViewController(album: album)
            navigationController?.pushViewController(vc, animated: true)
        case .header:
            break
        }
    }
}

final class ArtistHeaderCell: UICollectionViewCell {

    var onBioToggle: (() -> Void)?

    private let artistImageView = UIImageView()
    private let nameLabel = UILabel()
    private let genreLabel = UILabel()
    private let statsLabel = UILabel()
    private let bioLabel = UILabel()
    private let readMoreButton = UIButton(type: .system)
    private var bioExpanded = false

    override init(frame: CGRect) {
        super.init(frame: frame)

        artistImageView.contentMode = .scaleAspectFill
        artistImageView.clipsToBounds = true
        artistImageView.backgroundColor = .tertiarySystemFill
        artistImageView.tintColor = .tertiaryLabel
        artistImageView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 36, weight: .ultraLight)

        nameLabel.font = .systemFont(ofSize: 28, weight: .bold)
        nameLabel.numberOfLines = 2
        nameLabel.textAlignment = .center

        genreLabel.font = .systemFont(ofSize: 15, weight: .medium)
        genreLabel.textColor = .secondaryLabel
        genreLabel.textAlignment = .center

        statsLabel.font = .systemFont(ofSize: 13, weight: .regular)
        statsLabel.textColor = .tertiaryLabel
        statsLabel.textAlignment = .center

        bioLabel.font = .preferredFont(forTextStyle: .subheadline)
        bioLabel.textColor = .secondaryLabel
        bioLabel.numberOfLines = 4

        readMoreButton.setTitle("Read more", for: .normal)
        readMoreButton.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        readMoreButton.contentHorizontalAlignment = .leading
        readMoreButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            self.bioExpanded.toggle()
            self.bioLabel.numberOfLines = self.bioExpanded ? 0 : 4
            self.readMoreButton.setTitle(self.bioExpanded ? "Read less" : "Read more", for: .normal)
            UIView.animate(withDuration: 0.3) {
                self.onBioToggle?()
            }
        }, for: .touchUpInside)

        let imageSize: CGFloat = 100
        artistImageView.layer.cornerRadius = imageSize / 2
        artistImageView.translatesAutoresizingMaskIntoConstraints = false

        let bioStack = UIStackView(arrangedSubviews: [bioLabel, readMoreButton])
        bioStack.axis = .vertical
        bioStack.spacing = 4

        let mainStack = UIStackView(arrangedSubviews: [artistImageView, nameLabel, genreLabel, statsLabel, bioStack])
        mainStack.axis = .vertical
        mainStack.spacing = 8
        mainStack.setCustomSpacing(16, after: artistImageView)
        mainStack.setCustomSpacing(4, after: nameLabel)
        mainStack.setCustomSpacing(4, after: genreLabel)
        mainStack.setCustomSpacing(16, after: statsLabel)
        mainStack.alignment = .center
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(mainStack)

        let bioStackWidth = bioStack.widthAnchor.constraint(equalTo: mainStack.widthAnchor)
        bioStackWidth.priority = .defaultHigh

        NSLayoutConstraint.activate([
            artistImageView.widthAnchor.constraint(equalToConstant: imageSize),
            artistImageView.heightAnchor.constraint(equalToConstant: imageSize),
            bioStackWidth,
            mainStack.topAnchor.constraint(equalTo: contentView.topAnchor),
            mainStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            mainStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(with info: ArtistHeaderInfo) {
        nameLabel.text = info.name

        if let artwork = info.artwork {
            artistImageView.contentMode = .scaleAspectFill
            artistImageView.image = artwork
        } else {
            artistImageView.contentMode = .center
            artistImageView.image = UIImage(systemName: "person.crop.circle.fill")
        }

        if let genre = info.genre, !genre.isEmpty {
            genreLabel.text = genre
            genreLabel.isHidden = false
        } else {
            genreLabel.isHidden = true
        }

        let albumWord = info.albumCount == 1 ? "album" : "albums"
        let trackWord = info.trackCount == 1 ? "track" : "tracks"
        statsLabel.text = "\(info.albumCount) \(albumWord) \u{00B7} \(info.trackCount) \(trackWord)"

        if let bio = info.bio, !bio.isEmpty {
            bioLabel.text = bio
            bioLabel.isHidden = false
            readMoreButton.isHidden = false
        } else {
            bioLabel.isHidden = true
            readMoreButton.isHidden = true
        }
    }
}
