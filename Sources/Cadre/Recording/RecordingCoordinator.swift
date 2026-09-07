import AppKit
import ScreenCaptureKit

/// Kaydın baştan sona akışı: alan seç, kaydet, durdur, dosyayı teslim et.
@MainActor
final class RecordingCoordinator {

    static let shared = RecordingCoordinator()

    private let recorder = ScreenRecorder()
    private var hud: RecordingHUD?
    private var starting = false

    private init() {}

    var isRecording: Bool { recorder.isRecording }

    func toggle() {
        if recorder.isRecording {
            Task { await stop() }
        } else {
            start()
        }
    }

    private func start() {
        guard !starting else { return }
        starting = true

        Task { @MainActor in
            let overlay = SelectionOverlayController(mode: .area)
            await overlay.present { [weak self] result, _ in
                guard let self else { return }
                Task { @MainActor in
                    self.starting = false
                    guard case .rect(let rect) = result else { return }
                    await self.beginRecording(in: rect)
                }
            }
        }
    }

    /// Alan zaten seçilmişse doğrudan kayda geç.
    func start(in rect: CGRect) async {
        guard !recorder.isRecording else { return }
        await beginRecording(in: rect)
    }

    private func beginRecording(in rect: CGRect) async {
        do {
            guard let screen = CoordinateSpace.screen(containing: rect) else { return }
            let displays = try await CaptureEngine.displays()
            let wanted = CoordinateSpace.displayID(of: screen)
            guard let display = displays.first(where: { $0.displayID == wanted }) ?? displays.first
            else { return }

            let local = CoordinateSpace.displayRect(fromCocoaRect: rect, on: screen)
            recorder.onFailure = { error in
                Task { @MainActor in
                    Notifier.show(error: error)
                    await self.stop()
                }
            }
            try await recorder.start(
                display: display,
                region: local,
                scale: screen.backingScaleFactor
            )

            await startRecordingAids()
            AppDelegateBridge.status?.setRecording(true)
            hud = RecordingHUD(near: rect) { [weak self] in
                Task { @MainActor in await self?.stop() }
            }
            Notifier.playShutter()
        } catch {
            Notifier.show(error: error)
        }
    }

    /// Kayıt sırasında ekranda duran yardımcılar. Hepsi ekranda göründüğü için
    /// ScreenCaptureKit onları videoya alır; ayrı bir birleştirme adımı yoktur.
    private func startRecordingAids() async {
        let settings = Settings.shared

        if settings.showsClicks { ClickIndicator.shared.start() }

        if settings.showsKeystrokes, !KeystrokeIndicator.shared.start() {
            Notifier.show(
                "Keystroke display is off",
                detail: "System Settings → Privacy & Security → Accessibility",
                isError: true
            )
            KeystrokeIndicator.requestPermission()
        }

        if settings.showsCamera, await !CameraOverlay.shared.start() {
            Notifier.show("Camera permission denied.", isError: true)
        }

        DoNotDisturb.setEnabled(true)
    }

    private func stopRecordingAids() {
        ClickIndicator.shared.stop()
        KeystrokeIndicator.shared.stop()
        CameraOverlay.shared.stop()
        DoNotDisturb.setEnabled(false)
    }

    private func stop() async {
        stopRecordingAids()
        hud?.close()
        hud = nil
        AppDelegateBridge.status?.setRecording(false)

        guard let temporaryURL = await recorder.stop() else {
            Notifier.show("The recording came out empty.", isError: true)
            return
        }

        let directory = Settings.shared.saveDirectory
        let target = uniqueURL(in: directory, name: temporaryURL.lastPathComponent)
        do {
            try FileManager.default.moveItem(at: temporaryURL, to: target)
            Notifier.playShutter()
            let poster = await VideoPoster.firstFrame(of: target)
            let size = await VideoPoster.size(of: target)
            if Settings.shared.keepHistory {
                History.shared.addRecording(videoURL: target, poster: poster, size: size)
            }
            RecordingResultOverlay.present(videoURL: target)
        } catch {
            Notifier.show(error: error)
        }
    }

