import FlaccyCore
import UIKit

extension AlbumDetailViewController: UITableViewDragDelegate {

    func tableView(_ tableView: UITableView, itemsForBeginning session: UIDragSession, at indexPath: IndexPath) -> [UIDragItem] {
        guard let track = dataSource.itemIdentifier(for: indexPath) else { return [] }
        return TrackDrag.items(for: [track], named: track.title)
    }
}
