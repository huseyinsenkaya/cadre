import AppKit
import AVFoundation

/// Kayıt sırasında kamerayı ekranın köşesinde gösterir.
///
/// Pencere ekranda durduğu için ScreenCaptureKit onu videoya alır. Ayrı bir
/// birleştirme adımı gerekmez. Taşınabilir ve yeniden boyutlandırılabilir.
@MainActor
final class CameraOverlay {

    static let shared = CameraOverlay()

    private var session: AVCaptureSession?
    private var window: NSWindow?

    private init() {}

    var isRunning: Bool { window != nil }

    /// Kamera izni yoksa `false` döner. Çağıran kullanıcıyı bilgilendirir.
    @discardableResult
    func start() async -> Bool {
        guard window == nil else { return true }

        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .notDetermined {
            guard await AVCaptureDevice.requestAccess(for: .video) else { return false }
        } else if status != .authorized {
            return false
        }

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device)
        else { return false }

        let session = AVCaptureSession()
        session.sessionPreset = .high
        guard session.canAddInput(input) else { return false }
        session.addInput(input)

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill

        let side = CGFloat(max(120, Settings.shared.cameraSize))
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let frame = NSRect(
            x: screen.visibleFrame.maxX - side - 32,
            y: screen.visibleFrame.minY + 32,
            width: side,
            height: side
        )

        let host = CameraHostView(frame: NSRect(origin: .zero, size: frame.size))
        host.wantsLayer = true
        host.layer?.cornerRadius = side / 2
        host.layer?.masksToBounds = true
        host.layer?.borderWidth = 3
        host.layer?.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        preview.frame = host.bounds
        preview.cornerRadius = side / 2
        host.layer?.addSublayer(preview)
        host.previewLayer = preview

        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.aspectRatio = NSSize(width: 1, height: 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.orderFrontRegardless()

        // Oturumu ana iş parçacığında başlatmak arayüzü durdurur.
        Task.detached { session.startRunning() }

        self.session = session
        self.window = window
        return true
    }

    func stop() {
        session?.stopRunning()
        session = nil
        window?.orderOut(nil)
        window = nil
    }
}

/// Kamera katmanı pencereyle birlikte büyüsün diye yeniden boyutlanmayı izler.
private final class CameraHostView: NSView {
    var previewLayer: AVCaptureVideoPreviewLayer?

    override func layout() {
        super.layout()
        previewLayer?.frame = bounds
        let radius = min(bounds.width, bounds.height) / 2
        previewLayer?.cornerRadius = radius
        layer?.cornerRadius = radius
    }
}