    private func uniqueURL(in directory: URL, name: String) -> URL {
        var url = directory.appendingPathComponent(name)
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(base) (\(counter)).\(ext)")
            counter += 1
        }
        return url
    }
}

/// Menü çubuğu denetleyicisine kayıt durumunu bildirmek için tek geçit.
@MainActor
enum AppDelegateBridge {
    static var status: StatusItemController?
}

/// Kayıt sürerken ekranda duran küçük denetim: geçen süre ve durdurma düğmesi.
@MainActor
final class RecordingHUD {

    private var window: NSWindow?
    private var timer: Timer?
    private let startedAt = Date()
    private let label = NSTextField(labelWithString: "0:00")

    init(near rect: CGRect, onStop: @escaping () -> Void) {
        let stop = NSButton(
            image: NSImage(systemSymbolName: "stop.fill", accessibilityDescription: "Stop")!,
            target: nil, action: nil
        )
        stop.bezelStyle = .circular
        stop.contentTintColor = .systemRed
        stop.onAction = onStop

        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white

        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 4
        dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 8).isActive = true

        let stack = NSStackView(views: [dot, label, stop])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 8)

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])

        let size = background.fittingSize
        let screen = CoordinateSpace.screen(containing: rect) ?? NSScreen.main
        let origin = CGPoint(
            x: rect.midX - size.width / 2,
            y: max((screen?.visibleFrame.minY ?? 0) + 16, rect.minY - size.height - 14)
        )

        let window = NSWindow(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = background
        window.level = .statusBar
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        window.orderFrontRegardless()
        self.window = window

        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        let elapsed = Int(Date().timeIntervalSince(startedAt))
        label.stringValue = String(format: "%d:%02d", elapsed / 60, elapsed % 60)
    }

    func close() {
        timer?.invalidate()
        timer = nil
        window?.orderOut(nil)
        window = nil
    }
}

/// Kayıt bittiğinde çıkan seçenekler: klasörde göster, oynat, GIF'e çevir.
@MainActor
enum RecordingResultOverlay {
    static func present(videoURL: URL) {
        let alert = NSAlert()
        alert.messageText = "Recording finished"
        alert.informativeText = videoURL.lastPathComponent
        alert.addButton(withTitle: "Edit")
        alert.addButton(withTitle: "Convert to GIF")
        alert.addButton(withTitle: "Show in Finder")
        alert.addButton(withTitle: "Close")

        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            VideoTrimWindow.open(videoURL: videoURL)
        case .alertThirdButtonReturn:
            NSWorkspace.shared.activateFileViewerSelecting([videoURL])
        case .alertSecondButtonReturn:
            Notifier.show("Preparing the GIF…")
            Task {
                do {
                    let gif = try await GIFEncoder.convert(
                        videoURL: videoURL,
                        frameRate: Settings.shared.gifFrameRate
                    )
                    let target = Settings.shared.saveDirectory
                        .appendingPathComponent(gif.lastPathComponent)
                    try? FileManager.default.removeItem(at: target)
                    try FileManager.default.moveItem(at: gif, to: target)
                    Notifier.show("GIF ready", detail: target.lastPathComponent)
                    NSWorkspace.shared.activateFileViewerSelecting([target])
                } catch {
                    Notifier.show(error: error)
                }
            }
        default:
            break
        }
    }
}

/// NSButton'a kapanış bağlamak için küçük yardımcı; her düğmeye ayrı hedef sınıf gerekmesin.
extension NSButton {
    private static var actionKey: UInt8 = 0

    var onAction: (() -> Void)? {
        get { objc_getAssociatedObject(self, &NSButton.actionKey) as? () -> Void }
        set {
            objc_setAssociatedObject(self, &NSButton.actionKey, newValue, .OBJC_ASSOCIATION_RETAIN)
            target = self
            action = #selector(runStoredAction)
        }
    }

    @objc private func runStoredAction() { onAction?() }
}
