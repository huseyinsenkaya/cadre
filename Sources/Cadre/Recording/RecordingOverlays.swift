import AppKit
import Carbon.HIToolbox

/// Kayıt sırasında fare tıklamalarını ekranda halka olarak gösterir.
///
/// Pencere fare olaylarını geçirir ve ekranda göründüğü için ScreenCaptureKit onu
/// videoya alır. Ayrı bir çizim katmanı gerekmez.
@MainActor
final class ClickIndicator {

    static let shared = ClickIndicator()

    private var monitor: Any?
    private let side: CGFloat = 96

    private init() {}

    var isRunning: Bool { monitor != nil }

    func start() {
        guard monitor == nil else { return }
        // Fare olaylarını genel olarak izlemek Erişilebilirlik izni istemez.
        monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            MainActor.assumeIsolated { self?.flash(at: NSEvent.mouseLocation, event: event) }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func flash(at point: CGPoint, event: NSEvent) {
        let frame = CGRect(
            x: point.x - side / 2,
            y: point.y - side / 2,
            width: side,
            height: side
        )

        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .statusBar
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        let host = NSView(frame: NSRect(origin: .zero, size: frame.size))
        host.wantsLayer = true

        let ring = CAShapeLayer()
        let inset: CGFloat = 26
        let circle = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
        ring.path = CGPath(ellipseIn: circle, transform: nil)
        ring.fillColor = NSColor.systemYellow.withAlphaComponent(0.32).cgColor
        ring.strokeColor = NSColor.systemYellow.cgColor
        ring.lineWidth = 2.5
        ring.frame = host.bounds
        host.layer?.addSublayer(ring)

        window.contentView = host
        window.orderFrontRegardless()

        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.35
        grow.toValue = 1.7
        grow.duration = 0.42
        grow.timingFunction = CAMediaTimingFunction(name: .easeOut)

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1.0
        fade.toValue = 0.0
        fade.duration = 0.42

        ring.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        ring.frame = host.bounds
        ring.add(grow, forKey: "grow")
        ring.add(fade, forKey: "fade")
        ring.opacity = 0

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            window.orderOut(nil)
        }
    }
}

/// Kayıt sırasında basılan tuşları ekranın altında gösterir.
///
/// Klavye olaylarını genel olarak izlemek Erişilebilirlik izni gerektirir.
/// İzin yoksa özellik sessizce kapalı kalır ve kullanıcıya bir kez söylenir.
@MainActor
final class KeystrokeIndicator {

    static let shared = KeystrokeIndicator()

    private var monitor: Any?
    private var window: NSWindow?
    private var label: NSTextField?
    private var hideWork: DispatchWorkItem?
    private var recent: [String] = []

    private init() {}

    var isRunning: Bool { monitor != nil }

    /// İzin verilmediyse `false` döner. Çağıran kullanıcıyı bilgilendirir.
    @discardableResult
    func start() -> Bool {
        guard monitor == nil else { return true }
        guard AXIsProcessTrusted() else { return false }

        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.show(event) }
        }
        return true
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        hideWork?.cancel()
        window?.orderOut(nil)
        window = nil
        label = nil
        recent.removeAll()
    }

    static func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func show(_ event: NSEvent) {
        let text = KeystrokeIndicator.describe(event)
        guard !text.isEmpty else { return }

        recent.append(text)
        if recent.count > 6 { recent.removeFirst(recent.count - 6) }

        ensureWindow()
        label?.stringValue = recent.joined(separator: "  ")
        resizeToFit()

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.recent.removeAll()
            self?.window?.orderOut(nil)
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }

    private func ensureWindow() {
        if let window { window.orderFrontRegardless(); return }

        let text = NSTextField(labelWithString: "")
        text.font = .systemFont(ofSize: 22, weight: .semibold)
        text.textColor = .white
        text.alignment = .center
        label = text

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        text.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 18),
            text.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -18),
            text.topAnchor.constraint(equalTo: background.topAnchor, constant: 10),
            text.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -10),
        ])

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 52),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = background
        window.level = .statusBar
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.orderFrontRegardless()
        self.window = window
    }

    private func resizeToFit() {
        guard let window, let background = window.contentView else { return }
        let size = background.fittingSize
        let screen = NSScreen.main ?? NSScreen.screens[0]
        window.setFrame(
            NSRect(
                x: screen.visibleFrame.midX - size.width / 2,
                y: screen.visibleFrame.minY + 60,
                width: size.width,
                height: size.height
            ),
            display: true
        )
    }

    /// Tuşu okunur bir metne çevirir. Değiştirici tuşlar simgeyle gösterilir.
    static func describe(_ event: NSEvent) -> String {
        var text = ""
        if event.modifierFlags.contains(.control) { text += "⌃" }
        if event.modifierFlags.contains(.option) { text += "⌥" }
        if event.modifierFlags.contains(.shift) { text += "⇧" }
        if event.modifierFlags.contains(.command) { text += "⌘" }

        let name = KeyCodeNames.name(for: UInt32(event.keyCode))
        if name.hasPrefix("Key ") {
            let typed = event.charactersIgnoringModifiers ?? ""
            return text + typed.uppercased()
        }
        return text + name
    }
}
