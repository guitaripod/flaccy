import FlaccyCore
import UIKit

extension EqualizerViewController {

    func updatePresets(profile: EqualizerProfile) {
        let candidates = engine.state.userProfiles + EqualizerPresets.all
        let order = candidates.map(\.id)
        if order != presetOrder {
            presetsRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
            presetCards.removeAll()
            for candidate in candidates {
                let card = EqualizerPresetCard()
                card.addAction(UIAction { [weak self] _ in
                    self?.impact.impactOccurred()
                    self?.engine.select(profileID: candidate.id)
                }, for: .touchUpInside)
                card.onPreviewRequested = { [weak self] in self?.previewForAccessibility(candidate) }
                presetCards[candidate.id] = card
                presetsRow.addArrangedSubview(card)
            }
            presetOrder = order
            lastPresetStyle = nil
        }
        let style = "\(profile.id)|\(accent.hash)"
        let currentChanged = style != lastPresetStyle
        for candidate in candidates {
            guard let card = presetCards[candidate.id] else { continue }
            let isCurrent = candidate.id == profile.id
            guard currentChanged || isCurrent else { continue }
            card.configure(
                name: EqualizerCopy.name(of: candidate),
                points: thumbnail(for: candidate),
                isCurrent: isCurrent,
                tint: accent
            )
            card.setHeld(auditioner.current?.id == candidate.id && !holdIsCancelling, animated: false)
        }
        if currentChanged, let card = presetCards[profile.id] {
            lastPresetStyle = style
            view.layoutIfNeeded()
            let target = card.frame.insetBy(dx: -24, dy: 0)
            presetsScroll.scrollRectToVisible(target, animated: lastPresetStyle != nil && isViewLoaded && view.window != nil)
        }
    }

    @objc func handleHold(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            endAccessibilityPreview()
            setScrolling(enabled: false)
            holdIsCancelling = false
            selection.prepare()
            trackHold(at: gesture.location(in: presetsBlock))
        case .changed:
            trackHold(at: gesture.location(in: presetsBlock))
        case .ended:
            endHold(keeping: !holdIsCancelling)
        case .cancelled, .failed:
            endHold(keeping: false)
        default:
            break
        }
    }

    /// Follows the finger: switches the audition to the card under it, and flips to the
    /// cancelling state once it has slid far enough off the strip.
    func trackHold(at point: CGPoint) {
        holdPoint = point
        let local = presetsScroll.convert(point, from: presetsBlock)
        let overshoot = max(-local.y, local.y - presetsScroll.bounds.height, 0)
        let cancelling = overshoot > Self.cancelDistance
        if cancelling != holdIsCancelling {
            holdIsCancelling = cancelling
            if cancelling { impact.impactOccurred(intensity: 0.7) } else { selection.selectionChanged() }
            refreshAuditionFeedback()
        }
        if !cancelling, let id = presetID(atContentX: local.x), id != auditioner.current?.id,
           let candidate = engine.allProfiles.first(where: { $0.id == id }) {
            selection.selectionChanged()
            auditioner.begin(candidate)
        }
        updateAutoscroll(visibleX: local.x - presetsScroll.contentOffset.x)
    }

    func presetID(atContentX x: CGFloat) -> String? {
        let cards = presetsRow.arrangedSubviews
        let half = presetsRow.spacing / 2
        guard let hit = cards.first(where: { x < $0.frame.maxX + half }) ?? cards.last else { return nil }
        return presetCards.first(where: { $0.value === hit })?.key
    }

    func setScrolling(enabled: Bool) {
        presetsScroll.isScrollEnabled = enabled
        scroll.isScrollEnabled = enabled
        navigationController?.isModalInPresentation = !enabled
    }

    /// Ends a hold, keeping the heard preset as one change when asked to, and always
    /// putting the sound back to what was in force otherwise.
    func endHold(keeping: Bool) {
        stopAutoscroll()
        let kept = keeping ? auditioner.current : nil
        setScrolling(enabled: true)
        holdIsCancelling = false
        if let kept {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            engine.select(profileID: kept.id)
        }
        auditioner.end()
    }

    func auditionChanged(to profile: EqualizerProfile?) {
        curveView.setPreview(profile?.resolvedBands())
        refreshAuditionFeedback()
        guard let profile else {
            hasAnnouncedAudition = false
            return
        }
        guard !hasAnnouncedAudition else { return }
        hasAnnouncedAudition = true
        UIAccessibility.post(notification: .announcement, argument: String(localized: "Hearing \(EqualizerCopy.name(of: profile))"))
    }

    func refreshAuditionFeedback() {
        let profile = auditioner.current
        hearingPill.set(name: profile.map { EqualizerCopy.name(of: $0) }, cancelling: holdIsCancelling, accent: accent)
        for (id, card) in presetCards {
            card.setHeld(id == profile?.id && !holdIsCancelling, animated: true)
        }
    }

    func updateAutoscroll(visibleX: CGFloat) {
        let edge = Self.autoscrollEdge
        let width = presetsScroll.bounds.width
        if visibleX < edge {
            autoscrollSpeed = -min((edge - visibleX) / edge, 1.5) * 12
        } else if visibleX > width - edge {
            autoscrollSpeed = min((visibleX - (width - edge)) / edge, 1.5) * 12
        } else {
            autoscrollSpeed = 0
        }
        if autoscrollSpeed != 0, autoscrollLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(autoscrollTick))
            link.add(to: .main, forMode: .common)
            autoscrollLink = link
        } else if autoscrollSpeed == 0 {
            stopAutoscroll()
        }
    }

    func stopAutoscroll() {
        autoscrollLink?.invalidate()
        autoscrollLink = nil
        autoscrollSpeed = 0
    }

    @objc func autoscrollTick() {
        let maximum = max(presetsScroll.contentSize.width - presetsScroll.bounds.width, 0)
        let offset = min(max(presetsScroll.contentOffset.x + autoscrollSpeed, 0), maximum)
        guard offset != presetsScroll.contentOffset.x else { return }
        presetsScroll.contentOffset.x = offset
        trackHold(at: holdPoint)
    }

    /// VoiceOver cannot hold and slide, so its Preview action plays the preset for a few
    /// seconds and puts the sound back.
    func previewForAccessibility(_ profile: EqualizerProfile) {
        endAccessibilityPreview()
        auditioner.begin(profile)
        previewTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.accessibilityPreviewSeconds))
            guard !Task.isCancelled else { return }
            self?.previewTimer = nil
            self?.auditioner.end()
        }
    }

    func endAccessibilityPreview() {
        guard previewTimer != nil else { return }
        previewTimer?.cancel()
        previewTimer = nil
        auditioner.end()
    }

    #if DEBUG
    /// Puts the screen in the state a held finger leaves it in, for the screenshot routes.
    func showAuditionForScreenshot(presetKey: String, cancelling: Bool) {
        guard let profile = EqualizerPresets.profile(forKey: presetKey) else { return }
        view.layoutIfNeeded()
        holdIsCancelling = cancelling
        auditioner.begin(profile)
        if let card = presetCards[profile.id] {
            presetsScroll.scrollRectToVisible(card.frame.insetBy(dx: -24, dy: 0), animated: false)
        }
    }
    #endif

    func thumbnail(for profile: EqualizerProfile) -> [Double] {
        if profile.isBuiltIn, let cached = Self.builtInThumbnails[profile.id] { return cached }
        let points = BiquadMath.curve(profile.resolvedBands(), points: 40)
        if profile.isBuiltIn { Self.builtInThumbnails[profile.id] = points }
        return points
    }
}
