@preconcurrency import AVFoundation
import FlaccyCore
import MidgarCore
import UIKit

/// Reads the QR code a Flaccy Server prints for a new device and hands back its link.
final class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {

    private let onLink: (ServerLink) -> Void
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "cc.midgarcorp.flaccy.qr-scanner")
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private let hintLabel = UILabel()
    private let haptics = UINotificationFeedbackGenerator()
    private var hasDeliveredLink = false

    init(onLink: @escaping (ServerLink) -> Void) {
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
        hintLabel.text = String(localized: "Point the camera at the QR code your Flaccy Server printed.")
        hintLabel.accessibilityIdentifier = "qrScanner.hint"
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hintLabel)
        NSLayoutConstraint.activate([
            hintLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            hintLabel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            hintLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -32),
        ])
        requestAccessThenStart()
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

    private func requestAccessThenStart() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted { self?.configureSession() } else { self?.showDenied() }
                }
            }
        default:
            showDenied()
        }
    }

    private func showDenied() {
        hintLabel.text = String(localized: "Flaccy can\u{2019}t use the camera. Allow it in Settings, or type the server\u{2019}s address and key instead.")
        haptics.notificationOccurred(.warning)
    }

    private func configureSession() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input)
        else {
            hintLabel.text = String(localized: "This device has no camera to scan with. Type the server\u{2019}s address and key instead.")
            return
        }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.insertSublayer(preview, at: 0)
        previewLayer = preview
        let session = session
        sessionQueue.async { session.startRunning() }
    }

    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection
    ) {
        let payloads = metadataObjects.compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }
        MainActor.assumeIsolated {
            guard !hasDeliveredLink, let payload = payloads.first else { return }
            if let link = ServerLink(text: payload) {
                hasDeliveredLink = true
                onLink(link)
            } else {
                hintLabel.text = String(localized: "That code isn\u{2019}t a Flaccy Server link. Scan the QR code printed by flaccy-server key add --url.")
                haptics.notificationOccurred(.warning)
            }
        }
    }
}
