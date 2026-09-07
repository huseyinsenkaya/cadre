import AppKit

/// Ekranda üstte duran, taşınabilir görüntü penceresi.
///
/// Kilit kipinde pencere fare olaylarını geçirir: altındaki uygulamayla çalışırken
/// görüntü ekranda kalır. Kilitli pencere kendini açamaz, bu yüzden menü çubuğundan
/// açılır. Kilidi menüsüz bırakmak pencereyi kapatılamaz hale getirir.
@MainActor
final class PinnedShotWindow: NSWindow {

    private static var openWindows: [PinnedShotWindow] = []

    static var pinnedCount: Int { openWindows.count }
    static var hasLockedWindow: Bool { openWindows.contains { $0.isLocked } }

    static func unlockAll() {
        for window in openWindows { window.setLocked(false) }
    }

    static func closeAll() {
        for window in openWindows { window.orderOut(nil) }
        openWindows.removeAll()
    }

    @discardableResult
    static func pin(_ shot: Shot) -> PinnedShotWindow {
        let window = PinnedShotWindow(shot: shot)
        openWindows.append(window)
        window.orderFrontRegardless()
        window.makeFirstResponder(window.contentImageView)
        Notifier.show("Pinned", detail: "Press ✕ or Esc to close")
        return window
    }

    private let shot: Shot
    private let contentImageView = PinnedImageView()
    private var isLocked = false
    private var scaleFactor: CGFloat = 1

    override var canBecomeKey: Bool { !isLocked }

    private init(shot: Shot) {
        self.shot = shot

        let aspect = CGFloat(shot.image.height) / CGFloat(max(1, shot.image.width))
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let width = min(CGFloat(shot.image.width) / screen.backingScaleFactor, screen.visibleFrame.width * 0.45)
        let size = NSSize(width: width, height: (width * aspect).rounded())
        let origin = CGPoint(
            x: screen.visibleFrame.maxX - size.width - 40,
            y: screen.visibleFrame.maxY - size.height - 40
        )

        super.init(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )

        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        aspectRatio = size

        contentImageView.image = shot.nsImage
        contentImageView.owner = self
        contentView = contentImageView
    }

    // MARK: - Denetimler

    func setLocked(_ locked: Bool) {
        isLocked = locked
        ignoresMouseEvents = locked
        contentImageView.locked = locked
        contentImageView.needsDisplay = true
    }

    func toggleLock() { setLocked(!isLocked) }

    func changeOpacity(by delta: CGFloat) {
        alphaValue = min(1, max(0.15, alphaValue + delta))
    }

    func resize(by delta: CGFloat) {
        let current = frame
        let width = min(max(120, current.width * (1 + delta)), 4000)
        let height = (width * current.height / current.width).rounded()
        setFrame(
            NSRect(x: current.minX, y: current.maxY - height, width: width, height: height),
            display: true,
            animate: false
        )
    }

    func copyImage() {
        shot.copyToClipboard()
        Notifier.show("Copied to clipboard")
    }

    func saveImage() {
        do {
            let url = try shot.save()
            Notifier.show("Saved", detail: url.lastPathComponent)
        } catch {
            Notifier.show(error: error)
        }
    }

    func openInEditor() {
        EditorWindowController.open(with: shot)
        dismiss()
    }

    func dismiss() {
        orderOut(nil)
        PinnedShotWindow.openWindows.removeAll { $0 === self }
    }

    func dragOut(with event: NSEvent) {
        guard let url = TempFiles.write(shot) else { return }
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(contentImageView.bounds, contents: shot.nsImage)
        contentImageView.beginDraggingSession(with: [item], event: event, source: contentImageView)
    }
}

private final class PinnedImageView: NSImageView, NSDraggingSource {

    weak var owner: PinnedShotWindow?
    var locked = false

    private var hovering = false
    private var trackingArea: NSTrackingArea?
    private var dragStart: CGPoint?

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        imageScaling = .scaleAxesIndependently
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

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

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

    private let buttonSide: CGFloat = 26

    private var closeButtonRect: CGRect {
        CGRect(x: bounds.maxX - buttonSide - 8, y: bounds.maxY - buttonSide - 8,
               width: buttonSide, height: buttonSide)
    }

    private var lockButtonRect: CGRect {
        closeButtonRect.offsetBy(dx: -(buttonSide + 6), dy: 0)
    }

    /// Düğmeler her zaman görünür. Yalnız fare üstündeyken çizmek, pencereyi
    /// kapatmanın yolu yokmuş gibi gösteriyordu.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !locked, let context = NSGraphicsContext.current?.cgContext else { return }

        let opacity: CGFloat = hovering ? 0.82 : 0.5
        for (rect, glyph) in [(closeButtonRect, "✕"), (lockButtonRect, "🔒")] {
            context.setFillColor(NSColor.black.withAlphaComponent(opacity).cgColor)
            NSBezierPath(ovalIn: rect).fill()
            context.setStrokeColor(NSColor.white.withAlphaComponent(opacity * 0.5).cgColor)
            context.setLineWidth(1)
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()

            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .bold),
                .foregroundColor: NSColor.white,
            ]
            let text = glyph as NSString
            let size = text.size(withAttributes: attributes)
            text.draw(
                at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                withAttributes: attributes
            )
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if closeButtonRect.contains(point) { owner?.dismiss(); return }
        if lockButtonRect.contains(point) { owner?.toggleLock(); return }
        dragStart = point
        super.mouseDown(with: event)
    }

    /// Option basılıyken sürüklemek görüntüyü başka uygulamaya bırakır.
    override func mouseDragged(with event: NSEvent) {
        guard event.modifierFlags.contains(.option), let dragStart else {
            super.mouseDragged(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - dragStart.x, point.y - dragStart.y) > 6 else { return }
        self.dragStart = nil
        owner?.dragOut(with: event)
    }

    /// Kaydırma boyu, Option ile birlikte saydamlığı değiştirir.
    override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaY / 400
        if event.modifierFlags.contains(.option) {
            owner?.changeOpacity(by: delta)
        } else {
            owner?.resize(by: delta)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(copyImage), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Save", action: #selector(saveImage), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Open in Editor", action: #selector(openInEditor), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Lock Mode", action: #selector(toggleLock), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Close", action: #selector(close), keyEquivalent: "").target = self
        return menu
    }

    @objc private func copyImage() { owner?.copyImage() }
    @objc private func saveImage() { owner?.saveImage() }
    @objc private func openInEditor() { owner?.openInEditor() }
    @objc private func toggleLock() { owner?.toggleLock() }
    @objc private func close() { owner?.dismiss() }

    override func keyDown(with event: NSEvent) {
        let isEscape = event.keyCode == 53
        let isCloseShortcut = event.modifierFlags.contains(.command)
            && event.charactersIgnoringModifiers?.lowercased() == "w"
        if isEscape || isCloseShortcut {
            owner?.dismiss()
        } else {
            super.keyDown(with: event)
        }
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        [.copy]
    }
}
