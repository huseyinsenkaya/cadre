import AppKit
import Carbon.HIToolbox

private let overlayAccent = NSColor(srgbRed: 0.35, green: 0.64, blue: 1.0, alpha: 1)
private let overlayDim = NSColor.black.withAlphaComponent(0.42)
private let overlayBadgeFill = NSColor.black.withAlphaComponent(0.78)

/// Seçim katmanının girdi yüzeyi ve çizim düzeni. Ekran başına bir tane yaşar.
///
/// Karartma, artı imleci, seçim çerçevesi ve tutamaklar CALayer üstünde durur.
/// Fare hareketi yalnız katman çerçevelerini değiştirir. Hiçbir şey yeniden çizilmez.
///
/// Önceki sürüm her fare olayında `needsDisplay = true` diyordu. Bu, ekran boyutundaki
/// görünümün tamamını kirletiyordu: retina ekranda her harekette yirmi milyon pikseli
/// işlemcide yeniden harmanlamak demekti. Kasmanın sebebi buydu. Ölçüm için tek
/// gösterge yeter: karartma dolgusu artık hiç çizilmez, dört katman olarak yerleşir.
///
/// Metin ve görüntü isteyen parçalar kendi küçük görünümlerinde durur. Her biri
/// yalnız kendi içeriği değişince çizilir ve çizim alanı ekranın değil, rozetin boyudur.
final class OverlayView: NSView {

    enum Phase {
        case idle
        case dragging
        case adjusting
    }

    enum Handle {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, inside
    }

    weak var controller: SelectionOverlayController?
    var freezeImage: CGImage?
    var screenFrame: CGRect = .zero
    var windowTargets: [WindowTarget] = []

    var mode: SelectionMode = .area {
        didSet {
            modeBar.mode = mode
            updateChrome()
        }
    }

    /// Hepsi bir arada kipinde katmanın altında kip çubuğu görünür.
    var showsModeBar = false

    enum ModeChoice: CaseIterable {
        case area, window, fullScreen, record

        var title: String {
            switch self {
            case .area: return "Area"
            case .window: return "Window"
            case .fullScreen: return "Full Screen"
            case .record: return "Record"
            }
        }

        var symbol: String {
            switch self {
            case .area: return "crop"
            case .window: return "macwindow"
            case .fullScreen: return "rectangle.inset.filled"
            case .record: return "record.circle"
            }
        }
    }

    private var modeButtons: [(rect: CGRect, choice: ModeChoice)] = []
    private var modeBarRect: CGRect = .zero
    private var actionBarRect: CGRect = .zero
    private var confirmButtonRect: CGRect = .zero
    private var cancelButtonRect: CGRect = .zero

    private var phase: Phase = .idle

    /// Kullanıcı bir seçim başlattı mı. Denetleyici katmanı kapatmadan önce buna bakar.
    var isSelecting: Bool { phase != .idle || selection != nil }
    private var selection: CGRect?
    private var anchor: CGPoint = .zero
    private var activeHandle: Handle?
    private var grabOffset: CGSize = .zero
    private var mouseLocation: CGPoint = .zero
    private var dragStartPoint: CGPoint = .zero
    private var hoveredWindow: WindowTarget?
    private var trackingArea: NSTrackingArea?

    private let handleSize: CGFloat = 9
    private let magnifierSize: CGFloat = 132
    private let magnifierZoom: CGFloat = 8

    // MARK: - Çizim katmanları

    private var chromeReady = false
    private let layerHost = PassthroughView()
    private let dimLayers: [CALayer] = (0..<4).map { _ in CALayer() }
    private let crossHorizontal = CALayer()
    private let crossVertical = CALayer()
    private let borderOuter = CALayer()
    private let borderInner = CALayer()
    private let handleLayers: [CALayer] = (0..<8).map { _ in CALayer() }

