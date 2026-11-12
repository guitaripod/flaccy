import AVFoundation
import MidgarCore
import AVKit
import Combine
import UIKit

extension NowPlayingViewController {

    /// Picks the arrangement for the room this view has and for the fold, if
    /// one runs across it, then re-applies it only when something changed.
    func updateLayoutModeIfNeeded() {
        let size = view.bounds.size
        guard size.width > 1, size.height > 1 else { return }
        let focus = isFocused
            ? AdaptiveLayout.splitGeometry(width: size.width, division: view.divisionRegionFrame)
            : nil
        let desired = AdaptiveLayout.playerLayout(size: size, horizontalFold: view.activeHorizontalFold, focus: focus)
        if desired != layoutMode {
            MidgarLog.debug("Now Playing layout \(desired) for \(size), fold \(String(describing: view.activeHorizontalFold))", category: .ui)
            layoutMode = desired
            switch desired {
            case .laptop(let top, let bottom): activateLayoutMode(desired, foldTop: top, foldBottom: bottom)
            default: activateLayoutMode(desired, foldTop: nil, foldBottom: nil)
            }
            view.setNeedsLayout()
        } else if usesCompactControls(in: layoutMode) != compactControlsApplied {
            applyControlFit(for: layoutMode)
        }
        syncLaptopCompanions()
    }

