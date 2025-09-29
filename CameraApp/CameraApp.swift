import SwiftUI
import AVFoundation
import Photos

@main
struct CameraApp: App {
    var body: some Scene {
        WindowGroup {
            CameraScreen()
                .preferredColorScheme(.dark)
        }
    }
}

// MARK: - UI
struct CameraScreen: View {
    @StateObject private var camera = CameraManager()
    @State private var showSavedBanner = false
    @State private var lastError: String? = nil

    var body: some View {
        ZStack {
            CameraPreview(session: camera.session)
                .ignoresSafeArea()
                .onAppear { camera.startSession() }
                .onDisappear { camera.stopSession() }

            VStack {
                HStack {
                    Spacer()
                    Button(action: { camera.switchCamera() }) {
                        Image(systemName: "arrow.triangle.2.circlepath.camera")
                            .font(.system(size: 22, weight: .semibold))
                            .padding(12)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .padding()
                }
                Spacer()
                HStack(spacing: 28) {
                    Button(action: { camera.toggleFlashMode() }) {
                        Image(systemName: camera.flashMode == .off ? "bolt.slash.fill" : (camera.flashMode == .on ? "bolt.fill" : "bolt.badge.a.fill"))
                            .font(.system(size: 20, weight: .bold))
                            .padding(14)
                            .background(.ultraThinMaterial, in: Circle())
                    }

                    Button(action: capture) {
                        Circle()
                            .strokeBorder(.white, lineWidth: 4)
                            .frame(width: 74, height: 74)
                            .overlay(Circle().fill(.white).frame(width: 62, height: 62))
                            .shadow(radius: 4)
                    }

                    Button(action: { camera.cycleAspectRatio() }) {
                        Image(systemName: camera.aspectRatio.icon)
                            .font(.system(size: 20, weight: .bold))
                            .padding(14)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                }
                .padding(.bottom, 22)
            }

            if showSavedBanner {
                Text("Снимок сохранён")
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 60)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .onReceive(camera.$didSavePhoto) { saved in
            if saved { showSavedBanner = true; DispatchQueue.main.asyncAfter(deadline: .now()+1.2) { showSavedBanner = false } }
        }
        .onReceive(camera.$lastErrorMessage) { msg in
            if let msg = msg { lastError = msg }
        }
        .alert("Ошибка", isPresented: .constant(lastError != nil)) {
            Button("ОК", role: .cancel) { lastError = nil }
        } message: { Text(lastError ?? "") }
    }

    private func capture() {
        camera.capturePhoto { result in
            if case .failure(let err) = result { lastError = err.localizedDescription }
        }
    }
}

// MARK: - Aspect Ratio Helper
enum CameraAspectRatio: CaseIterable {
    case full, square, ratio4x3
    var icon: String {
        switch self {
        case .full: return "rectangle.portrait"
        case .square: return "square"
        case .ratio4x3: return "rectangle"
        }
    }
}

// MARK: - Preview Layer
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> UIView { PreviewView(session: session) }
    func updateUIView(_ uiView: UIView, context: Context) {}

    private final class PreviewView: UIView {
        private let previewLayer = AVCaptureVideoPreviewLayer()
        init(session: AVCaptureSession) {
            super.init(frame: .zero)
            previewLayer.session = session
            previewLayer.videoGravity = .resizeAspectFill
            layer.addSublayer(previewLayer)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func layoutSubviews() { super.layoutSubviews(); previewLayer.frame = bounds }
    }
}

// MARK: - Camera Manager
final class CameraManager: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    let session = AVCaptureSession()
    @Published var flashMode: AVCaptureDevice.FlashMode = .off
    @Published var didSavePhoto: Bool = false
    @Published var lastErrorMessage: String? = nil
    @Published var aspectRatio: CameraAspectRatio = .full
    private let sessionQueue = DispatchQueue(label: "camera.session.queue")
    private let photoOutput = AVCapturePhotoOutput()
    private var currentDevice: AVCaptureDevice?
    private var currentInput: AVCaptureDeviceInput?
    private var baseZoom: CGFloat = 1

    override init() {
        super.init()
        configureSession()
    }
    func startSession() { sessionQueue.async { if !self.session.isRunning { self.session.startRunning() } } }
    func stopSession() { sessionQueue.async { if self.session.isRunning { self.session.stopRunning() } } }
    func cycleAspectRatio() {}
    func switchCamera() {
        sessionQueue.async {
            let desired: AVCaptureDevice.Position = (self.currentDevice?.position == .back) ? .front : .back
            guard let newDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: desired) else { return }
            do {
                let newInput = try AVCaptureDeviceInput(device: newDevice)
                self.session.beginConfiguration()
                if let old = self.currentInput { self.session.removeInput(old) }
                if self.session.canAddInput(newInput) { self.session.addInput(newInput); self.currentInput = newInput; self.currentDevice = newDevice }
                self.session.commitConfiguration()
            } catch { self.publishError(error.localizedDescription) }
        }
    }
    func toggleFlashMode() { flashMode = (flashMode == .off ? .on : (flashMode == .on ? .auto : .off)) }
    func pinchToZoom(scale: CGFloat) {
        guard let device = currentDevice else { return }
        let maxZoom = min(device.activeFormat.videoMaxZoomFactor, 10)
        let newZoom = max(1.0, min(baseZoom * scale, maxZoom))
        do { try device.lockForConfiguration(); device.videoZoomFactor = newZoom; device.unlockForConfiguration() } catch { publishError(error.localizedDescription) }
    }
    func pinchEnd() { baseZoom = currentDevice?.videoZoomFactor ?? 1 }
    func capturePhoto(completion: @escaping (Result<Void, Error>) -> Void) {
        requestPermissionsIfNeeded { granted in
            guard granted else { self.publishError("Нет доступа к Камере/Фото"); completion(.failure(NSError(domain: "perm", code: 1))); return }
            let settings = AVCapturePhotoSettings()
            if self.photoOutput.supportedFlashModes.contains(self.flashMode) { settings.flashMode = self.flashMode }
            self.photoOutput.capturePhoto(with: settings, delegate: self)
            self.captureCompletion = completion
        }
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error = error { DispatchQueue.main.async { self.captureCompletion?(.failure(error)) }; return }
        guard let data = photo.fileDataRepresentation() else { DispatchQueue.main.async { self.captureCompletion?(.failure(NSError(domain: "photo", code: -1))) }; return }
        saveToPhotos(imageData: data)
    }
    private var captureCompletion: ((Result<Void, Error>) -> Void)?
    private func saveToPhotos(imageData: Data) {
        PHPhotoLibrary.shared().performChanges({
            let req = PHAssetCreationRequest.forAsset()
            req.addResource(with: .photo, data: imageData, options: nil)
        }) { success, error in
            DispatchQueue.main.async {
                if let error = error { self.publishError(error.localizedDescription); self.captureCompletion?(.failure(error)) }
                else { self.didSavePhoto = true; self.captureCompletion?(.success(())) }
                self.captureCompletion = nil
            }
        }
    }
    private func configureSession() {
        sessionQueue.async {
            self.session.beginConfiguration()
            self.session.sessionPreset = .photo
            defer { self.session.commitConfiguration() }
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else { self.publishError("Камера недоступна"); return }
            self.currentDevice = device
            do {
                let input = try AVCaptureDeviceInput(device: device)
                if self.session.canAddInput(input) { self.session.addInput(input); self.currentInput = input }
            } catch { self.publishError(error.localizedDescription) }
            self.photoOutput.isHighResolutionCaptureEnabled = true
            if self.session.canAddOutput(self.photoOutput) { self.session.addOutput(self.photoOutput) }
        }
    }
    private func publishError(_ message: String) { DispatchQueue.main.async { self.lastErrorMessage = message } }
    private func requestPermissionsIfNeeded(_ cb: @escaping (Bool) -> Void) {
        func checkPhotos(_ ok: Bool) {
            if !ok { cb(false); return }
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                DispatchQueue.main.async { cb(status == .authorized || status == .limited) }
            }
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: checkPhotos(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { checkPhotos(granted) }
            }
        default: cb(false)
        }
    }
    private func publishError(_ message: String) { DispatchQueue.main.async { self.lastErrorMessage = message } }
}