    private let magnifierView = MagnifierView()
    private let pointerBadge = BadgeView()
    private let sizeBadge = BadgeView()
    private let windowLabelBadge = BadgeView()
    private let actionBar = ActionBarView()
    private let modeBar = ModeBarView()

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    /// Uygulama etkin değilken macOS ilk tıklamayı pencereyi öne almak için harcar
    /// ve görünüme hiç vermez. Menü çubuğu uygulamasında etkinleşme isteği eşzamansızdır,
    /// bu yüzden kullanıcı katman açılır açılmaz sürüklerse ilk seçim kayboluyordu.
    /// Kullanıcı ikinci kez tıklamak zorunda kalıyordu.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Kurulum

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        buildChrome()
        window?.makeFirstResponder(self)
        rebuildTrackingArea()
        mouseLocation = convertFromScreen(NSEvent.mouseLocation)
        updateChrome()
    }

    override func layout() {
        super.layout()
        updateChrome()
    }

    private func buildChrome() {
        guard !chromeReady else { return }
        chromeReady = true
        wantsLayer = true

        // Katmanlar kendi taşıyıcı görünümünde durur. AppKit alt görünümlerin katmanlarını
        // kendi sırasına göre yerleştirir; elle eklenen katmanları o sıraya karıştırmamak
        // için taşıyıcı en altta bir alt görünüm olarak durur. Böylece rozetler her zaman
        // karartmanın üstünde kalır.
        layerHost.frame = bounds
        layerHost.autoresizingMask = [.width, .height]
        layerHost.wantsLayer = true
        addSubview(layerHost)

        let scale = window?.backingScaleFactor ?? 2
        if let host = layerHost.layer { buildLayers(in: host, scale: scale) }

        for view in [magnifierView, pointerBadge, sizeBadge, windowLabelBadge, actionBar, modeBar] as [NSView] {
            view.wantsLayer = true
            view.isHidden = true
            addSubview(view)
        }
        modeBar.mode = mode
        actionBar.frame = CGRect(origin: .zero, size: ActionBarView.barSize)
        modeBar.frame = CGRect(origin: .zero, size: ModeBarView.barSize)
        magnifierView.frame = CGRect(x: 0, y: 0, width: magnifierSize, height: magnifierSize)
    }

    private func buildLayers(in host: CALayer, scale: CGFloat) {
        for dim in dimLayers {
            dim.backgroundColor = overlayDim.cgColor
            dim.contentsScale = scale
            host.addSublayer(dim)
        }

        for line in [crossHorizontal, crossVertical] {
            line.backgroundColor = NSColor.white.withAlphaComponent(0.55).cgColor
            line.contentsScale = scale
            line.isHidden = true
            host.addSublayer(line)
        }

        borderOuter.borderColor = NSColor.white.cgColor
        borderInner.borderColor = overlayAccent.withAlphaComponent(0.9).cgColor
        for border in [borderOuter, borderInner] {
            border.borderWidth = 1
            border.contentsScale = scale
            border.isHidden = true
            host.addSublayer(border)
        }

        for handle in handleLayers {
            handle.backgroundColor = NSColor.white.cgColor
            handle.borderColor = overlayAccent.cgColor
            handle.borderWidth = 1
            handle.contentsScale = scale
            handle.isHidden = true
            host.addSublayer(handle)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        rebuildTrackingArea()
    }

    /// Artı imleci imleç dikdörtgeninden gelir.
    ///
    /// Önceki sürüm imleci yalnız `takeFocus()` içinde bir kez `NSCursor.crosshair.set()`
    /// ile kuruyordu. `set()` geçicidir: AppKit fare her hareket ettiğinde imleci
    /// pencerenin imleç dikdörtgenlerinden yeniden okur ve dikdörtgen olmadığı için
    /// ok imlecine dönüyordu. Kullanıcı katman açıldıktan sonra artıyı geç görüyordu.
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.crosshair.set()
    }

    private func rebuildTrackingArea() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    private func convertFromScreen(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - screenFrame.minX, y: point.y - screenFrame.minY)
    }

    private var pointerIsHere: Bool {
        screenFrame.contains(NSEvent.mouseLocation)
    }

    // MARK: - Yerleşim

    /// Katmanın görünen her parçası buradan yerleşir. Fare hareketinin tek yaptığı iş budur.
    private func updateChrome() {
        guard chromeReady else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let highlight = currentHighlight()
        layoutDim(around: highlight)
        layoutSelection(highlight)
        layoutPointerAids(highlight: highlight)
        layoutWindowLabel()
        layoutModeBar()
    }

    private func layoutDim(around hole: CGRect?) {
        guard let hole = hole?.intersection(bounds), !hole.isEmpty else {
            dimLayers[0].frame = bounds
            for index in 1..<dimLayers.count { dimLayers[index].frame = .zero }
            return
        }
        dimLayers[0].frame = CGRect(
            x: 0, y: hole.maxY, width: bounds.width, height: max(0, bounds.maxY - hole.maxY)
        )
        dimLayers[1].frame = CGRect(x: 0, y: 0, width: bounds.width, height: max(0, hole.minY))
        dimLayers[2].frame = CGRect(x: 0, y: hole.minY, width: max(0, hole.minX), height: hole.height)
        dimLayers[3].frame = CGRect(
            x: hole.maxX, y: hole.minY, width: max(0, bounds.maxX - hole.maxX), height: hole.height
        )
    }

    private func layoutSelection(_ rect: CGRect?) {
        guard let rect else {
            borderOuter.isHidden = true
            borderInner.isHidden = true
            for handle in handleLayers { handle.isHidden = true }
            sizeBadge.isHidden = true
            actionBar.isHidden = true
            return
        }

        borderOuter.isHidden = false
        borderInner.isHidden = false
        borderOuter.frame = rect.insetBy(dx: -1, dy: -1)
        borderInner.frame = rect

        let showsHandles = mode == .area && phase == .adjusting
        for (layer, point) in zip(handleLayers, handlePoints(for: rect)) {
            layer.isHidden = !showsHandles
            guard showsHandles else { continue }
            layer.frame = CGRect(
                x: point.x - handleSize / 2,
                y: point.y - handleSize / 2,
                width: handleSize,
                height: handleSize
            )
        }

        placeSizeBadge(for: rect)
        placeActionBar(for: rect)
    }

    private func placeSizeBadge(for rect: CGRect) {
        let scale = window?.backingScaleFactor ?? 2
        let pixels = CGSize(width: (rect.width * scale).rounded(), height: (rect.height * scale).rounded())
        sizeBadge.set("\(Int(pixels.width)) × \(Int(pixels.height))", fontSize: 12)
        let size = sizeBadge.fittingBadgeSize

        var origin = CGPoint(x: rect.midX - size.width / 2, y: rect.maxY + 8)
        if origin.y + size.height > bounds.maxY - 4 { origin.y = rect.minY - size.height - 8 }
        if origin.y < 4 { origin.y = rect.minY + 8 }
        origin.x = min(max(4, origin.x), bounds.maxX - size.width - 4)

        sizeBadge.isHidden = false
        place(sizeBadge, at: origin, size: size)
    }

    private func placeActionBar(for rect: CGRect) {
        guard mode == .area, phase == .adjusting else {
            actionBar.isHidden = true
            actionBarRect = .zero
            return
        }
        let size = ActionBarView.barSize
        var origin = CGPoint(x: rect.maxX - size.width, y: rect.minY - size.height - 8)
        if origin.y < 4 { origin.y = rect.maxY + 8 }
        if origin.y + size.height > bounds.maxY - 4 { origin.y = rect.minY + 8 }
        origin.x = min(max(4, origin.x), bounds.maxX - size.width - 4)

        actionBarRect = CGRect(origin: origin, size: size)
        cancelButtonRect = ActionBarView.cancelRect.offsetBy(dx: origin.x, dy: origin.y)
        confirmButtonRect = ActionBarView.confirmRect.offsetBy(dx: origin.x, dy: origin.y)
        actionBar.isHidden = false
        place(actionBar, at: origin, size: size)
    }

    /// Artı imleci, büyüteç ve imleç rozeti. Üçü de aynı koşullara bakar.
    private func layoutPointerAids(highlight: CGRect?) {
        let showsCrosshair = mode == .area && highlight == nil && pointerIsHere
        crossHorizontal.isHidden = !showsCrosshair
        crossVertical.isHidden = !showsCrosshair
        if showsCrosshair {
            crossHorizontal.frame = CGRect(x: 0, y: mouseLocation.y.rounded(), width: bounds.width, height: 1)
            crossVertical.frame = CGRect(x: mouseLocation.x.rounded(), y: 0, width: 1, height: bounds.height)
        }

        // Büyüteç gerçek pikselleri gösterir; donmuş kare yoksa gösterecek bir şey yok.
        let showsMagnifier = mode == .area && phase != .adjusting && pointerIsHere && freezeImage != nil
        magnifierView.isHidden = !showsMagnifier

        if showsMagnifier, let freezeImage {
            placeMagnifier(freezeImage)
            return
        }
        if showsCrosshair, freezeImage == nil {
            let readout = "\(Int(mouseLocation.x + screenFrame.minX)), \(Int(mouseLocation.y + screenFrame.minY))"
            pointerBadge.set(readout, fontSize: 11)
            pointerBadge.isHidden = false
            place(pointerBadge, at: CGPoint(x: mouseLocation.x + 16, y: mouseLocation.y - 30),
                  size: pointerBadge.fittingBadgeSize)
            return
        }
        pointerBadge.isHidden = true
    }

    /// Donmuş kareden ham pikselleri büyütür. Kırpma tembeldir, örnek küçüktür:
    /// büyüteç görünümü her harekette yeniden çizilse bile alan 132 nokta karedir.
    private func placeMagnifier(_ image: CGImage) {
        let scale = window?.backingScaleFactor ?? 2
        let sampleSide = (magnifierSize / magnifierZoom).rounded()

        let pixelPoint = CGPoint(
            x: (mouseLocation.x * scale).rounded(),
            y: ((bounds.height - mouseLocation.y) * scale).rounded()
        )
        let sampleRect = CGRect(
            x: pixelPoint.x - sampleSide / 2,
            y: pixelPoint.y - sampleSide / 2,
            width: sampleSide,
            height: sampleSide
        ).integral

        magnifierView.set(sample: image.cropping(to: sampleRect), sampleSide: sampleSide)

        var origin = CGPoint(x: mouseLocation.x + 22, y: mouseLocation.y - magnifierSize - 22)
        if origin.x + magnifierSize > bounds.maxX - 8 { origin.x = mouseLocation.x - magnifierSize - 22 }
        if origin.y < 8 { origin.y = mouseLocation.y + 22 }
        origin.y = min(origin.y, bounds.maxY - magnifierSize - 34)
        place(magnifierView, at: origin, size: CGSize(width: magnifierSize, height: magnifierSize))

        let color = pixelColor(at: pixelPoint, in: image)
        let readout = "\(Int(mouseLocation.x + screenFrame.minX)), \(Int(mouseLocation.y + screenFrame.minY))   \(color.hex)"
        pointerBadge.set(readout, fontSize: 11)
        let size = pointerBadge.fittingBadgeSize
        pointerBadge.isHidden = false
        place(pointerBadge, at: CGPoint(x: origin.x, y: origin.y - 26), size: size)
    }

    private func layoutWindowLabel() {
        guard mode == .window, let hoveredWindow else {
            windowLabelBadge.isHidden = true
            return
        }
        let rect = convertFromScreenRect(hoveredWindow.frame)
        let label = hoveredWindow.title.isEmpty
            ? hoveredWindow.appName
            : "\(hoveredWindow.appName) — \(hoveredWindow.title)"
        let trimmed = label.count > 60 ? String(label.prefix(59)) + "…" : label
        windowLabelBadge.set(trimmed, fontSize: 12, weight: .semibold)
        let size = windowLabelBadge.fittingBadgeSize

        var origin = CGPoint(x: rect.midX - size.width / 2, y: rect.minY - size.height - 10)
        if origin.y < 8 { origin.y = rect.maxY + 10 }
        origin.x = min(max(6, origin.x), bounds.maxX - size.width - 6)
        windowLabelBadge.isHidden = false
        place(windowLabelBadge, at: origin, size: size)
    }

    /// Kip çubuğu tek bir alt görünümdür ve yalnız kip değişince yeniden çizilir.
    /// Önceki sürüm dört SF Symbol görüntüsünü her fare hareketinde yeniden üretiyordu.
    private func layoutModeBar() {
        guard showsModeBar else {
            modeBar.isHidden = true
            modeButtons = []
            modeBarRect = .zero
            return
        }
        let size = ModeBarView.barSize
        let origin = CGPoint(x: bounds.midX - size.width / 2, y: 48)
        modeBarRect = CGRect(origin: origin, size: size)
        modeButtons = ModeChoice.allCases.enumerated().map { index, choice in
            (ModeBarView.buttonRect(at: index).offsetBy(dx: origin.x, dy: origin.y), choice)
        }
        modeBar.isHidden = false
        place(modeBar, at: origin, size: size)
    }

    private func place(_ view: NSView, at origin: CGPoint, size: CGSize) {
        let frame = CGRect(origin: origin, size: size)
        if view.frame != frame { view.frame = frame }
    }

    private func modeChoice(at point: CGPoint) -> ModeChoice? {
        guard showsModeBar, modeBarRect.contains(point) else { return nil }
        return modeButtons.first { $0.rect.contains(point) }?.choice
    }

    private func handle(_ choice: ModeChoice) {
        switch choice {
        case .area:
            controller?.setMode(.area)
        case .window:
            controller?.setMode(.window)
        case .fullScreen:
            controller?.confirmFullScreen(on: self)
        case .record:
            guard let selection, selection.width >= 4, selection.height >= 4 else {
                Notifier.show("Select the area to record first.")
                return
            }
            controller?.confirmRecord(selection, on: self)
        }
        updateChrome()
    }

    private func currentHighlight() -> CGRect? {
        if mode == .window {
            guard let hoveredWindow else { return nil }
            let rect = convertFromScreenRect(hoveredWindow.frame).intersection(bounds)
            return rect.width >= 1 && rect.height >= 1 ? rect : nil
        }
        guard let selection, selection.width >= 1, selection.height >= 1 else { return nil }
        return selection
    }

    private func convertFromScreenRect(_ rect: CGRect) -> CGRect {
        rect.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
    }

    private func handlePoints(for rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.midX, y: rect.maxY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.maxX, y: rect.midY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.midX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.midY),
        ]
    }

    private struct PixelColor {
        let red: Int, green: Int, blue: Int
        var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }
    }

    /// Tek piksel okunur. Önce o piksel kırpılır, sonra çizilir.
    /// Bütün kareyi 1×1 tampona çizmek her fare hareketinde tüm görüntüyü
    /// yeniden örnekliyordu; donmanın sebebi buydu.
    private func pixelColor(at point: CGPoint, in image: CGImage) -> PixelColor {
        let crop = CGRect(x: point.x, y: point.y, width: 1, height: 1).integral
        guard crop.minX >= 0, crop.minY >= 0,
              crop.maxX <= CGFloat(image.width), crop.maxY <= CGFloat(image.height),
              let pixelImage = image.cropping(to: crop)
        else { return PixelColor(red: 0, green: 0, blue: 0) }

        var pixel: [UInt8] = [0, 0, 0, 0]
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return PixelColor(red: 0, green: 0, blue: 0) }
        context.draw(pixelImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return PixelColor(red: Int(pixel[0]), green: Int(pixel[1]), blue: Int(pixel[2]))
    }

    // MARK: - Fare

    /// Sağ tık her zaman çıkış yoludur; seçim kipinden bağımsız çalışır.
    override func rightMouseDown(with event: NSEvent) {
        controller?.cancel()
    }

    override func otherMouseDown(with event: NSEvent) {
        controller?.cancel()
    }

    override func mouseMoved(with event: NSEvent) {
        controller?.noteInteraction()
        mouseLocation = convert(event.locationInWindow, from: nil)
        if mode == .window { updateHoveredWindow() }
        updateChrome()
    }

    override func mouseEntered(with event: NSEvent) {
        // Çok ekranlı kurulumda tuşlar ve fare hareketi yalnız anahtar pencereye gider.
        // Fare hangi ekrana geçtiyse o ekranın penceresi anahtar olur.
        takeKey()
        updateChrome()
    }

    override func mouseExited(with event: NSEvent) {
        updateChrome()
    }

    private func takeKey() {
        guard let window, !window.isKeyWindow else { return }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(self)
    }

    private func updateHoveredWindow() {
        let screenPoint = CGPoint(
            x: mouseLocation.x + screenFrame.minX,
            y: mouseLocation.y + screenFrame.minY
        )
        hoveredWindow = windowTargets.first { $0.frame.contains(screenPoint) }
    }

    override func mouseDown(with event: NSEvent) {
        controller?.noteInteraction()
        takeKey()
        let point = convert(event.locationInWindow, from: nil)
        mouseLocation = point

        if let choice = modeChoice(at: point) {
            handle(choice)
            return
        }

        if mode == .window {
            updateHoveredWindow()
            if let hoveredWindow { controller?.confirmWindow(hoveredWindow) }
            return
        }

        if phase == .adjusting, actionBarRect.contains(point) {
            if confirmButtonRect.contains(point) { confirmSelection() }
            else if cancelButtonRect.contains(point) { controller?.cancel() }
            return
        }

        if phase == .adjusting, let selection {
            if let handle = handle(at: point, in: selection) {
                activeHandle = handle
                anchor = oppositeCorner(of: handle, in: selection)
                grabOffset = CGSize(width: point.x - selection.minX, height: point.y - selection.minY)
                phase = .dragging
                return
            }
        }

        activeHandle = nil
        anchor = point
        dragStartPoint = point
        selection = CGRect(origin: point, size: .zero)
        phase = .dragging
        updateChrome()
    }

    override func mouseDragged(with event: NSEvent) {
        guard mode == .area, phase == .dragging else { return }
        if modeBarRect.contains(dragStartPoint) { return }
        let point = clamp(convert(event.locationInWindow, from: nil))
        mouseLocation = point

        if let handle = activeHandle, let current = selection {
            selection = resize(current, handle: handle, to: point).standardized
        } else {
            var rect = CGRect(
                x: min(anchor.x, point.x),
                y: min(anchor.y, point.y),
                width: abs(point.x - anchor.x),
                height: abs(point.y - anchor.y)
            )
            if event.modifierFlags.contains(.shift) {
                let side = max(rect.width, rect.height)
                rect.size = CGSize(width: side, height: side)
                if point.x < anchor.x { rect.origin.x = anchor.x - side }
                if point.y < anchor.y { rect.origin.y = anchor.y - side }
            }
            selection = rect.intersection(bounds)
        }
        updateChrome()
    }

    override func mouseUp(with event: NSEvent) {
        guard mode == .area else { return }
        defer { updateChrome() }
        activeHandle = nil

        guard let rect = selection, rect.width >= 3, rect.height >= 3 else {
            selection = nil
            phase = .idle
            return
        }

        // Onay adımı kapalıyken fare bırakılır bırakılmaz yakalanır.
        guard Settings.shared.confirmBeforeCapture else {
            confirmSelection()
            return
        }
        phase = .adjusting
    }

    private func clamp(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(0, point.x), bounds.maxX),
            y: min(max(0, point.y), bounds.maxY)
        )
    }

    private func handle(at point: CGPoint, in rect: CGRect) -> Handle? {
        let grab: CGFloat = 12
        let handles: [(Handle, CGPoint)] = [
            (.topLeft, CGPoint(x: rect.minX, y: rect.maxY)),
            (.top, CGPoint(x: rect.midX, y: rect.maxY)),
            (.topRight, CGPoint(x: rect.maxX, y: rect.maxY)),
            (.right, CGPoint(x: rect.maxX, y: rect.midY)),
            (.bottomRight, CGPoint(x: rect.maxX, y: rect.minY)),
            (.bottom, CGPoint(x: rect.midX, y: rect.minY)),
            (.bottomLeft, CGPoint(x: rect.minX, y: rect.minY)),
            (.left, CGPoint(x: rect.minX, y: rect.midY)),
        ]
        for (handle, position) in handles {
            let box = CGRect(x: position.x - grab, y: position.y - grab, width: grab * 2, height: grab * 2)
            if box.contains(point) { return handle }
        }
        return rect.contains(point) ? .inside : nil
    }

    private func oppositeCorner(of handle: Handle, in rect: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: return CGPoint(x: rect.maxX, y: rect.minY)
        case .topRight: return CGPoint(x: rect.minX, y: rect.minY)
        case .bottomLeft: return CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottomRight: return CGPoint(x: rect.minX, y: rect.maxY)
        default: return CGPoint(x: rect.minX, y: rect.minY)
        }
    }

    private func resize(_ rect: CGRect, handle: Handle, to point: CGPoint) -> CGRect {
        var result = rect
        switch handle {
        case .inside:
            result.origin = CGPoint(x: point.x - grabOffset.width, y: point.y - grabOffset.height)
            result.origin.x = min(max(0, result.origin.x), bounds.maxX - result.width)
            result.origin.y = min(max(0, result.origin.y), bounds.maxY - result.height)
        case .left:
            result.size.width = rect.maxX - point.x
            result.origin.x = point.x
        case .right:
            result.size.width = point.x - rect.minX
        case .top:
            result.size.height = point.y - rect.minY
        case .bottom:
            result.size.height = rect.maxY - point.y
            result.origin.y = point.y
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            result = CGRect(
                x: min(anchor.x, point.x),
                y: min(anchor.y, point.y),
                width: abs(point.x - anchor.x),
                height: abs(point.y - anchor.y)
            )
        }
        return result.intersection(bounds)
    }

    // MARK: - Klavye

    override func keyDown(with event: NSEvent) {
        controller?.noteInteraction()
        switch Int(event.keyCode) {
        case kVK_Escape:
            controller?.cancel()
        case kVK_Return, kVK_ANSI_KeypadEnter:
            confirmSelection()
        case kVK_Space:
            controller?.setMode(controller?.currentMode == .window ? .area : .window)
            if controller?.currentMode == .window { updateHoveredWindow() }
            updateChrome()
        case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow:
            nudge(keyCode: Int(event.keyCode), resizing: event.modifierFlags.contains(.shift))
        default:
            if event.charactersIgnoringModifiers == "a", event.modifierFlags.contains(.command) {
                selection = bounds
                phase = .adjusting
                updateChrome()
            } else {
                super.keyDown(with: event)
            }
        }
    }

    private func nudge(keyCode: Int, resizing: Bool) {
        guard var rect = selection else { return }
        let step: CGFloat = 1
        switch keyCode {
        case kVK_LeftArrow:
            if resizing { rect.size.width = max(1, rect.width - step) } else { rect.origin.x -= step }
        case kVK_RightArrow:
            if resizing { rect.size.width += step } else { rect.origin.x += step }
        case kVK_UpArrow:
            if resizing { rect.size.height += step } else { rect.origin.y += step }
        case kVK_DownArrow:
            if resizing { rect.size.height = max(1, rect.height - step) } else { rect.origin.y -= step }
        default: break
        }
        selection = rect.intersection(bounds)
        updateChrome()
    }

    private func confirmSelection() {
        guard let selection, selection.width >= 1, selection.height >= 1 else { return }
        controller?.confirmArea(selection, on: self)
    }
}

