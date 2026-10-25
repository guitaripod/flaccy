import Combine
import MidgarCore
import FlaccyCore
import UIKit
import UniformTypeIdentifiers

extension LibraryViewController {

    func badgeAccessories(
        qualityTrack: Track?, loved: Bool, scrobbleCount: Int? = nil, newMix: Bool = false
    ) -> [UICellAccessory] {
        let container = UIStackView()
        container.axis = .horizontal
        container.spacing = 6
        container.alignment = .center

        if newMix {
            container.addArrangedSubview(NewMixChipView())
        }
        if let scrobbleCount {
            container.addArrangedSubview(scrobbleCountView(scrobbleCount))
        }
        if loved {
            let heart = UIImageView(image: UIImage(
                systemName: "heart.fill",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            ))
            heart.tintColor = .systemPink
            heart.accessibilityLabel = String(localized: "Loved")
            heart.isAccessibilityElement = true
            container.addArrangedSubview(heart)
        }
        if qualityTrack?.qualityBadge != nil {
            let badge = QualityBadgeView(size: .compact)
            badge.configure(with: qualityTrack)
            container.addArrangedSubview(badge)
        }
        guard !container.arrangedSubviews.isEmpty else { return [] }
        let size = container.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        container.frame = CGRect(origin: .zero, size: size)
        return [.customView(configuration: .init(
            customView: container,
            placement: .trailing(),
            reservedLayoutWidth: .actual,
            maintainsFixedSize: true
        ))]
    }

    /// A compact play-count pill (waveform glyph + monospaced count) shown on song
    /// rows, sized so it never increases the row height set by the title/subtitle.
    func scrobbleCountView(_ count: Int) -> UIView {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 3
        stack.alignment = .center

        let glyph = UIImageView(image: UIImage(
            systemName: "waveform",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        ))
        glyph.tintColor = .tertiaryLabel

        let label = UILabel()
        label.text = count > 999 ? String(localized: "\(count / 1000)k") : "\(count)"
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabel

        stack.addArrangedSubview(glyph)
        stack.addArrangedSubview(label)
        stack.isAccessibilityElement = true
        stack.accessibilityLabel = String(localized: "\(count) scrobbles")
        return stack
    }

    func configureArtworkRow(
        cell: ListArtworkCell, title: String, subtitle: String,
        albumTitle: String, artist: String, cornerRadius: CGFloat
    ) {
        var content = UIListContentConfiguration.subtitleCell()
        content.text = title
        content.secondaryText = subtitle
        content.secondaryTextProperties.color = .secondaryLabel
        content.imageProperties.cornerRadius = cornerRadius
        content.imageProperties.maximumSize = CGSize(width: 44, height: 44)
        content.imageProperties.reservedLayoutSize = CGSize(width: 44, height: 44)
        if let cached = AlbumArtworkCache.shared.thumbnail(forAlbum: albumTitle, artist: artist) {
            content.image = cached
            cell.currentArtworkKey = nil
        } else {
            content.image = UIImage(systemName: "music.note")
            content.imageProperties.tintColor = .tertiaryLabel
            let artKey = "\(albumTitle)|\(artist)"
            cell.currentArtworkKey = artKey
            AlbumArtworkCache.shared.loadThumbnail(forAlbum: albumTitle, artist: artist) { [weak cell] image in
                guard let cell, cell.currentArtworkKey == artKey, let image,
                      var updated = cell.contentConfiguration as? UIListContentConfiguration else { return }
                updated.image = image
                updated.imageProperties.tintColor = nil
                cell.contentConfiguration = updated
            }
        }
        cell.contentConfiguration = content
    }

