import AppKit
import MidgarCore
import AVFoundation
import AVKit
import Combine

extension NowPlayingViewController {

    /// Lyrics (left) and queue (right) are independent columns that show or hide
    /// on their own; any combination — art alone, art + one, or all three — is
    /// valid, and the equal-fill body redistributes the visible columns.
    func togglePanel(_ panel: Panel) {
        switch panel {
        case .lyrics:
            lyricsShown.toggle()
            setColumn(lyricsColumn, visible: lyricsShown)
            lyricsPanel.setActive(lyricsShown)
            NowPlayingLayout.lyricsShown = lyricsShown
        case .queue:
            queueShown.toggle()
            setColumn(queueColumn, visible: queueShown)
            queuePanel.setActive(queueShown)
            NowPlayingLayout.queueShown = queueShown
        }
        refreshCapsuleToggles()
    }

    /// Which side each panel occupies is the reader's choice and is remembered,
    /// the way it is on Linux — some people want the lyrics under their eye on
    /// the left, some on the right.
    @objc func swapPanelSides() {
        swapSides.toggle()
        NowPlayingLayout.swapSides = swapSides
        applyColumnOrder()
        refreshCapsuleToggles()
    }

    func applyColumnOrder() {
        guard let body, let center = body.arrangedSubviews.first(where: {
            $0 !== lyricsColumn && $0 !== queueColumn
        }) else { return }
        let ordered = swapSides
            ? [queueColumn, center, lyricsColumn]
            : [lyricsColumn, center, queueColumn]
        guard body.arrangedSubviews != ordered else { return }
        for column in ordered {
            body.removeArrangedSubview(column)
            body.addArrangedSubview(column)
        }
    }

    /// Shows or hides one side column, fading it in while the columns beside it
    /// slide to their new widths. A glass surface that is resized under implicit
    /// animation keeps the frame it had, and so does everything inside it, so a
    /// panel would stay at its old width and clip its trailing controls;
    /// `settleVisibleColumns` re-lays the visible columns out without animation
    /// right after the group to put them at the width the constraints ask for.
    func setColumn(_ column: NSView, visible: Bool) {
        guard column.isHidden == visible else { return }
        let widthConstraint = column === lyricsColumn ? lyricsWidthConstraint : queueWidthConstraint
        widthConstraint?.isActive = visible
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            column.isHidden = !visible
            column.alphaValue = visible ? 1 : 0
            return
        }
        if visible {
            column.alphaValue = 0
            column.isHidden = false
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.26
            context.allowsImplicitAnimation = true
            column.animator().alphaValue = visible ? 1 : 0
            column.isHidden = !visible
            self.view.layoutSubtreeIfNeeded()
        }
        settleVisibleColumns()
    }

    func settleVisibleColumns() {
        NSAnimationContext.runAnimationGroup { context in
            context.allowsImplicitAnimation = false
            for column in [lyricsColumn, queueColumn] where !column.isHidden {
                invalidateLayout(of: column)
                column.layoutSubtreeIfNeeded()
            }
        }
    }

    func invalidateLayout(of target: NSView) {
        target.needsLayout = true
        target.subviews.forEach(invalidateLayout(of:))
    }

    func refreshCapsuleToggles() {
        lyricsCapsule.isActiveToggle = lyricsShown
        queueCapsule.isActiveToggle = queueShown
        swapCapsule?.isHidden = !(lyricsShown && queueShown)
    }

    @objc func queueChanged() {
        let upNext = max(0, player.queue.count - player.currentIndex - 1)
        queueCapsule.title = upNext > 0 ? String(localized: "Up Next · \(upNext)") : String(localized: "Up Next")
    }

    func buildCenterColumn() -> NSView {
        configureArtwork()
        configureLabels()

        let titleRow = NSStackView(views: [titleLabel, badgeContainer, loveButton])
        titleRow.orientation = .horizontal
        titleRow.spacing = 10
        titleRow.alignment = .centerY

        let content = NSStackView(views: [artworkContainer, titleRow, artistButton, albumLabel])
        content.orientation = .vertical
        content.alignment = .centerX
        content.spacing = 10
        content.setCustomSpacing(24, after: artworkContainer)
        content.setCustomSpacing(4, after: titleRow)
        content.setCustomSpacing(2, after: artistButton)
        content.translatesAutoresizingMaskIntoConstraints = false

        let slot = NSView()
        slot.addSubview(content)
        let artwork = artworkContainer.widthAnchor.constraint(equalToConstant: 380)
        artwork.priority = .defaultHigh
        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: slot.centerXAnchor),
            content.centerYAnchor.constraint(equalTo: slot.centerYAnchor),
            content.topAnchor.constraint(greaterThanOrEqualTo: slot.topAnchor),
            content.bottomAnchor.constraint(lessThanOrEqualTo: slot.bottomAnchor),
            content.widthAnchor.constraint(lessThanOrEqualToConstant: 600),
            content.widthAnchor.constraint(lessThanOrEqualTo: slot.widthAnchor),
            artwork,
            artworkContainer.widthAnchor.constraint(lessThanOrEqualToConstant: 430),
            artworkContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 170),
            artworkContainer.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor),
            artworkContainer.heightAnchor.constraint(equalTo: artworkContainer.widthAnchor),
            titleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 460),
        ])
        return slot
    }

    /// A glass side column hosting a lyrics or queue panel; both are permanently
    /// installed as children so a hidden column keeps its state, and each is
    /// suspended via `setActive` when not visible.
    func buildColumn(_ column: NSView, hosting panel: NSViewController, title: String) {
        addChild(panel)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 14, weight: .bold)
        titleLabel.textColor = MacColors.primaryLabel

        let header = NSStackView(views: [titleLabel])
        header.orientation = .horizontal
        header.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 4, right: 16)

        panel.view.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: [header, panel.view])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        panel.view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let glass = MacLiquidGlass.surface(hosting: stack, cornerRadius: 20)
        glass.translatesAutoresizingMaskIntoConstraints = false
        column.addSubview(glass)
        column.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: column.topAnchor, constant: 4),
            glass.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            glass.bottomAnchor.constraint(equalTo: column.bottomAnchor, constant: -4),
        ])
    }

    func configureArtwork() {
        artworkContainer.wantsLayer = true
        artworkContainer.layer?.cornerRadius = 14
        artworkContainer.layer?.cornerCurve = .continuous
        artworkContainer.layer?.masksToBounds = true
        artworkContainer.layer?.addSublayer(artworkPlaceholder)
        artworkContainer.translatesAutoresizingMaskIntoConstraints = false
        artworkView.imageScaling = .scaleProportionallyUpOrDown
        artworkView.translatesAutoresizingMaskIntoConstraints = false
        artworkContainer.addSubview(artworkView)
        NSLayoutConstraint.activate([
            artworkView.topAnchor.constraint(equalTo: artworkContainer.topAnchor),
            artworkView.leadingAnchor.constraint(equalTo: artworkContainer.leadingAnchor),
            artworkView.trailingAnchor.constraint(equalTo: artworkContainer.trailingAnchor),
            artworkView.bottomAnchor.constraint(equalTo: artworkContainer.bottomAnchor),
        ])
        let click = NSClickGestureRecognizer(target: self, action: #selector(togglePlayPause))
        artworkContainer.addGestureRecognizer(click)
    }
}