// MARK: - Alt görünümler

/// Fareyi hiç tutmayan görünüm. Katmanın bütün isabet sınaması OverlayView'de kalır.
private class PassthroughView: NSView {
    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Yuvarlak köşeli koyu rozet. Yalnız metni değişince yeniden çizilir.
private final class BadgeView: PassthroughView {

    private static let padding = CGSize(width: 8, height: 5)

    private var text = ""
    private var fontSize: CGFloat = 12
    private var weight: NSFont.Weight = .medium

    private static func attributes(size: CGFloat, weight: NSFont.Weight) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight),
            .foregroundColor: NSColor.white,
        ]
    }

    var fittingBadgeSize: CGSize {
        let size = (text as NSString).size(withAttributes: BadgeView.attributes(size: fontSize, weight: weight))
        return CGSize(
            width: size.width + BadgeView.padding.width * 2,
            height: size.height + BadgeView.padding.height * 2
        )
    }

    func set(_ newText: String, fontSize newSize: CGFloat, weight newWeight: NSFont.Weight = .medium) {
        guard newText != text || newSize != fontSize || newWeight != weight else { return }
        text = newText
        fontSize = newSize
        weight = newWeight
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !text.isEmpty else { return }
        overlayBadgeFill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        (text as NSString).draw(
            at: CGPoint(x: BadgeView.padding.width, y: BadgeView.padding.height),
            withAttributes: BadgeView.attributes(size: fontSize, weight: weight)
        )
    }
}