    /// Portrait is the single column. Landscape puts the artwork and title in
    /// a left column and every control in a right column. Laptop keeps the
    /// column but ends the media region at the fold and starts the controls
    /// below it, with lyrics beside the artwork and the queue above the
    /// controls: the same controls in every pose, arranged around the hinge.
    func activateLayoutMode(_ mode: AdaptiveLayout.PlayerLayout, foldTop: CGFloat?, foldBottom: CGFloat?) {
        NSLayoutConstraint.deactivate(modeConstraints)
        let safe = view.safeAreaLayoutGuide
        var constraints: [NSLayoutConstraint] = []
        laptopFoldTopConstraint = nil
        laptopFoldBottomConstraint = nil
        artworkGroupTrailing.isActive = true
        artworkGroupTop.isActive = mode != .landscape
        placeInfoBlock(inControls: mode == .landscape)
        infoBlock.isHidden = mode == .landscape && centerState != .artwork
        switch mode {
        case .portrait:
            constraints = [
                centerContainer.topAnchor.constraint(equalTo: safe.topAnchor, constant: 24),
                centerContainer.leadingAnchor.constraint(equalTo: portraitColumn.leadingAnchor),
                centerContainer.trailingAnchor.constraint(equalTo: portraitColumn.trailingAnchor),
                centerContainer.bottomAnchor.constraint(equalTo: bottomControls.topAnchor, constant: -14),
                bottomControls.leadingAnchor.constraint(equalTo: portraitColumn.leadingAnchor),
                bottomControls.trailingAnchor.constraint(equalTo: portraitColumn.trailingAnchor),
                bottomControls.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -16),
                artworkContainer.heightAnchor.constraint(lessThanOrEqualTo: view.heightAnchor, multiplier: isColumnPane ? 0.34 : 0.42),
                stateContentContainer.leadingAnchor.constraint(equalTo: portraitColumn.leadingAnchor, constant: -columnMargin),
                stateContentContainer.trailingAnchor.constraint(equalTo: portraitColumn.trailingAnchor, constant: columnMargin),
                stateContentContainer.topAnchor.constraint(equalTo: compactHeader.bottomAnchor, constant: 10),
                stateContentContainer.bottomAnchor.constraint(equalTo: centerContainer.bottomAnchor),
                laptopQueueHost.leadingAnchor.constraint(equalTo: bottomControls.leadingAnchor),
                laptopQueueHost.trailingAnchor.constraint(equalTo: bottomControls.trailingAnchor),
                laptopQueueHost.topAnchor.constraint(equalTo: artworkGroup.bottomAnchor, constant: 18),
                laptopQueueHost.bottomAnchor.constraint(equalTo: bottomControls.topAnchor, constant: -12),
            ]
        case .landscape:
            let controlsFillRegion = bottomControls.widthAnchor.constraint(equalTo: landscapeControlsRegion.widthAnchor)
            controlsFillRegion.priority = .init(999)
            let controlsCentered = bottomControls.centerYAnchor.constraint(equalTo: safe.centerYAnchor)
            controlsCentered.priority = .defaultHigh
            constraints = [
                centerContainer.topAnchor.constraint(equalTo: safe.topAnchor, constant: 12),
                centerContainer.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 28),
                centerContainer.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -12),
                centerContainer.widthAnchor.constraint(equalTo: safe.widthAnchor, multiplier: centerState == .artwork ? 0.36 : 0.5),
                landscapeControlsRegion.leadingAnchor.constraint(equalTo: centerContainer.trailingAnchor, constant: 28),
                landscapeControlsRegion.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -28),
                bottomControls.centerXAnchor.constraint(equalTo: landscapeControlsRegion.centerXAnchor),
                bottomControls.widthAnchor.constraint(lessThanOrEqualToConstant: AdaptiveLayout.playerControlsMaximumWidth),
                controlsFillRegion,
                controlsCentered,
                bottomControls.topAnchor.constraint(greaterThanOrEqualTo: safe.topAnchor, constant: 12),
                bottomControls.bottomAnchor.constraint(lessThanOrEqualTo: safe.bottomAnchor, constant: -8),
                artworkContainer.heightAnchor.constraint(lessThanOrEqualTo: view.heightAnchor, multiplier: 0.72),
                artworkGroup.centerYAnchor.constraint(equalTo: centerContainer.centerYAnchor),
                artworkGroup.topAnchor.constraint(greaterThanOrEqualTo: centerContainer.topAnchor),
                stateContentContainer.leadingAnchor.constraint(equalTo: centerContainer.leadingAnchor),
                stateContentContainer.trailingAnchor.constraint(equalTo: centerContainer.trailingAnchor),
                stateContentContainer.topAnchor.constraint(equalTo: compactHeader.bottomAnchor, constant: 10),
                stateContentContainer.bottomAnchor.constraint(equalTo: centerContainer.bottomAnchor),
            ]
        case .laptop:
            let mediaBottom = centerContainer.bottomAnchor.constraint(equalTo: view.topAnchor, constant: (foldTop ?? 0) - 12)
            let queueTop = laptopQueueHost.topAnchor.constraint(equalTo: view.topAnchor, constant: (foldBottom ?? 0) + 10)
            queueTop.priority = .defaultHigh
            laptopFoldTopConstraint = mediaBottom
            laptopFoldBottomConstraint = queueTop
            artworkGroupTrailing.isActive = false
            constraints = [
                centerContainer.topAnchor.constraint(equalTo: safe.topAnchor, constant: 16),
                centerContainer.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 28),
                centerContainer.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -28),
                mediaBottom,
                artworkGroup.trailingAnchor.constraint(equalTo: centerContainer.centerXAnchor, constant: -10),
                bottomControls.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 28),
                bottomControls.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -28),
                bottomControls.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -8),
                artworkContainer.heightAnchor.constraint(lessThanOrEqualTo: centerContainer.heightAnchor, constant: -120),
                stateContentContainer.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
                stateContentContainer.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
                stateContentContainer.topAnchor.constraint(equalTo: compactHeader.bottomAnchor, constant: 10),
                stateContentContainer.bottomAnchor.constraint(equalTo: centerContainer.bottomAnchor),
                laptopLyricsHost.topAnchor.constraint(equalTo: centerContainer.topAnchor),
                laptopLyricsHost.bottomAnchor.constraint(equalTo: centerContainer.bottomAnchor),
                laptopLyricsHost.leadingAnchor.constraint(equalTo: centerContainer.centerXAnchor, constant: 10),
                laptopLyricsHost.trailingAnchor.constraint(equalTo: centerContainer.trailingAnchor),
                laptopQueueHost.leadingAnchor.constraint(equalTo: bottomControls.leadingAnchor),
                laptopQueueHost.trailingAnchor.constraint(equalTo: bottomControls.trailingAnchor),
                laptopQueueHost.bottomAnchor.constraint(equalTo: bottomControls.topAnchor, constant: -10),
                laptopQueueHost.heightAnchor.constraint(greaterThanOrEqualToConstant: 0),
                queueTop,
            ]
        case .focus(let geometry):
            let columnGap = geometry.secondaryLeading - geometry.primaryWidth + 12
            constraints = [
                focusLeftColumn.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                focusLeftColumn.widthAnchor.constraint(equalToConstant: geometry.primaryWidth - 12),
                focusLeftColumn.topAnchor.constraint(equalTo: view.topAnchor),
                focusLeftColumn.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                focusRightColumn.leadingAnchor.constraint(equalTo: focusLeftColumn.trailingAnchor, constant: columnGap),
                focusRightColumn.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -24),
                focusRightColumn.topAnchor.constraint(equalTo: view.topAnchor),
                focusRightColumn.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                centerContainer.topAnchor.constraint(equalTo: safe.topAnchor, constant: 24),
                centerContainer.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 28),
                centerContainer.trailingAnchor.constraint(equalTo: focusLeftColumn.trailingAnchor),
                centerContainer.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -24),
                artworkContainer.heightAnchor.constraint(lessThanOrEqualTo: centerContainer.heightAnchor, constant: -120),
                bottomControls.leadingAnchor.constraint(equalTo: focusRightColumn.leadingAnchor),
                bottomControls.trailingAnchor.constraint(equalTo: focusRightColumn.trailingAnchor),
                bottomControls.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -16),
                stateContentContainer.leadingAnchor.constraint(equalTo: focusRightColumn.leadingAnchor),
                stateContentContainer.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
                stateContentContainer.topAnchor.constraint(equalTo: safe.topAnchor, constant: 16),
                stateContentContainer.bottomAnchor.constraint(equalTo: bottomControls.topAnchor, constant: -12),
            ]
        }
        applyControlFit(for: mode)
        NSLayoutConstraint.activate(constraints)
        modeConstraints = constraints
        refreshCenterVisibility()
    }

    /// Landscape gives the artwork a column to itself, so the title block moves
    /// to the top of the controls column; every other pose keeps it under the
    /// artwork.
    func placeInfoBlock(inControls: Bool) {
        let inControlsNow = infoBlock.superview === bottomControls
        guard inControls != inControlsNow else { return }
        infoBlock.removeFromSuperview()
        if inControls {
            bottomControls.insertArrangedSubview(infoBlock, at: 0)
            bottomControls.setCustomSpacing(14, after: infoBlock)
        } else {
            artworkGroup.insertArrangedSubview(infoBlock, at: 1)
        }
    }

    func isFocusMode(_ mode: AdaptiveLayout.PlayerLayout) -> Bool {
        if case .focus = mode { return true }
        return false
    }

    var isFocusLayout: Bool { isFocusMode(layoutMode) }

    /// Re-applies which center pieces show for the current state and pose
    /// without animating: in focus the artwork stays on the left whatever the
    /// state, and lyrics or the queue fill the right half.
    func refreshCenterVisibility() {
        let showsArtwork = centerState == .artwork
        let keepsArtwork = showsArtwork || isFocusLayout
        artworkGroup.alpha = keepsArtwork ? 1 : 0
        artworkGroup.transform = .identity
        compactHeader.alpha = keepsArtwork ? 0 : 1
        stateContentContainer.alpha = showsArtwork ? 0 : 1
        stateContentContainer.transform = .identity
        artworkGroup.isUserInteractionEnabled = keepsArtwork
        compactHeader.isUserInteractionEnabled = !keepsArtwork
        stateContentContainer.isUserInteractionEnabled = !showsArtwork
    }

    func isLaptop(_ mode: AdaptiveLayout.PlayerLayout) -> Bool {
        if case .laptop = mode { return true }
        return false
    }

    /// Tightens the control column in the laptop pose so the queue fits above
    /// it, and restores the roomier spacing everywhere else.
    func applyControlSpacing(compact: Bool) {
        bottomControls.spacing = compact ? 12 : 22
        bottomControls.setCustomSpacing(compact ? 14 : 28, after: transportStack)
        bottomControls.setCustomSpacing(compact ? 18 : 34, after: volumeRowView)
    }

    /// Narrows the margins and the cover of an iPad's Now Playing column, and
    /// lets the cover give way before the controls do, so the column still
    /// fits a short window (an iPad mini on its side); restores all three
    /// everywhere else.
    func fitColumnPane() {
        portraitColumnFill?.constant = -2 * columnMargin
        if layoutMode == .portrait {
            activateLayoutMode(.portrait, foldTop: nil, foldBottom: nil)
        } else {
            applyControlFit(for: layoutMode)
        }
    }

    /// Whether the controls take their tight spacing and the cover gives way before them: the
    /// laptop and focus poses, an iPad's column, an accessibility text size, and any player too
    /// short for the roomy column, such as an iPhone SE, Display Zoom, or any iPhone on its side.
    func usesCompactControls(in mode: AdaptiveLayout.PlayerLayout) -> Bool {
        if isLaptop(mode) || isFocusMode(mode) || isColumnPane { return true }
        if traitCollection.preferredContentSizeCategory.isAccessibilityCategory { return true }
        switch mode {
        case .portrait: return view.bounds.height < AdaptiveLayout.playerRoomyPortraitMinimumHeight
        case .landscape: return view.bounds.height < AdaptiveLayout.playerRoomyLandscapeMinimumHeight
        default: return false
        }
    }

    /// Spaces the controls for the room `mode` has and lets a compact player's cover shrink
    /// before the title, the badges and the controls are squeezed: at its usual priority the
    /// cover kept its full width on a short screen and pushed the action row off the bottom.
    func applyControlFit(for mode: AdaptiveLayout.PlayerLayout) {
        let compact = usesCompactControls(in: mode)
        compactControlsApplied = compact
        artworkPreferredWidth?.priority = compact ? .init(740) : .init(999)
        applyControlSpacing(compact: compact)
    }

    var columnMargin: CGFloat {
        isColumnPane ? 20 : 28
    }

    /// True while this player is an iPad's Now Playing column: a narrow, tall
    /// pane that tightens its controls and lists what plays next under the
    /// title.
    var isColumnPane: Bool {
        isPaneMode && paneStyle == .column
    }

    var isLaptopLayout: Bool {
        if case .laptop = layoutMode { return true }
        return false
    }

    /// Shows the companions the laptop pose adds to the artwork state (lyrics
    /// beside the cover, the queue above the controls) and tears them down in
    /// every other pose so nothing observes the player for no reason. A pane
    /// tall enough to leave room under the title (an iPad's Now Playing
    /// column) shows what plays next there too.
    func syncLaptopCompanions() {
        let queueRoom = bottomControls.frame.minY - 10 - (laptopQueueHost.frame.minY)
        let showsLyrics = isLaptopLayout && centerState == .artwork && AudioPlayer.shared.currentTrack != nil
        let showsPaneQueue = isColumnPane && layoutMode == .portrait && centerState == .artwork
            && queueRoom >= AdaptiveLayout.paneQueueMinimumHeight
        let showsQueue = (isLaptopLayout && centerState != .queue && queueRoom >= 96) || showsPaneQueue
        setCompanion(
            laptopLyricsHost, visible: showsLyrics, current: laptopLyricsChild,
            make: {
                guard let track = AudioPlayer.shared.currentTrack else { return nil }
                return LyricsViewController(track: track.title, artist: track.artist, album: track.albumTitle)
            },
            store: { [weak self] in self?.laptopLyricsChild = $0 as? LyricsViewController }
        )
        setCompanion(
            laptopQueueHost, visible: showsQueue, current: laptopQueueChild,
            make: { [weak self] in
                let controller = QueueViewController()
                controller.listsUpNextOnly = showsPaneQueue
                controller.onPushRequest = { viewController in self?.dismissAndPush(viewController) }
                return controller
            },
            store: { [weak self] in self?.laptopQueueChild = $0 as? QueueViewController }
        )
    }

    func setCompanion(
        _ host: UIView, visible: Bool, current: UIViewController?,
        make: () -> UIViewController?, store: (UIViewController?) -> Void
    ) {
        host.isHidden = !visible
        if visible, current == nil, let child = make() {
            addChild(child)
            child.view.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(child.view)
            NSLayoutConstraint.activate([
                child.view.topAnchor.constraint(equalTo: host.topAnchor),
                child.view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                child.view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                child.view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            ])
            child.didMove(toParent: self)
            store(child)
        } else if !visible, let current {
            current.willMove(toParent: nil)
            current.view.removeFromSuperview()
            current.removeFromParent()
            store(nil)
        }
    }
}