    func configureDataSource() {
        let albumGridRegistration = UICollectionView.CellRegistration<AlbumCell, Album> { [weak self] cell, _, album in
            cell.configure(
                with: album,
                qualityTrack: self?.viewModel.representativeTrack(for: album),
                loved: self?.viewModel.isLovedAlbum(album) ?? false
            )
        }

        let albumListRegistration = UICollectionView.CellRegistration<ListArtworkCell, Album> { [weak self] cell, _, album in
            self?.configureArtworkRow(
                cell: cell, title: album.title, subtitle: album.artist,
                albumTitle: album.title, artist: album.artist, cornerRadius: 6
            )
            cell.accessories = self?.badgeAccessories(
                qualityTrack: self?.viewModel.representativeTrack(for: album),
                loved: self?.viewModel.isLovedAlbum(album) ?? false
            ) ?? []
        }

        let albumCompactRegistration = UICollectionView.CellRegistration<ListArtworkCell, Album> { [weak self] cell, _, album in
            var content = UIListContentConfiguration.valueCell()
            content.text = album.title
            content.secondaryText = album.artist
            content.secondaryTextProperties.color = .secondaryLabel
            content.textProperties.font = .scaled(.subheadline, size: 15, weight: .regular)
            cell.contentConfiguration = content
            cell.currentArtworkKey = nil
            cell.accessories = self?.badgeAccessories(
                qualityTrack: self?.viewModel.representativeTrack(for: album),
                loved: self?.viewModel.isLovedAlbum(album) ?? false
            ) ?? []
        }

        let songGridRegistration = UICollectionView.CellRegistration<TrackGridCell, Track> { cell, _, track in
            cell.configure(with: track, loved: LovedTracksService.shared.isLoved(track: track))
        }

        let songCompactRegistration = UICollectionView.CellRegistration<ListArtworkCell, Track> { [weak self] cell, _, track in
            let newMix = track.showsNewMix
            var content = UIListContentConfiguration.valueCell()
            content.text = track.title
            content.secondaryText = track.artist
            content.secondaryTextProperties.color = .secondaryLabel
            content.textProperties.font = .scaled(.subheadline, size: 15, weight: .regular)
            cell.contentConfiguration = content
            cell.currentArtworkKey = nil
            cell.accessories = self?.badgeAccessories(
                qualityTrack: track, loved: LovedTracksService.shared.isLoved(track: track),
                scrobbleCount: self?.viewModel.scrobbleCount(for: track),
                newMix: newMix
            ) ?? []
            cell.accessibilityLabel = newMix
                ? TrackVersionCopy.accessibilityLabel("\(track.title), \(track.artist)", newMix: true)
                : nil
        }

        let artistRegistration = UICollectionView.CellRegistration<ListArtworkCell, ArtistItem> { [weak self] cell, _, artist in
            var content = UIListContentConfiguration.subtitleCell()
            content.text = artist.name
            content.secondaryText = artist.albumCount > 0
                ? String(localized: "\(artist.albumCount) albums")
                : String(localized: "Appears on \(artist.appearanceCount) albums")
            content.secondaryTextProperties.color = .secondaryLabel
            content.imageProperties.cornerRadius = 22
            content.imageProperties.maximumSize = CGSize(width: 44, height: 44)
            content.imageProperties.reservedLayoutSize = CGSize(width: 44, height: 44)

            let firstAlbum = self?.viewModel.firstAlbum(forArtist: artist.name)
            let cachedArt: UIImage? = firstAlbum.flatMap { AlbumArtworkCache.shared.thumbnail(forAlbum: $0.title, artist: $0.artist) }

            if let cachedArt {
                content.image = cachedArt
                cell.currentArtworkKey = nil
            } else {
                content.image = UIImage(systemName: "person.crop.circle.fill")
                content.imageProperties.tintColor = .tertiaryLabel
                if let firstAlbum {
                    let artKey = "\(firstAlbum.title)|\(firstAlbum.artist)|\(artist.name)"
                    cell.currentArtworkKey = artKey
                    AlbumArtworkCache.shared.loadThumbnail(forAlbum: firstAlbum.title, artist: firstAlbum.artist) { [weak cell] image in
                        guard let cell, cell.currentArtworkKey == artKey, let image,
                              var updated = cell.contentConfiguration as? UIListContentConfiguration else { return }
                        updated.image = image
                        updated.imageProperties.tintColor = nil
                        cell.contentConfiguration = updated
                    }
                } else {
                    cell.currentArtworkKey = nil
                }
            }
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]
        }

        let playlistRegistration = UICollectionView.CellRegistration<PlaylistListCell, PlaylistItem> { [weak self] cell, _, playlist in
            var content = UIListContentConfiguration.subtitleCell()
            content.text = playlist.name
            content.secondaryText = String(localized: "\(playlist.trackCount) tracks")
            content.secondaryTextProperties.color = .secondaryLabel
            cell.contentConfiguration = content
            let thumbnail = UICellAccessory.CustomViewConfiguration(
                customView: cell.thumbnail,
                placement: .leading(),
                reservedLayoutWidth: .custom(PlaylistThumbnailView.side.width),
                maintainsFixedSize: true
            )
            cell.accessories = [.customView(configuration: thumbnail), .disclosureIndicator()]
            if let index = self?.playlistAlbumIndex {
                cell.thumbnail.load(playlistId: playlist.id, index: index)
            }
        }