/// Büyüteç. Çizim alanı 132 nokta karedir, ekranın tamamı değil.
private final class MagnifierView: PassthroughView {

    private var sample: CGImage?
    private var sampleSide: CGFloat = 1

    func set(sample newSample: CGImage?, sampleSide newSide: CGFloat) {
        guard newSample !== sample || newSide != sampleSide else { return }
        sample = newSample
        sampleSide = newSide
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let sample, let context = NSGraphicsContext.current?.cgContext else { return }

        context.saveGState()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).addClip()
        // İnterpolasyon kapalı: piksel sınırları görünür kalır ve tek piksellik hizalama yapılabilir.
        context.interpolationQuality = .none
        context.draw(sample, in: bounds)
        context.restoreGState()

        NSColor.white.withAlphaComponent(0.9).setStroke()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
        border.lineWidth = 2
        border.stroke()

        let cell = bounds.width / max(1, sampleSide)
        let box = CGRect(
            x: (bounds.midX - cell / 2).rounded(),
            y: (bounds.midY - cell / 2).rounded(),
            width: cell,
            height: cell
        )
        context.setStrokeColor(overlayAccent.cgColor)
        context.setLineWidth(1.5)
        context.stroke(box)
    }
}

/// Onay ve iptal düğmeleri. İçerik sabittir, bir kez çizilir.
private final class ActionBarView: PassthroughView {

