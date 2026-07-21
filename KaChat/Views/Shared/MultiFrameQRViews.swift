import SwiftUI
import AVFoundation
import CoreImage
import UIKit

/// Cycles through a KasSigner-style animated multi-frame QR sequence (see QrFrameChunker) at a
/// fixed interval. A single-frame sequence just renders a static code with no play/pause
/// controls or frame counter. Matches KasSee's own 2.5s auto-advance (kassee/web/js/app.js's
/// displayKsptQr) — a scanning camera needs real time to lock onto and decode each frame.
struct AnimatedQRDisplayView: View {
    let frames: [Data]
    var frameDelaySeconds: Double = 2.5
    var displaySize: CGFloat = 240

    @State private var frameIndex = 0
    @State private var isPlaying = true
    @State private var frameImages: [UIImage?] = []

    var body: some View {
        VStack(spacing: 12) {
            Group {
                if let image = safeImage(at: frameIndex) {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: displaySize, height: displaySize)
                } else {
                    ProgressView()
                        .frame(width: displaySize, height: displaySize)
                }
            }
            .padding(20)
            .background(Color.white)
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.accentColor, lineWidth: 3)
            )
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

            if frames.count > 1 {
                HStack(spacing: 4) {
                    ForEach(frames.indices, id: \.self) { i in
                        Circle()
                            .fill(i == frameIndex ? Color.accentColor : Color(white: 0.82))
                            .frame(width: 8, height: 8)
                    }
                }
                HStack(spacing: 20) {
                    Button {
                        frameIndex = (frameIndex - 1 + frames.count) % frames.count
                    } label: {
                        Image(systemName: "backward.frame.fill")
                    }
                    Button {
                        isPlaying.toggle()
                    } label: {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    }
                    Button {
                        frameIndex = (frameIndex + 1) % frames.count
                    } label: {
                        Image(systemName: "forward.frame.fill")
                    }
                }
                .foregroundColor(.accentColor)
                Text("Frame \(frameIndex + 1) / \(frames.count)")
                    .font(.caption)
                    .foregroundColor(Color(white: 0.4))
            }
        }
        .onAppear { renderFrames() }
        .onChange(of: frames) { _ in
            frameIndex = 0
            renderFrames()
        }
        .task(id: isPlaying) {
            guard isPlaying, frames.count > 1 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(frameDelaySeconds * 1_000_000_000))
                if Task.isCancelled { return }
                frameIndex = (frameIndex + 1) % frames.count
            }
        }
    }

    private func safeImage(at index: Int) -> UIImage? {
        guard frameImages.indices.contains(index) else { return nil }
        return frameImages[index]
    }

    private func renderFrames() {
        frameImages = frames.map { try? ByteModeQRCode.generateImage(for: $0) }
    }
}

/// Scans a KasSigner animated multi-frame QR sequence (a signed KSPT response, or anything else
/// chunked with QrFrameChunker) and reassembles it. Unlike QRScannerView, which fires once on the
/// first decode, this keeps scanning until every frame has been seen.
struct MultiFrameQRScannerView: View {
    let isComplete: (Data) -> Bool
    let onComplete: (Data) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isAuthorized = false
    @State private var showPermissionDenied = false
    @State private var progress: (received: Int, total: Int)?
    @State private var receivedIndices: Set<Int> = []
    @State private var done = false

    private let accumulator: QrFrameChunker.Accumulator

    init(isComplete: @escaping (Data) -> Bool, onComplete: @escaping (Data) -> Void) {
        self.isComplete = isComplete
        self.onComplete = onComplete
        self.accumulator = QrFrameChunker.Accumulator(isComplete: isComplete)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                if isAuthorized {
                    MultiFrameScannerRepresentable { data in
                        guard !done else { return }
                        guard let complete = accumulator.addFrame(data) else {
                            progress = accumulator.progress
                            receivedIndices = accumulator.receivedFrameIndices
                            return
                        }
                        done = true
                        onComplete(complete)
                        dismiss()
                    }
                    .ignoresSafeArea()

                    VStack {
                        Spacer()
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white, lineWidth: 3)
                            .frame(width: 250, height: 250)
                        Spacer()

                        if let progress, progress.total > 0 {
                            HStack(spacing: 4) {
                                ForEach(0..<progress.total, id: \.self) { i in
                                    Circle()
                                        .fill(receivedIndices.contains(i) ? Color.accentColor : Color.white.opacity(0.4))
                                        .frame(width: 8, height: 8)
                                }
                            }
                            .padding(.bottom, 8)
                            Text("\(progress.received) / \(progress.total) frames")
                                .font(.headline)
                                .foregroundColor(.white)
                                .padding()
                                .background(.ultraThinMaterial)
                                .cornerRadius(8)
                                .padding(.bottom, 50)
                        } else {
                            Text("Point camera at the KasSigner screen")
                                .font(.headline)
                                .foregroundColor(.white)
                                .padding()
                                .background(.ultraThinMaterial)
                                .cornerRadius(8)
                                .padding(.bottom, 50)
                        }
                    }
                } else if showPermissionDenied {
                    VStack(spacing: 20) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 60))
                            .foregroundColor(.secondary)
                        Text("Camera Access Required")
                            .font(.title2)
                            .fontWeight(.semibold)
                        Text("Please enable camera access in Settings to scan the signed transaction.")
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
            .navigationTitle("Scan Signed Transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
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
            await MainActor.run { showPermissionDenied = true }
        @unknown default:
            await MainActor.run { showPermissionDenied = true }
        }
    }
}

// MARK: - UIKit camera plumbing

private struct MultiFrameScannerRepresentable: UIViewControllerRepresentable {
    let onFrame: (Data) -> Void

    func makeUIViewController(context: Context) -> MultiFrameScannerViewController {
        let controller = MultiFrameScannerViewController()
        controller.onFrame = onFrame
        return controller
    }

    func updateUIViewController(_ uiViewController: MultiFrameScannerViewController, context: Context) {}
}

/// Same camera setup as QRScannerView's internal controller, except it keeps decoding every
/// frame (not just the first) and hands off the QR's raw byte-mode payload — via
/// AVMetadataMachineReadableCodeObject.descriptor, not .stringValue, since .stringValue silently
/// truncates/corrupts binary payloads with embedded 0x00 bytes (verified before this shipped).
private class MultiFrameScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onFrame: ((Data) -> Void)?

    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var lastEmitTime: Date = .distantPast

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
        guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let descriptor = object.descriptor as? CIQRCodeDescriptor else {
            return
        }
        // Throttle: the same still frame gets redetected every camera tick while the physical
        // display hasn't advanced yet — feeding it repeatedly is harmless (Accumulator dedupes
        // by frame index) but wastes CPU on redundant bit-parses.
        let now = Date()
        guard now.timeIntervalSince(lastEmitTime) > 0.15 else { return }
        lastEmitTime = now

        guard let payload = try? ByteModeQRCode.extractPayload(
            errorCorrectedPayload: descriptor.errorCorrectedPayload,
            symbolVersion: descriptor.symbolVersion
        ) else { return }

        onFrame?(payload)
    }
}
