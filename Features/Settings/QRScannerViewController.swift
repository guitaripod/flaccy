@preconcurrency import AVFoundation
import FlaccyCore
import MidgarCore
import UIKit

/// Reads the QR code a Flaccy Server prints for a new device and hands back its link, whichever kind it is.
///
/// The camera starts once the scanner is on screen and keeps running while Flaccy shares the screen with other apps on an iPad
/// that allows it. Where the iPad does not, or another app takes the camera, the hint says why the picture stopped and what to do.
final class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {

    private let onLink: (ParsedServerLink) -> Void
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "cc.midgarcorp.flaccy.qr-scanner")
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private var sessionObservers: [any NSObjectProtocol] = []
    private var isConfigured = false
    private let hintLabel = UILabel()
    private lazy var settingsButton = UIButton(configuration: .filled(), primaryAction: UIAction { [weak self] _ in
        self?.openSettings()
    })
    private let haptics = UINotificationFeedbackGenerator()
    private var hasDeliveredLink = false

    init(onLink: @escaping (ParsedServerLink) -> Void) {
        self.onLink = onLink
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Scan QR Code")
        view.backgroundColor = .black
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .cancel,
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) }
        )
        hintLabel.font = .preferredFont(forTextStyle: .callout)
        hintLabel.adjustsFontForContentSizeCategory = true
        hintLabel.textColor = .white
        hintLabel.numberOfLines = 0
        hintLabel.textAlignment = .center
        hintLabel.text = Self.aimHint
        hintLabel.accessibilityIdentifier = "qrScanner.hint"
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hintLabel)
        settingsButton.configuration?.title = String(localized: "Open Settings")
        settingsButton.isHidden = true
        settingsButton.accessibilityIdentifier = "qrScanner.openSettings"
        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(settingsButton)
        NSLayoutConstraint.activate([
            hintLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            hintLabel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            hintLabel.bottomAnchor.constraint(equalTo: settingsButton.topAnchor, constant: -16),
            settingsButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            settingsButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -32),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        observeSession()
        startCamera()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        let session = session
        sessionQueue.async { if session.isRunning { session.stopRunning() } }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        sessionObservers.forEach { NotificationCenter.default.removeObserver($0) }
        sessionObservers.removeAll()
    }

    private static var aimHint: String {
        String(localized: "Point at the code on your computer")
    }

    private func startCamera() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            guard configureSession() else { return }
            run()
        case .notDetermined:
            Task { [weak self] in
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                if granted { self?.startCamera() } else { self?.showDenied() }
            }
        default:
            showDenied()
        }
    }

    private func showDenied() {
        hintLabel.text = String(localized: "Flaccy can\u{2019}t use the camera. Allow it in Settings, or type the server\u{2019}s details instead.")
        settingsButton.isHidden = false
        haptics.notificationOccurred(.warning)
    }

    private func openSettings() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// Adds the camera and the QR reader once. An iPad that can share its camera with other apps on screen is asked to, so the
    /// scanner runs in a window, Split View or Stage Manager instead of showing black.
    private func configureSession() -> Bool {
        if isConfigured { return true }
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input)
        else {
            hintLabel.text = String(localized: "This device has no camera to scan with. Type the server\u{2019}s details instead.")
            return false
        }
        let output = AVCaptureMetadataOutput()
        session.beginConfiguration()
        session.addInput(input)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            hintLabel.text = String(localized: "This device has no camera to scan with. Type the server\u{2019}s details instead.")
            return false
        }
        session.addOutput(output)
        if session.isMultitaskingCameraAccessSupported {
            session.isMultitaskingCameraAccessEnabled = true
        }
        session.commitConfiguration()
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        attachPreview(for: device)
        isConfigured = true
        return true
    }

    private func attachPreview(for device: AVCaptureDevice) {
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.insertSublayer(preview, at: 0)
        previewLayer = preview
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: preview)
        rotationCoordinator = coordinator
        level(preview, at: coordinator.videoRotationAngleForHorizonLevelPreview)
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { [weak self] coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            Task { @MainActor in
                guard let self, let preview = self.previewLayer else { return }
                self.level(preview, at: angle)
            }
        }
    }

    /// Keeps the picture upright however the iPad is turned: the camera's own angle is portrait, which draws a landscape iPad's
    /// preview on its side.
    private func level(_ preview: AVCaptureVideoPreviewLayer, at angle: CGFloat) {
        guard let connection = preview.connection, connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
    }

    private func run() {
        let session = session
        sessionQueue.async { if !session.isRunning { session.startRunning() } }
    }

    private func observeSession() {
        guard sessionObservers.isEmpty else { return }
        let center = NotificationCenter.default
        sessionObservers = [
            center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: .main) { [weak self] notification in
                let reason = (notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int)
                    .flatMap(AVCaptureSession.InterruptionReason.init(rawValue:))
                MainActor.assumeIsolated { self?.cameraInterrupted(reason) }
            },
            center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cameraResumed() }
            },
            center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cameraFailed() }
            },
        ]
    }

    private func cameraInterrupted(_ reason: AVCaptureSession.InterruptionReason?) {
        MidgarLog.notice("QR scanner camera interrupted: \(reason.map { String($0.rawValue) } ?? "unknown")", category: .remote)
        hintLabel.text = reason == .videoDeviceNotAvailableWithMultipleForegroundApps
            ? String(localized: "The camera stops while Flaccy shares the screen with other apps. Make Flaccy full screen to scan, or type the server\u{2019}s details instead.")
            : String(localized: "Another app is using the camera. Close it, and the camera comes back here.")
        haptics.notificationOccurred(.warning)
    }

    private func cameraResumed() {
        hintLabel.text = Self.aimHint
    }

    private func cameraFailed() {
        MidgarLog.error("QR scanner camera stopped with a runtime error", category: .remote)
        guard isConfigured, viewIfLoaded?.window != nil else { return }
        run()
    }

    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection
    ) {
        let payloads = metadataObjects.compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }
        MainActor.assumeIsolated {
            guard !hasDeliveredLink, let payload = payloads.first else { return }
            if let link = ParsedServerLink(text: payload) {
                hasDeliveredLink = true
                onLink(link)
            } else {
                hintLabel.text = String(localized: "That isn\u{2019}t a Flaccy Server code. Scan the code from Add a Device on your Mac, or the one your server printed.")
                haptics.notificationOccurred(.warning)
            }
        }
    }
}