    static let buttonSize = CGSize(width: 44, height: 32)
    static let spacing: CGFloat = 6
    static let barSize = CGSize(
        width: buttonSize.width * 2 + spacing * 3,
        height: buttonSize.height + spacing * 2
    )
    static let cancelRect = CGRect(
        x: spacing, y: spacing, width: buttonSize.width, height: buttonSize.height
    )
    static let confirmRect = cancelRect.offsetBy(dx: buttonSize.width + spacing, dy: 0)

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.8).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()

        overlayAccent.setFill()
        NSBezierPath(roundedRect: ActionBarView.confirmRect, xRadius: 7, yRadius: 7).fill()

        draw("✕", in: ActionBarView.cancelRect)
        draw("✓", in: ActionBarView.confirmRect)
    }

    private func draw(_ glyph: String, in rect: CGRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let size = (glyph as NSString).size(withAttributes: attributes)
        (glyph as NSString).draw(
            at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
            withAttributes: attributes
        )
    }
}

/// Hepsi bir arada çubuğu: tek kısayoldan bütün yakalama kiplerine geçit.
/// Yalnız kip değişince yeniden çizilir. Simge görüntüleri önbellekte durur.
private final class ModeBarView: PassthroughView {

    static let buttonSize = CGSize(width: 96, height: 56)
    static let spacing: CGFloat = 6
    static let barSize = CGSize(
        width: CGFloat(OverlayView.ModeChoice.allCases.count) * buttonSize.width
            + CGFloat(OverlayView.ModeChoice.allCases.count + 1) * spacing,
        height: buttonSize.height + spacing * 2
    )

