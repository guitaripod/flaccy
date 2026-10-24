import FlaccyCore
import UIKit

extension LyricsViewController {

    /// A small button over the lines whose menu shifts the lyrics earlier or
    /// later when they run ahead of or behind the singing. The menu stays open
    /// between presses so a correction can be dialled in by ear.
    func makeTimingButton() -> UIButton {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "clock")
        config.baseForegroundColor = .white.withAlphaComponent(0.7)
        config.background.backgroundColor = .white.withAlphaComponent(0.12)
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 9, leading: 9, bottom: 9, trailing: 9)
        let earlier = UIAction(
            title: String(localized: "Show Lyrics Earlier"),
            image: UIImage(systemName: "minus.circle"),
            attributes: .keepsMenuPresented
        ) { [weak self] _ in
            self?.nudgeOffset(by: -Self.offsetStepMs)
        }
        let later = UIAction(
            title: String(localized: "Show Lyrics Later"),
            image: UIImage(systemName: "plus.circle"),
            attributes: .keepsMenuPresented
        ) { [weak self] _ in
            self?.nudgeOffset(by: Self.offsetStepMs)
        }
        let reset = UIAction(
            title: String(localized: "Reset Timing"),
            image: UIImage(systemName: "arrow.counterclockwise")
        ) { [weak self] _ in
            self?.setOffset(0)
        }
        let button = UIButton(configuration: config)
        button.menu = UIMenu(title: String(localized: "Lyrics Timing"), children: [offsetItem, earlier, later, reset])
        button.showsMenuAsPrimaryAction = true
        button.accessibilityLabel = String(localized: "Lyrics timing")
        button.isHidden = true
        return button
    }

    /// The row in the top corner holding the timing note chip and, right of it,
    /// the timing button. Hidden members collapse, so the button keeps its
    /// corner while the chip comes and goes.
    func makeTimingControls() -> UIStackView {
        let stack = UIStackView(arrangedSubviews: [timingNoteChip, timingButton])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
        ])
        return stack
    }

    /// A quiet pill beside the clock that names why the words are not filled
    /// in, and opens the longer reason.
    func makeTimingNoteChip() -> UIButton {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "info.circle")
        config.imagePlacement = .leading
        config.imagePadding = 5
        config.baseForegroundColor = .white.withAlphaComponent(0.7)
        config.background.backgroundColor = .white.withAlphaComponent(0.12)
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 9, leading: 12, bottom: 9, trailing: 12)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.scaled(.footnote, size: 13, weight: .semibold)
            return attributes
        }
        let button = TimingNoteChipButton(configuration: config, primaryAction: UIAction { [weak self] _ in
            self?.presentTimingNote()
        })
        button.accessibilityHint = LyricsTimingNoteCopy.accessibilityHint
        button.isHidden = true
        return button
    }

    /// Computes the note once for the document just applied and shows or hides
    /// the chip to match.
    func showTimingNote(for document: LyricsDocument) {
        guard let kind = LyricsTimingNote.kind(for: document) else {
            hideTimingNote()
            return
        }
        timingNoteKind = kind
        timingNoteChip.configuration?.title = LyricsTimingNoteCopy.label(for: kind)
        timingNoteChip.isHidden = false
    }

    func hideTimingNote() {
        timingNoteKind = nil
        timingNoteChip.isHidden = true
        if presentedViewController is TimingNoteViewController {
            dismiss(animated: false)
        }
    }

    func presentTimingNote() {
        guard let kind = timingNoteKind, presentedViewController == nil else { return }
        lineSelectionFeedback.impactOccurred()
        let note = TimingNoteViewController(kind: kind)
        note.modalPresentationStyle = .popover
        if let popover = note.popoverPresentationController {
            popover.sourceView = timingNoteChip
            popover.sourceRect = timingNoteChip.bounds
            popover.permittedArrowDirections = .up
            popover.delegate = note
        }
        present(note, animated: true)
    }

    func nudgeOffset(by delta: Int) {
        setOffset((lyrics?.offsetMs ?? 0) + delta)
    }

    func setOffset(_ offsetMs: Int) {
        guard var lyrics else { return }
        let clamped = min(max(offsetMs, -Self.offsetLimitMs), Self.offsetLimitMs)
        lyrics.offsetMs = clamped
        self.lyrics = lyrics
        offsetItem.title = Self.offsetText(clamped)
        LyricsService.shared.saveOffset(track: trackTitle, artist: artistName, offsetMs: clamped)
        lineSelectionFeedback.impactOccurred()
        needsLineRefresh = true
        syncDisplayLink()
    }

    /// "In sync", or the correction as a signed number of seconds.
    static func offsetText(_ offsetMs: Int) -> String {
        guard offsetMs != 0 else { return String(localized: "In sync") }
        let seconds = Double(abs(offsetMs)) / 1000
        let sign = offsetMs > 0 ? "+" : "\u{2212}"
        return "\(sign)\(String(format: "%.1f", seconds)) s"
    }
}
