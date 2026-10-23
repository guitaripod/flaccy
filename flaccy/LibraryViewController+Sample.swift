import Combine
import MidgarCore
import FlaccyCore
import UIKit
import UniformTypeIdentifiers

extension LibraryViewController {

    #if DEBUG
    func driveSampleFlowIfRequested() {
        guard let step = SampleDebugHooks.drive else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            switch step {
            case "guide": self?.presentComputerTransferGuide()
            case "sample": self?.sampleMusicTapped()
            case "sample-retry":
                self?.sampleMusicTapped()
                try? await Task.sleep(for: .seconds(SampleDebugHooks.retryDelay))
                self?.sampleMusicTapped()
            default: break
            }
        }
    }
    #endif

    func presentComputerTransferGuide() {
        impactLight.impactOccurred()
        let guide = UINavigationController(rootViewController: ComputerTransferGuideViewController())
        guide.modalPresentationStyle = .pageSheet
        guide.sheetPresentationController?.detents = [.medium(), .large()]
        guide.sheetPresentationController?.prefersGrabberVisible = true
        present(guide, animated: true)
    }

    /// The button is the one place the sample's state lives: idle states the
    /// size up front, a running download shows its progress, and an
    /// interrupted one offers to continue rather than silently starting over.
    func applySampleButtonState() {
        let service = SampleMusicService.shared
        var config = sampleMusicButton.configuration
        config?.showsActivityIndicator = service.isDownloading
        sampleMusicButton.isEnabled = !service.isDownloading
        if service.isDownloading {
            config?.title = service.progressText.isEmpty ? String(localized: "Downloading…") : service.progressText
            config?.subtitle = String(localized: "About 130 MB of 24-bit FLAC")
            config?.image = UIImage(systemName: "arrow.down.circle")
        } else {
            switch service.interruption {
            case .resumable:
                config?.title = String(localized: "Resume Download")
                config?.subtitle = String(localized: "Interrupted — picks up where it stopped")
                config?.image = UIImage(systemName: "arrow.clockwise.circle")
            case .unreachable:
                config?.title = String(localized: "Try Again")
                config?.subtitle = String(localized: "Couldn't reach the sample music server — check your connection")
                config?.image = UIImage(systemName: "arrow.clockwise.circle")
            case nil:
                config?.title = String(localized: "Add Sample Music")
                config?.subtitle = String(localized: "Bach, lossless, free · 130 MB")
                config?.image = UIImage(systemName: "arrow.down.circle")
            }
        }
        sampleMusicButton.configuration = config
    }

    func sampleMusicTapped() {
        guard !SampleMusicService.shared.isDownloading else { return }
        impactLight.impactOccurred()
        Task { [weak self] in
            let confirmation = await SampleDownloadPolicy.currentConfirmation()
            guard let self, !SampleMusicService.shared.isDownloading else { return }
            guard let confirmation else {
                self.downloadSampleMusic()
                return
            }
            MidgarLog.info("Sample download asks first: \(confirmation)", category: .content)
            self.presentSampleConfirmation(confirmation)
        }
    }

    func presentSampleConfirmation(_ confirmation: SampleDownloadPolicy.Confirmation) {
        let alert = UIAlertController(
            title: sampleConfirmationTitle(confirmation),
            message: sampleConfirmationMessage(confirmation),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "Not Now"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Download"), style: .default) { [weak self] _ in
            self?.downloadSampleMusic()
        })
        present(alert, animated: true)
    }

    func sampleConfirmationTitle(_ confirmation: SampleDownloadPolicy.Confirmation) -> String {
        switch confirmation {
        case .cellular: String(localized: "Download over cellular?")
        case .lowDataMode: String(localized: "Download in Low Data Mode?")
        }
    }

    func sampleConfirmationMessage(_ confirmation: SampleDownloadPolicy.Confirmation) -> String {
        switch confirmation {
        case .cellular: String(localized: "The sample album is about 130 MB and this connection may be metered. Wi-Fi is the better way to get it.")
        case .lowDataMode: String(localized: "The sample album is about 130 MB, and Low Data Mode asks apps to use less data.")
        }
    }

    func downloadSampleMusic() {
        guard !SampleMusicService.shared.isDownloading else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        let progressObserver = NotificationCenter.default.addObserver(
            forName: SampleMusicService.progressDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applySampleButtonState() }
        }

        Task { [weak self] in
            let success = await SampleMusicService.shared.downloadSamples()
            NotificationCenter.default.removeObserver(progressObserver)
            guard let self else { return }
            self.applySampleButtonState()
            if success {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                ToastView.show(String(localized: "Sample album added — Open Goldberg Variations (CC0)"), in: self.view, style: .success)
            } else {
                self.reportSampleFailure()
            }
        }
    }

    /// With the empty library still showing, the button itself became Retry;
    /// once the first songs landed the empty state is gone, so the failure
    /// carries its own Retry instead of leaving the album half there.
    func reportSampleFailure() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        if case .noLibrary = viewModel.emptyState {
            ToastView.show(String(localized: "Sample download failed — check your connection"), in: view, style: .error)
        } else {
            ToastView.showAction(
                String(localized: "Sample download interrupted"),
                actionTitle: String(localized: "Try Again"),
                in: view
            ) { [weak self] in
                self?.sampleMusicTapped()
            }
        }
    }
}