    static func buttonRect(at index: Int) -> CGRect {
        CGRect(
            x: spacing + CGFloat(index) * (buttonSize.width + spacing),
            y: spacing,
            width: buttonSize.width,
            height: buttonSize.height
        )
    }

    var mode: SelectionMode = .area {
        didSet { if mode != oldValue { needsDisplay = true } }
    }

    /// SF Symbol görüntüsü bir kez üretilir ve beyaza boyanmış hâliyle saklanır.
    /// Boyama ayrı bir görüntü bağlamında yapılır; aynı bağlamda `sourceAtop`
    /// kullanmak düğmenin arka planını da beyaza çeviriyordu.
    private static func symbol(_ name: String) -> NSImage? {
        if let hit = cache[name] { return hit }
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil),
              let sized = base.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 17, weight: .medium)
              )
        else { return nil }
        let tinted = NSImage(size: sized.size, flipped: false) { rect in
            sized.draw(in: rect)
            NSColor.white.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        cache[name] = tinted
        return tinted
    }

    nonisolated(unsafe) private static var cache: [String: NSImage] = [:]

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14)
        NSColor.black.withAlphaComponent(0.82).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.14).setStroke()
        path.lineWidth = 1
        path.stroke()

        for (index, choice) in OverlayView.ModeChoice.allCases.enumerated() {
            let rect = ModeBarView.buttonRect(at: index)
            let active = (choice == .area && mode == .area) || (choice == .window && mode == .window)
            if active {
                overlayAccent.withAlphaComponent(0.9).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9).fill()
            }

            if let image = ModeBarView.symbol(choice.symbol) {
                image.draw(in: NSRect(
                    x: rect.midX - image.size.width / 2,
                    y: rect.maxY - image.size.height - 8,
                    width: image.size.width,
                    height: image.size.height
                ))
            }

            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.white,
            ]
            let text = choice.title as NSString
            let size = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.minY + 6), withAttributes: attributes)
        }
    }
}
