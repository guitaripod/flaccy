import AppKit
import FlaccyCore
import UniformTypeIdentifiers

extension MacEqualizerViewController {

    func wireDeck() {
        deck.onPointed = { [weak self] id in self?.deckPointed(at: id) }
        deck.onLeft = { [weak self] in self?.deckLeft() }
        deck.onKeep = { [weak self] id in self?.keepPreset(id) }
        deck.onCancel = { [weak self] in self?.cancelAudition() }
        deck.onAuditionBriefly = { [weak self] id in self?.auditionBriefly(id) }
        deck.onHoverPreviewChanged = { [weak self] on in self?.hoverPreviewChanged(on) }
        deck.onImport = { [weak self] in self?.importProfile() }
        deck.onRowAction = { [weak self] action, id in self?.performRowAction(action, id: id) }
    }

    func performRowAction(_ action: MacDeckRowAction, id: String) {
        guard let target = engine.state.userProfiles.first(where: { $0.id == id }) else { return }
        switch action {
        case .rename: promptRename(id)
        case .export: export(target)
        case .copy: copyAsText(target)
        case .delete: confirmDelete(id)
        }
    }

    func hoverPreviewChanged(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.hoverPreviewKey)
        deck.setHoverPreview(on)
        if !on { endAudition() }
    }

    /// The pointer or keyboard focus has come to a preset. While one is already
    /// playing as a preview the switch is at once, so a sweep down the list
    /// plays each in turn; otherwise the pointer has to rest a moment first.
    func deckPointed(at id: String) {
        guard hoverPreviewOn else { return }
        auditionGeneration += 1
        if auditionID != nil {
            beginAudition(id)
            return
        }
        let generation = auditionGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.dwellSeconds) { [weak self] in
            guard let self, self.auditionGeneration == generation else { return }
            self.beginAudition(id)
        }
    }

    /// The pointer left a preset. The preview ends after a short grace unless
    /// it reaches another preset first.
    func deckLeft() {
        auditionGeneration += 1
        let generation = auditionGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.leaveGraceSeconds) { [weak self] in
            guard let self, self.auditionGeneration == generation else { return }
            self.endAudition()
        }
    }

    /// VoiceOver cannot hover, so its Audition action plays a preset for a few seconds.
    func auditionBriefly(_ id: String) {
        beginAudition(id)
        let generation = auditionGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.spokenAuditionSeconds) { [weak self] in
            guard let self, self.auditionGeneration == generation else { return }
            self.endAudition()
        }
    }

    func beginAudition(_ id: String) {
        guard auditionID != id, let candidate = engine.allProfiles.first(where: { $0.id == id }) else { return }
        engine.beginAudition(candidate)
        auditionID = id
        curveView.setPreview(candidate.resolvedBands())
        deck.setHearing(id)
        previewPill.show(EqualizerCopy.name(of: candidate))
        installEscapeMonitor()
    }

    func endAudition() {
        auditionGeneration += 1
        guard auditionID != nil else { return }
        auditionID = nil
        engine.endAudition()
        curveView.setPreview(nil)
        deck.setHearing(nil)
        previewPill.show(nil)
        removeEscapeMonitor()
    }

    func cancelAudition() {
        endAudition()
        view.window?.makeFirstResponder(curveView)
    }

    func endAuditionIfPresetVanished() {
        guard let id = auditionID, !engine.allProfiles.contains(where: { $0.id == id }) else { return }
        endAudition()
    }

    func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, self?.view.window === event.window, self?.auditionID != nil else { return event }
            self?.cancelAudition()
            return nil
        }
    }

    func removeEscapeMonitor() {
        guard let monitor = escapeMonitor else { return }
        NSEvent.removeMonitor(monitor)
        escapeMonitor = nil
    }

    func observeWindowForAudition() {
        guard let window = view.window, window !== observedWindow else { return }
        let center = NotificationCenter.default
        if let previous = observedWindow {
            center.removeObserver(self, name: NSWindow.didResignKeyNotification, object: previous)
            center.removeObserver(self, name: NSWindow.willCloseNotification, object: previous)
        }
        observedWindow = window
        center.addObserver(self, selector: #selector(windowStoppedListening), name: NSWindow.didResignKeyNotification, object: window)
        center.addObserver(self, selector: #selector(windowStoppedListening), name: NSWindow.willCloseNotification, object: window)
    }

    @objc func windowStoppedListening() {
        endAudition()
    }

#if DEBUG
    /// Starts an audition without a pointer, for the debug screenshot.
    func auditionForCapture(profileID: String) {
        beginAudition(profileID)
        deck.reveal(profileID)
    }

    /// The preset being auditioned, for the debug exercise.
    var auditionedPresetID: String? { auditionID }

    /// Whether the curve is drawing a previewed line, for the debug exercise.
    var curveIsPreviewing: Bool { curveView.isPreviewing }

    /// Runs the deck's own pointer callbacks as a hovering pointer would.
    func exercisePointer(at id: String?) {
        if let id { deckPointed(at: id) } else { deckLeft() }
    }

    /// Runs the deck's click callback.
    func exerciseKeep(_ id: String) {
        keepPreset(id)
    }
#endif
}
