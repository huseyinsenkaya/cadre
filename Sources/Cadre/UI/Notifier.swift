import AppKit

/// Kısa ömürlü bilgi balonu. Sistem bildirim izni istemeden geri bildirim verir.
enum Notifier {

    private static var current: NSWindow?

    static func show(_ message: String, detail: String? = nil, isError: Bool = false) {
        DispatchQueue.main.async { present(message, detail: detail, isError: isError) }
    }

    static func show(error: Error) {
        show(error.localizedDescription, isError: true)
    }

    private static func present(_ message: String, detail: String?, isError: Bool) {
        current?.orderOut(nil)

        let title = NSTextField(labelWithString: message)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .white
        title.lineBreakMode = .byTruncatingMiddle
        title.maximumNumberOfLines = 2

        let stack = NSStackView(views: [title])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2

        if let detail {
            let subtitle = NSTextField(labelWithString: detail)
            subtitle.font = .systemFont(ofSize: 11)
            subtitle.textColor = NSColor.white.withAlphaComponent(0.7)
            subtitle.lineBreakMode = .byTruncatingMiddle
            stack.addArrangedSubview(subtitle)
        }

        let background = NSVisualEffectView()
        background.material = isError ? .hudWindow : .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.borderWidth = 1
        background.layer?.borderColor = (isError ? NSColor.systemRed : NSColor.white)
            .withAlphaComponent(isError ? 0.6 : 0.12).cgColor

        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: background.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -12),
        ])

        let fitting = background.fittingSize
        let size = NSSize(width: min(max(220, fitting.width), 420), height: fitting.height)

        guard let screen = NSScreen.main else { return }
        let frame = NSRect(
            x: screen.visibleFrame.midX - size.width / 2,
            y: screen.visibleFrame.minY + 90,
            width: size.width,
            height: size.height
        )

        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = background
        window.level = .statusBar
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        window.alphaValue = 0
        window.orderFrontRegardless()

        current = window
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            window.animator().alphaValue = 1
        }

        let deadline = DispatchTime.now() + (isError ? 4.5 : 2.2)
        DispatchQueue.main.asyncAfter(deadline: deadline) {
            guard current === window else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                window.animator().alphaValue = 0
            } completionHandler: {
                window.orderOut(nil)
                if current === window { current = nil }
            }
        }
    }

    /// Sistem ekran görüntüsü sesi; bulunamazsa sessiz kalır.
    ///
    /// Ses açılışta bir kez diskten okunur. Her yakalamada `NSSound` kurmak
    /// ana iş parçacığını 80 ms kadar tutuyordu; kullanıcı bunu donma olarak görüyordu.
    private static let shutter: NSSound? = {
        let candidates = [
            "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Grab.aif",
            "/System/Library/Sounds/Grab.aiff",
        ]
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            if let sound = NSSound(contentsOfFile: path, byReference: true) { return sound }
        }
        return NSSound(named: "Pop")
    }()

    /// Sesi açılışta hazırlar. Ana iş parçacığı boştayken çağrılır.
    static func prepareShutter() {
        _ = shutter
    }

    static func playShutter() {
        guard Settings.shared.playSound, let sound = shutter else { return }
        // Aynı ses arka arkaya çalınırsa önceki çalma durdurulmadan yeniden başlamaz.
        if sound.isPlaying { sound.stop() }
        sound.play()
    }
}
