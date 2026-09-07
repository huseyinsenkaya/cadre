import AppKit

/// Yakalamadan sonra köşede beliren küçük kart. Buradan düzenlenir, kopyalanır,
/// kaydedilir ya da doğrudan başka bir uygulamaya sürüklenir.
@MainActor
final class ThumbnailOverlayController {

    static let shared = ThumbnailOverlayController()

    private var window: NSWindow?
    private var dismissWork: DispatchWorkItem?

    private init() {}

    /// Kendi testi kartın gerçekten açıldığını buradan doğrular.
    var isPresenting: Bool { window != nil }

    func present(shot: Shot) {
        dismiss(animated: false)

        let card = ThumbnailCardView(shot: shot)
        card.onDismiss = { [weak self] in self?.dismiss(animated: true) }
        card.onHoverChange = { [weak self] hovering in
            if hovering { self?.cancelTimer() } else { self?.startTimer() }
        }

        let size = card.fittingSize
        guard let screen = NSScreen.main else { return }
        let frame = NSRect(
            x: screen.visibleFrame.minX + 24,
            y: screen.visibleFrame.minY + 24,
            width: size.width,
            height: size.height
        )

        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = card
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = false
        window.alphaValue = 0
        window.orderFrontRegardless()

        self.window = window

        let start = frame.offsetBy(dx: -40, dy: 0)
        window.setFrame(start, display: false)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
            window.animator().setFrame(frame, display: true)
        }

        startTimer()
    }

    private func startTimer() {
        cancelTimer()
        let seconds = Settings.shared.overlaySeconds
        guard seconds > 0 else { return }
        let work = DispatchWorkItem { [weak self] in self?.dismiss(animated: true) }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func cancelTimer() {
        dismissWork?.cancel()
        dismissWork = nil
    }

    func dismiss(animated: Bool) {
        cancelTimer()
        guard let window else { return }
        self.window = nil
        guard animated else {
            window.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            window.animator().alphaValue = 0
            window.animator().setFrame(window.frame.offsetBy(dx: -30, dy: 0), display: true)
        } completionHandler: {
            window.orderOut(nil)
        }
    }
}

private final class ThumbnailCardView: NSView, NSDraggingSource {

    var onDismiss: (() -> Void)?
    var onHoverChange: ((Bool) -> Void)?

    private var shot: Shot
    private let imageView = NSImageView()
    private var dragStart: CGPoint?
    private var trackingArea: NSTrackingArea?

    private let cardWidth: CGFloat = 286

    init(shot: Shot) {
        self.shot = shot
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        wantsLayer = true

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.borderWidth = 1
        background.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)

        let aspect = CGFloat(shot.image.height) / CGFloat(max(1, shot.image.width))
        let previewHeight = min(max(72, (cardWidth - 20) * aspect), 190)

        imageView.image = shot.nsImage
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 8
        imageView.layer?.masksToBounds = true
        imageView.layer?.borderWidth = 1
        imageView.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        imageView.translatesAutoresizingMaskIntoConstraints = false

        let buttons = NSStackView(views: [
            makeButton("Edit", action: #selector(edit)),
            makeButton("Pin", action: #selector(pinShot)),
            makeButton("Copy", action: #selector(copyShot)),
            makeButton("Save", action: #selector(saveShot)),
            makeButton("Close", action: #selector(close)),
        ])
        buttons.orientation = .horizontal
        buttons.distribution = .fillEqually
        buttons.spacing = 4
        buttons.translatesAutoresizingMaskIntoConstraints = false

        background.addSubview(imageView)
        background.addSubview(buttons)

        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),

            imageView.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 10),
            imageView.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -10),
            imageView.topAnchor.constraint(equalTo: background.topAnchor, constant: 10),
            imageView.heightAnchor.constraint(equalToConstant: previewHeight),

            buttons.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 10),
            buttons.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -10),
            buttons.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 8),
            buttons.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -10),
            buttons.heightAnchor.constraint(equalToConstant: 24),

            widthAnchor.constraint(equalToConstant: cardWidth),
        ])
    }

    private func makeButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .accessoryBarAction
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11, weight: .medium)
        return button
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }

    // MARK: - Eylemler

    @objc private func edit() {
        onDismiss?()
        EditorWindowController.open(with: shot)
    }

    @objc private func pinShot() {
        PinnedShotWindow.pin(shot)
        onDismiss?()
    }

    @objc private func copyShot() {
        shot.copyToClipboard()
        Notifier.show("Copied to clipboard")
        onDismiss?()
    }

    @objc private func saveShot() {
        do {
            let url = try shot.save()
            Notifier.show("Saved", detail: url.lastPathComponent)
            onDismiss?()
        } catch {
            Notifier.show(error: error)
        }
    }

    @objc private func close() { onDismiss?() }

    // MARK: - Sürükleyip bırakma

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - dragStart.x, point.y - dragStart.y) > 6 else { return }
        self.dragStart = nil

        guard let url = TempFiles.write(shot) else { return }
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(imageView.frame, contents: shot.nsImage)
        beginDraggingSession(with: [item], event: event, source: self)
        onDismiss?()
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        [.copy]
    }
}
