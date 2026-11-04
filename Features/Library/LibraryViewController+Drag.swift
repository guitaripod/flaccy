import FlaccyCore
import UIKit

extension LibraryViewController: UICollectionViewDragDelegate {

    func collectionView(
        _ collectionView: UICollectionView,
        itemsForBeginning session: UIDragSession,
        at indexPath: IndexPath
    ) -> [UIDragItem] {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return [] }
        let (tracks, name) = draggedSongs(for: item)
        return TrackDrag.items(for: tracks, named: name)
    }

    /// The songs a Library tile carries when dragged: an album's songs, a
    /// song, or an artist's songs as their page plays them. Playlists and
    /// suggestions stay put.
    private func draggedSongs(for item: LibraryItem) -> ([Track], String) {
        switch item {
        case .album(let album), .recentAlbum(let album):
            return (album.tracks, album.title)
        case .song(let track):
            return ([track], track.title)
        case .artist(let artist):
            let albums = viewModel.albumsForArtist(artist.name)
            let tracks = ArtistDetailViewController.ownedTracks(of: artist.name, albums: albums.credited, appearsOn: albums.appearsOn)
            return (tracks, artist.name)
        case .playlist, .suggestedPlaylist, .charts, .wantlist:
            return ([], "")
        }
    }
}
