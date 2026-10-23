import AppKit
import FlaccyCore
import UniformTypeIdentifiers

extension MacEqualizerViewController {

    @objc func showOutputMenu(_ sender: NSButton) {
        let menu = NSMenu()
        let output = engine.output
        let header = NSMenuItem(title: output?.name ?? String(localized: "Speaker"), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let remember = NSMenuItem(title: String(localized: "Remember for this Output"), action: #selector(toggleRemember), keyEquivalent: "")
        remember.target = self
        remember.state = engine.keepsOwnProfileForOutput ? .on : .off
        remember.isEnabled = output != nil
        menu.addItem(remember)

        let use = NSMenuItem(title: String(localized: "Use Profile"), action: nil, keyEquivalent: "")
        use.submenu = profileSubmenu(includeOff: true) { [weak self] choice in
            guard let self, let id = self.engine.outputID else { return }
            self.apply(choice, toOutput: id)
        }
        menu.addItem(use)

        let others = engine.rememberedOutputs.filter { $0.id != engine.outputID }
        if !others.isEmpty {
            menu.addItem(.separator())
            let title = NSMenuItem(title: String(localized: "Other Outputs"), action: nil, keyEquivalent: "")
            title.isEnabled = false
            menu.addItem(title)
            for other in others {
                let profileName = other.binding == EqualizerState.offBinding
                    ? String(localized: "Off · bit-perfect")
                    : (engine.state.profile(withID: other.binding).map { EqualizerCopy.name(of: $0) } ?? "")
                let item = NSMenuItem(title: "\(other.name) · \(profileName)", action: nil, keyEquivalent: "")
                item.submenu = profileSubmenu(includeOff: true, includeForget: true) { [weak self] choice in
                    self?.apply(choice, toOutput: other.id)
                }
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        let defaultItem = NSMenuItem(title: String(localized: "Other Outputs Use"), action: nil, keyEquivalent: "")
        defaultItem.submenu = profileSubmenu(includeOff: false) { [weak self] choice in
            if case .profile(let id) = choice { self?.engine.setDefaultProfile(id) }
        }
        menu.addItem(defaultItem)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    enum Choice {
        case off
        case profile(String)
        case forget
    }

    func profileSubmenu(includeOff: Bool, includeForget: Bool = false, handler: @escaping (Choice) -> Void) -> NSMenu {
        let menu = NSMenu()
        if includeOff {
            menu.addItem(MacClosureMenuItem(title: String(localized: "Off · bit-perfect")) { handler(.off) })
            menu.addItem(.separator())
        }
        for candidate in engine.state.userProfiles {
            menu.addItem(MacClosureMenuItem(title: candidate.name) { handler(.profile(candidate.id)) })
        }
        if !engine.state.userProfiles.isEmpty { menu.addItem(.separator()) }
        for candidate in EqualizerPresets.all {
            menu.addItem(MacClosureMenuItem(title: EqualizerCopy.name(of: candidate)) { handler(.profile(candidate.id)) })
        }
        if includeForget {
            menu.addItem(.separator())
            menu.addItem(MacClosureMenuItem(title: String(localized: "Forget this Output")) { handler(.forget) })
        }
        return menu
    }

    func apply(_ choice: Choice, toOutput id: String) {
        beginEditing()
        switch choice {
        case .off: engine.bindOutputToOff(id)
        case .profile(let profileID): engine.setBinding(profileID, forOutput: id)
        case .forget: engine.forgetOutput(id)
        }
        finishEditing()
    }

    @objc func toggleRemember() {
        beginEditing()
        engine.setRemembering(!engine.keepsOwnProfileForOutput)
        finishEditing()
    }
}
