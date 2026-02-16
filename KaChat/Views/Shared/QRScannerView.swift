import SwiftUI
import AVFoundation

/// A view that scans QR codes using the device camera
struct QRScannerView: View {
    @Environment(\.dismiss) private var dismiss
    let onScan: (String) -> Void

    @State private var isAuthorized = false
    @State private var showPermissionDenied = false

    var body: some View {
        NavigationStack {
            ZStack {
                if isAuthorized {
                    QRScannerRepresentable(onScan: handleScan)
                        .ignoresSafeArea()

                    // Scanning overlay
                    VStack {
                        Spacer()

                        // Scanning frame indicator
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white, lineWidth: 3)
                            .frame(width: 250, height: 250)
                            .background(Color.clear)

                        Spacer()

                        Text("Point camera at a QR code")
                            .font(.headline)
                            .foregroundColor(.white)
                            .padding()
                            .background(.ultraThinMaterial)
                            .cornerRadius(8)
                            .padding(.bottom, 50)
                    }
                } else if showPermissionDenied {
                    VStack(spacing: 20) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 60))
                            .foregroundColor(.secondary)

                        Text("Camera Access Required")
                            .font(.title2)
                            .fontWeight(.semibold)

                        Text("Please enable camera access in Settings to scan QR codes.")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)

                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding()
                } else {
                    ProgressView("Requesting camera access...")
                }
            }
            .navigationTitle("Scan QR Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
        .task {
            await checkCameraPermission()
        }
    }

    private func checkCameraPermission() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            isAuthorized = true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            await MainActor.run {
                isAuthorized = granted
                showPermissionDenied = !granted
            }
        case .denied, .restricted:
            await MainActor.run {
                showPermissionDenied = true
            }
        @unknown default:
            await MainActor.run {
                showPermissionDenied = true
            }
        }
    }

    private func handleScan(_ code: String) {
        // Provide haptic feedback
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)

        onScan(code)
        dismiss()
    }
}

// MARK: - UIKit Scanner Wrapper

private struct QRScannerRepresentable: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeUIViewController(context: Context) -> QRScannerViewController {
        let controller = QRScannerViewController()
        controller.onScan = onScan
        return controller
    }

    func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {}
}

private class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScan: ((String) -> Void)?

    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var hasScanned = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupCamera()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        startScanning()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopScanning()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    private func setupCamera() {
        let session = AVCaptureSession()

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else {
            return
        }

        if session.canAddInput(input) {
            session.addInput(input)
        }

        let output = AVCaptureMetadataOutput()
        if session.canAddOutput(output) {
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
        }

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)

        self.captureSession = session
        self.previewLayer = preview
    }

    private func startScanning() {
        hasScanned = false
        if let session = captureSession, !session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async {
                session.startRunning()
            }
        }
    }

    private func stopScanning() {
        if let session = captureSession, session.isRunning {
            session.stopRunning()
        }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard !hasScanned,
              let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let code = object.stringValue else {
            return
        }

        hasScanned = true
        stopScanning()
        onScan?(code)
    }
}

#Preview {
    QRScannerView { code in
        print("Scanned: \(code)")
    }
}
