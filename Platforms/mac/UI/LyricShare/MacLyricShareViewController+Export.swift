import AppKit
import FlaccyCore
import MidgarCore
import UniformTypeIdentifiers

extension MacLyricShareViewController {

    /// What happens to the finished file: the person saves it somewhere, or
    /// hands it to a sharing service.
    enum ExportDestination {
        case save
        case share
    }

    func buildBottomBar() -> NSView {
        saveImageButton.image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
        saveImageButton.imagePosition = .imageLeading
        saveImageButton.target = self
        saveImageButton.action = #selector(saveImageTapped)
        saveVideoButton.image = NSImage(systemSymbolName: "play.rectangle", accessibilityDescription: nil)
        saveVideoButton.imagePosition = .imageLeading
        saveVideoButton.target = self
        saveVideoButton.action = #selector(saveVideoTapped)
        shareButton.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)
        shareButton.imagePosition = .imageLeading
        shareButton.keyEquivalent = "\r"
        shareButton.target = self
        shareButton.action = #selector(shareTapped)
        for button in [saveImageButton, saveVideoButton, shareButton] {
            button.bezelStyle = .rounded
            button.controlSize = .large
        }
        exportActions.setViews([saveImageButton, saveVideoButton, shareButton], in: .leading)
        exportActions.orientation = .horizontal
        exportActions.spacing = 10

        progressLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressBar.widthAnchor.constraint(equalToConstant: 240).isActive = true
        cancelExportButton.bezelStyle = .rounded
        cancelExportButton.target = self
        cancelExportButton.action = #selector(cancelExportTapped)
        exportProgress.setViews([progressLabel, progressBar, cancelExportButton], in: .leading)
        exportProgress.orientation = .horizontal
        exportProgress.alignment = .centerY
        exportProgress.spacing = 12
        exportProgress.isHidden = true

        let bar = NSView()
        for subview in [exportProgress, exportActions] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            exportProgress.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 20),
            exportProgress.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            exportActions.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -20),
            exportActions.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
        return bar
    }

    @objc private func saveImageTapped() {
        export(video: false, destination: .save)
    }

    @objc private func saveVideoTapped() {
        export(video: true, destination: .save)
    }

    @objc private func shareTapped() {
        export(video: true, destination: .share)
    }

    @objc private func cancelExportTapped() {
        cancelFlag?.set()
    }

    private func setExporting(_ exporting: Bool) {
        exportActions.isHidden = exporting
        exportProgress.isHidden = !exporting
        progressBar.doubleValue = 0
        setControlsEnabled(!exporting)
        let hasAudio = session.audio != nil
        saveImageButton.isEnabled = !exporting
        saveVideoButton.isEnabled = !exporting && hasAudio
        shareButton.isEnabled = !exporting && hasAudio
    }

    func export(video: Bool, destination: ExportDestination) {
        guard cancelFlag == nil else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        preview.pause()
        updatePlayButton()
        let flag = LyricShareCancelFlag()
        cancelFlag = flag
        setExporting(video)
        Task { [weak self] in
            guard let self else { return }
            let result = await self.session.export(video: video, cancel: flag) { [weak self] value in
                self?.progressBar.doubleValue = value
            }
            self.cancelFlag = nil
            self.setExporting(false)
            switch result {
            case .success(let url):
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
                switch destination {
                case .save: self.promptSave(url, video: video)
                case .share: self.presentShare(url)
                }
            case .failure(.cancelled):
                break
            case .failure(let failure):
                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                MidgarLog.error("Lyric share export failed: \(failure)", category: .content)
                MacToast.show(LyricShareCopy.exportFailure(failure), style: .error, in: self.view.window)
            }
        }
    }

    private func presentShare(_ url: URL) {
        let picker = NSSharingServicePicker(items: [url])
        picker.show(relativeTo: shareButton.bounds, of: shareButton, preferredEdge: .maxY)
    }

    /// Asks where to keep the finished file, named after the song.
    private func promptSave(_ exported: URL, video: Bool) {
        guard let window = view.window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = exported.lastPathComponent
        panel.allowedContentTypes = [video ? .mpeg4Movie : .png]
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let destination = panel.url else { return }
            self?.save(exported, to: destination)
        }
    }

    private func save(_ exported: URL, to destination: URL) {
        let name = destination.lastPathComponent
        guard destination.standardizedFileURL != exported.standardizedFileURL else { return }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: exported, to: destination)
            MidgarLog.info("Lyric share saved to \(destination.path)", category: .content)
            MacToast.show(LyricShareCopy.saved(name), style: .success, in: view.window)
        } catch {
            MidgarLog.error("Lyric share save failed: \(error.localizedDescription)", category: .content)
            MacToast.show(
                LyricShareCopy.saveFailure(name, reason: error.localizedDescription), style: .error, in: view.window)
        }
    }
}
