import FlaccyCore
import UIKit

extension LyricsViewController: UITableViewDataSource {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        document.lines.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let line = document.lines[indexPath.row]
        let lit = litLines.contains(indexPath.row)
        if line.isInterlude {
            let cell = tableView.dequeueReusableCell(withIdentifier: InterludeCell.reuseID, for: indexPath) as! InterludeCell
            cell.configure(isCurrent: lit)
            if lit { cell.setLitBeats(line.litBeats(at: lastLyricTime)) }
            return cell
        }
        let cell = tableView.dequeueReusableCell(withIdentifier: LyricCell.reuseID, for: indexPath) as! LyricCell
        cell.configure(line: line, isCurrent: lit)
        if lit { cell.showProgress(line.progress(at: lastLyricTime)) }
        return cell
    }
}

extension LyricsViewController: UITableViewDelegate {

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let line = document.lines[indexPath.row]
        lineSelectionFeedback.impactOccurred()
        let target = line.start + (lyrics?.offsetSeconds ?? 0)
        AudioPlayer.shared.seek(to: max(0, target - Self.seekLeadIn))
        scrollResumeWorkItem?.cancel()
        isUserScrolling = false
        needsLineRefresh = true
        aimScroll(atRow: indexPath.row)
    }

    func tableView(
        _ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard isCurrentTrack, !document.lines[indexPath.row].isInterlude else { return nil }
        let row = indexPath.row
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: [
                UIAction(title: LyricShareCopy.fromLine, image: UIImage(systemName: "quote.bubble")) { _ in
                    self?.presentLyricShare(line: row)
                }
            ])
        }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        scrollResumeWorkItem?.cancel()
        isUserScrolling = true
        cancelScroll()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            scheduleScrollResume()
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        scheduleScrollResume()
    }

    func scheduleScrollResume() {
        scrollResumeWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.isUserScrolling = false
        }
        scrollResumeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: workItem)
    }
}