        let suggestedRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, SuggestedPlaylist> { cell, _, suggestion in
            var content = UIListContentConfiguration.subtitleCell()
            content.text = suggestion.title
            content.secondaryText = String(localized: "\(suggestion.subtitle) · \(suggestion.tracks.count) songs")
            content.secondaryTextProperties.color = .secondaryLabel
            content.image = UIImage(systemName: suggestion.systemImage)
            content.imageProperties.tintColor = .tintColor
            content.imageProperties.maximumSize = CGSize(width: 44, height: 44)
            content.imageProperties.reservedLayoutSize = CGSize(width: 44, height: 44)
            cell.contentConfiguration = content
            let play = UIImageView(image: UIImage(
                systemName: "play.circle.fill",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .regular)
            ))
            play.tintColor = .tintColor
            cell.accessories = [.customView(configuration: .init(customView: play, placement: .trailing()))]
        }

        let chartsRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, Int> { cell, _, _ in
            var content = UIListContentConfiguration.subtitleCell()
            content.text = String(localized: "Recap")
            content.secondaryText = String(localized: "Your listening stats")
            content.secondaryTextProperties.color = .secondaryLabel
            content.image = UIImage(systemName: "chart.bar.fill")
            content.imageProperties.tintColor = .systemPink
            content.imageProperties.maximumSize = CGSize(width: 44, height: 44)
            content.imageProperties.reservedLayoutSize = CGSize(width: 44, height: 44)
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]
            cell.accessibilityIdentifier = "library.playlists.recap"
        }

        let wantlistRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, Int> { cell, _, _ in
            var content = UIListContentConfiguration.subtitleCell()
            content.text = String(localized: "Wantlist")
            let unseen = WantlistService.shared.unseenCount()
            content.secondaryText = unseen > 0
                ? String(localized: "\(unseen) new suggestions")
                : String(localized: "Music to get & discoveries")
            content.secondaryTextProperties.color = unseen > 0 ? .systemTeal : .secondaryLabel
            content.image = UIImage(systemName: "sparkle.magnifyingglass")
            content.imageProperties.tintColor = .systemTeal
            content.imageProperties.maximumSize = CGSize(width: 44, height: 44)
            content.imageProperties.reservedLayoutSize = CGSize(width: 44, height: 44)
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]
        }

        let headerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { supplementaryView, _, _ in
            var config = UIListContentConfiguration.header()
            config.text = String(localized: "Recently Played")
            config.textProperties.font = .scaled(.footnote, size: 13, weight: .semibold)
            config.textProperties.color = .secondaryLabel
            supplementaryView.contentConfiguration = config
        }

        let songRegistration = UICollectionView.CellRegistration<ListArtworkCell, Track> { [weak self] cell, _, track in
            self?.configureArtworkRow(
                cell: cell, title: track.title, subtitle: "\(track.artist) · \(track.albumTitle)",
                albumTitle: track.albumTitle, artist: track.artist, cornerRadius: 4
            )
            cell.accessories = self?.badgeAccessories(
                qualityTrack: track, loved: LovedTracksService.shared.isLoved(track: track),
                scrobbleCount: self?.viewModel.scrobbleCount(for: track)
            ) ?? []
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) {
            [weak self] collectionView, indexPath, item in
            let mode = self?.viewModel.layoutMode ?? .grid
            switch item {
            case .recentAlbum(let album):
                return collectionView.dequeueConfiguredReusableCell(
                    using: albumGridRegistration, for: indexPath, item: album
                )
            case .album(let album):
                switch mode {
                case .grid:
                    return collectionView.dequeueConfiguredReusableCell(using: albumGridRegistration, for: indexPath, item: album)
                case .list:
                    return collectionView.dequeueConfiguredReusableCell(using: albumListRegistration, for: indexPath, item: album)
                case .compact:
                    return collectionView.dequeueConfiguredReusableCell(using: albumCompactRegistration, for: indexPath, item: album)
                }
            case .song(let track):
                switch mode {
                case .grid:
                    return collectionView.dequeueConfiguredReusableCell(using: songGridRegistration, for: indexPath, item: track)
                case .list:
                    return collectionView.dequeueConfiguredReusableCell(using: songRegistration, for: indexPath, item: track)
                case .compact:
                    return collectionView.dequeueConfiguredReusableCell(using: songCompactRegistration, for: indexPath, item: track)
                }
            case .artist(let artist):
                return collectionView.dequeueConfiguredReusableCell(
                    using: artistRegistration, for: indexPath, item: artist
                )
            case .playlist(let playlist):
                return collectionView.dequeueConfiguredReusableCell(
                    using: playlistRegistration, for: indexPath, item: playlist
                )
            case .suggestedPlaylist(let suggestion):
                return collectionView.dequeueConfiguredReusableCell(
                    using: suggestedRegistration, for: indexPath, item: suggestion
                )
            case .charts:
                return collectionView.dequeueConfiguredReusableCell(
                    using: chartsRegistration, for: indexPath, item: 0
                )
            case .wantlist:
                return collectionView.dequeueConfiguredReusableCell(
                    using: wantlistRegistration, for: indexPath, item: 0
                )
            }
        }

        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: headerRegistration, for: indexPath)
        }
    }
}
