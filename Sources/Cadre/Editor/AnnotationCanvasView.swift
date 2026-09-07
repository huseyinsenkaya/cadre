import AppKit
import Carbon.HIToolbox

/// Görüntüyü ve üstündeki açıklamaları gösteren tuval.
/// Açıklamalar görüntü piksel uzayında yaşar; ekrandaki ölçek yalnız çizime uygulanır.
final class AnnotationCanvasView: NSView, NSTextViewDelegate {

    private(set) var baseImage: CGImage
    private(set) var annotations: [Annotation] = []
    private var redoStack: [[Annotation]] = []
    private var undoStack: [[Annotation]] = []

    var tool: Tool = .arrow {
        didSet {
            guard tool != oldValue else { return }
            updateCursor()
            needsDisplay = true
            onChange?()
        }
    }
    var style = AnnotationStyle() { didSet { applyStyleToSelection() } }

    /// Görüntünün çevresine eklenen zemin. Açıklamalar yine görüntü uzayında durur.
    var background = CanvasBackground() {
        didSet {
            guard background != oldValue else { return }
            needsDisplay = true
            onChange?()
        }
    }

    var onChange: (() -> Void)?

    private var draft: Annotation?
    private var dragStart: CGPoint = .zero
    private var selectedID: UUID?
    private var moveOrigin: CGPoint?
    private var counterValue = 1
    private var cropRect: CGRect?
    private var textEditor: NSTextView?
    private var textRectInImage: CGRect?

    private let accent = NSColor(srgbRed: 0.35, green: 0.64, blue: 1.0, alpha: 1)

    init(image: CGImage) {
        self.baseImage = image
        super.init(frame: NSRect(x: 0, y: 0, width: image.width, height: image.height))
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    var imageSize: CGSize {
        CGSize(width: baseImage.width, height: baseImage.height)
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var hasCropSelection: Bool { cropRect != nil }

    // MARK: - Yerleşim

    /// Zeminle birlikte toplam boy. Zemin kapalıyken görüntünün kendi boyu.
    var canvasSize: CGSize {
        BackgroundRenderer.canvasSize(for: imageSize, style: background)
    }

    /// Zeminin tuval içindeki yeri: en-boy oranı korunur, büyütme yapılmaz.
    var canvasRect: CGRect {
        let available = bounds
        let size = canvasSize
        guard size.width > 0, size.height > 0 else { return available }
        let scale = min(available.width / size.width, available.height / size.height, 1)
        let scaled = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(
            x: ((available.width - scaled.width) / 2).rounded(),
            y: ((available.height - scaled.height) / 2).rounded(),
            width: scaled.width,
            height: scaled.height
        )
    }

    /// Görüntünün ekrandaki yeri. Açıklama koordinatları buna göre çevrilir.
    var imageRect: CGRect {
        let scale = displayScale
        let origin = BackgroundRenderer.imageOrigin(for: imageSize, style: background)
        let canvas = canvasRect
        return CGRect(
            x: canvas.minX + origin.x * scale,
            y: canvas.minY + origin.y * scale,
            width: imageSize.width * scale,
            height: imageSize.height * scale
        )
    }

    private var displayScale: CGFloat {
        max(0.0001, canvasRect.width / max(1, canvasSize.width))
    }

    private func toImage(_ point: CGPoint) -> CGPoint {
        let rect = imageRect
        let scale = displayScale
        return CGPoint(x: (point.x - rect.minX) / scale, y: (point.y - rect.minY) / scale)
    }

    private func toView(_ point: CGPoint) -> CGPoint {
        let rect = imageRect
        let scale = displayScale
        return CGPoint(x: rect.minX + point.x * scale, y: rect.minY + point.y * scale)
    }

    private func toView(_ rect: CGRect) -> CGRect {
        let scale = displayScale
        let origin = toView(rect.origin)
        return CGRect(x: origin.x, y: origin.y, width: rect.width * scale, height: rect.height * scale)
    }

    // MARK: - Çizim

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let rect = imageRect

        context.setFillColor(NSColor.black.withAlphaComponent(0.06).cgColor)
        context.fill(bounds)

        BackgroundRenderer.drawBackground(background, in: context, canvas: canvasRect)

        // Saydam alanlar görünsün diye görüntünün altına dama deseni serilir.
        if !background.enabled {
            drawCheckerboard(in: rect, context: context)
        }
        BackgroundRenderer.drawImage(
            baseImage, style: background, in: context, rect: rect, scale: displayScale
        )

        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: displayScale, y: displayScale)
        var visible = annotations
        if let draft { visible.append(draft) }
        AnnotationRenderer.draw(visible, base: baseImage, in: context, imageSize: imageSize)
        context.restoreGState()

        if let selectedID, let annotation = annotations.first(where: { $0.id == selectedID }) {
            let box = toView(annotation.boundingBox)
            context.setStrokeColor(accent.cgColor)
            context.setLineWidth(1)
            context.setLineDash(phase: 0, lengths: [4, 3])
            context.stroke(box)
            context.setLineDash(phase: 0, lengths: [])
        }

        if let cropRect {
            drawCropChrome(toView(cropRect), in: context)
        }
    }

    private func drawCheckerboard(in rect: CGRect, context: CGContext) {
        let side: CGFloat = 8
        context.saveGState()
        context.clip(to: rect)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(rect)
        context.setFillColor(NSColor(white: 0.9, alpha: 1).cgColor)
        var y = rect.minY
        var row = 0
        while y < rect.maxY {
            var x = rect.minX + (row.isMultiple(of: 2) ? 0 : side)
            while x < rect.maxX {
                context.fill(CGRect(x: x, y: y, width: side, height: side))
                x += side * 2
            }
            y += side
            row += 1
        }
        context.restoreGState()
    }

    private func drawCropChrome(_ rect: CGRect, in context: CGContext) {
        context.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
        context.saveGState()
        context.addRect(imageRect)
        context.addRect(rect)
        context.fillPath(using: .evenOdd)
        context.restoreGState()

        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(1)
        context.stroke(rect)

        // Üçte bir çizgileri kadraja yardım eder.
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.35).cgColor)
        context.beginPath()
        for index in 1...2 {
            let fraction = CGFloat(index) / 3
            context.move(to: CGPoint(x: rect.minX + rect.width * fraction, y: rect.minY))
            context.addLine(to: CGPoint(x: rect.minX + rect.width * fraction, y: rect.maxY))
            context.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * fraction))
            context.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * fraction))
        }
        context.strokePath()
    }

    private func updateCursor() {
        switch tool {
        case .select: NSCursor.arrow.set()
        case .text: NSCursor.iBeam.set()
        default: NSCursor.crosshair.set()
        }
    }

    // MARK: - Geçmiş

    private func pushHistory() {
        undoStack.append(annotations)
        redoStack.removeAll()
        if undoStack.count > 60 { undoStack.removeFirst() }
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(annotations)
        annotations = previous
        selectedID = nil
        needsDisplay = true
        onChange?()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(annotations)
        annotations = next
        selectedID = nil
        needsDisplay = true
        onChange?()
    }

    func clearAll() {
        guard !annotations.isEmpty else { return }
        pushHistory()
        annotations.removeAll()
        counterValue = 1
        selectedID = nil
        needsDisplay = true
        onChange?()
    }

    func deleteSelected() {
        guard let selectedID else { return }
        pushHistory()
        annotations.removeAll { $0.id == selectedID }
        self.selectedID = nil
        needsDisplay = true
        onChange?()
    }

    private func applyStyleToSelection() {
        guard let selectedID,
              let index = annotations.firstIndex(where: { $0.id == selectedID })
        else { needsDisplay = true; return }
        pushHistory()
        annotations[index].style = style
        needsDisplay = true
        onChange?()
    }

    // MARK: - Fare

    override func mouseDown(with event: NSEvent) {
        commitTextEditor()
        let viewPoint = convert(event.locationInWindow, from: nil)
        let point = toImage(viewPoint)
        dragStart = point

        switch tool {
        case .select:
            selectedID = annotations.last { $0.hitTest(point) }?.id
            moveOrigin = point
            needsDisplay = true

        case .counter:
            pushHistory()
            annotations.append(Annotation(shape: .counter(point, counterValue), style: style))
            counterValue += 1
            needsDisplay = true
            onChange?()

        case .text:
            beginTextEditing(at: point)

        case .crop:
            cropRect = CGRect(origin: point, size: .zero)
            needsDisplay = true

        case .pen, .highlighter:
            draft = Annotation(
                shape: tool == .pen ? .pen([point]) : .highlighter([point]),
                style: style
            )

        default:
            draft = Annotation(shape: shape(for: tool, from: point, to: point), style: style)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = clampToImage(toImage(convert(event.locationInWindow, from: nil)))

        switch tool {
        case .select:
            guard let selectedID, let moveOrigin,
                  let index = annotations.firstIndex(where: { $0.id == selectedID })
            else { return }
            let offset = CGSize(width: point.x - moveOrigin.x, height: point.y - moveOrigin.y)
            annotations[index].translate(by: offset)
            self.moveOrigin = point

        case .crop:
            cropRect = rect(from: dragStart, to: point)

        case .pen:
            if case .pen(var points) = draft?.shape {
                points.append(point)
                draft?.shape = .pen(points)
            }

        case .highlighter:
            if case .highlighter(var points) = draft?.shape {
                points.append(point)
                draft?.shape = .highlighter(points)
            }

        case .counter, .text:
            return

        default:
            let end = event.modifierFlags.contains(.shift)
                ? constrain(from: dragStart, to: point)
                : point
            draft?.shape = shape(for: tool, from: dragStart, to: end)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { needsDisplay = true }

        if tool == .select {
            if moveOrigin != nil, selectedID != nil { pushHistory(); onChange?() }
            moveOrigin = nil
            return
        }

        if tool == .crop {
            if let cropRect, cropRect.width < 4 || cropRect.height < 4 { self.cropRect = nil }
            onChange?()
            return
        }

        guard let draft else { return }
        self.draft = nil

        let box = draft.boundingBox
        let tooSmall = box.width < 3 && box.height < 3
        if case .pen(let points) = draft.shape, points.count < 2 { return }
        if tooSmall, case .counter = draft.shape {} else if tooSmall { return }

        pushHistory()
        annotations.append(draft)
        onChange?()
    }

    private func clampToImage(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(0, point.x), imageSize.width),
            y: min(max(0, point.y), imageSize.height)
        )
    }

    private func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    /// Shift basılıyken kare, daire ve 45 derecelik ok üretir.
    private func constrain(from a: CGPoint, to b: CGPoint) -> CGPoint {
        let dx = b.x - a.x
        let dy = b.y - a.y
        if tool == .arrow || tool == .line {
            let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
            let length = hypot(dx, dy)
            return CGPoint(x: a.x + cos(angle) * length, y: a.y + sin(angle) * length)
        }
        let side = max(abs(dx), abs(dy))
        return CGPoint(x: a.x + (dx < 0 ? -side : side), y: a.y + (dy < 0 ? -side : side))
    }

    private func shape(for tool: Tool, from: CGPoint, to: CGPoint) -> AnnotationShape {
        switch tool {
        case .arrow: return .arrow(from: from, to: to)
        case .line: return .line(from: from, to: to)
        case .rectangle: return .rectangle(rect(from: from, to: to))
        case .ellipse: return .ellipse(rect(from: from, to: to))
        case .blur: return .blur(rect(from: from, to: to))
        case .pixelate: return .pixelate(rect(from: from, to: to))
        case .spotlight: return .spotlight(rect(from: from, to: to))
        default: return .line(from: from, to: to)
        }
    }

    // MARK: - Yazı

    private func beginTextEditing(at point: CGPoint) {
        let defaultSize = CGSize(width: 260, height: style.fontSize * 1.8)
        let imageRectForText = CGRect(
            x: point.x,
            y: point.y - defaultSize.height,
            width: defaultSize.width,
            height: defaultSize.height
        )
        textRectInImage = imageRectForText

        let viewFrame = toView(imageRectForText)
        let editor = NSTextView(frame: viewFrame)
        editor.font = .systemFont(ofSize: style.fontSize * displayScale, weight: .semibold)
        editor.textColor = style.color
        editor.backgroundColor = NSColor.white.withAlphaComponent(0.85)
        editor.isRichText = false
        editor.delegate = self
        editor.wantsLayer = true
        editor.layer?.cornerRadius = 4
        editor.layer?.borderWidth = 1
        editor.layer?.borderColor = accent.cgColor
        editor.textContainerInset = NSSize(width: 3, height: 2)

        addSubview(editor)
        window?.makeFirstResponder(editor)
        textEditor = editor
    }

    /// Yazı kutusu kapanırken içindekiler kalıcı bir açıklamaya dönüşür.
    @discardableResult
    func commitTextEditor() -> Bool {
        guard let editor = textEditor, let rect = textRectInImage else { return false }
        let text = editor.string.trimmingCharacters(in: .whitespacesAndNewlines)
        editor.removeFromSuperview()
        textEditor = nil
        textRectInImage = nil
        reclaimKeyboard()

        guard !text.isEmpty else { return false }
        pushHistory()
        annotations.append(Annotation(shape: .text(rect, text), style: style))
        needsDisplay = true
        onChange?()
        return true
    }

    /// NSTextView Esc'yi kendi tamamlama paneli için yutar. Tuvalin iptal merdivenine bağlarız.
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        discardTextEditor()
        return true
    }

    func textDidChange(_ notification: Notification) {
        guard let editor = textEditor else { return }
        editor.sizeToFit()
        var frame = editor.frame
        frame.size.width = max(frame.width, 80)
        editor.frame = frame
    }

    // MARK: - Kırpma

    func applyCrop() {
        guard let cropRect else { return }
        let pixels = cropRect.integral.intersection(CGRect(origin: .zero, size: imageSize))
        guard pixels.width >= 2, pixels.height >= 2 else { return }

        // CGImage.cropping sol-üst orijinli beklediği için y ters çevrilir.
        let flipped = CGRect(
            x: pixels.minX,
            y: imageSize.height - pixels.maxY,
            width: pixels.width,
            height: pixels.height
        )
        guard let cropped = baseImage.cropping(to: flipped) else { return }

        pushHistory()
        baseImage = cropped
        let offset = CGSize(width: -pixels.minX, height: -pixels.minY)
        annotations = annotations.map { annotation in
            var moved = annotation
            moved.translate(by: offset)
            return moved
        }
        self.cropRect = nil
        tool = .select
        frame = NSRect(x: 0, y: 0, width: cropped.width, height: cropped.height)
        needsDisplay = true
        onChange?()
    }

    func cancelCrop() {
        cropRect = nil
        needsDisplay = true
        onChange?()
    }

    // MARK: - Birleştirme

    /// Verilen görüntüleri geçerli görüntünün altına ekler ve tek görüntü yapar.
    /// Genişlikler farklıysa en geniş olan esas alınır, dar olanlar ortalanır.
    func append(images: [CGImage]) {
        commitTextEditor()

        let spacing = CGFloat(Settings.shared.combineSpacing)
        let all = [baseImage] + images
        let width = all.map { CGFloat($0.width) }.max() ?? CGFloat(baseImage.width)
        let totalHeight = all.reduce(CGFloat(0)) { $0 + CGFloat($1.height) }
            + spacing * CGFloat(all.count - 1)

        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: Int(width), height: Int(totalHeight),
                bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else {
            Notifier.show("Could not combine the images.", isError: true)
            return
        }

        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: totalHeight))

        // CGContext sol-alt orijinlidir; sıra üstten aşağı olduğu için yukarıdan başlanır.
        var y = totalHeight
        for image in all {
            y -= CGFloat(image.height)
            let x = ((width - CGFloat(image.width)) / 2).rounded()
            context.draw(
                image,
                in: CGRect(x: x, y: y, width: CGFloat(image.width), height: CGFloat(image.height))
            )
            y -= spacing
        }

        guard let combined = context.makeImage() else { return }

        pushHistory()
        // Var olan görüntü yukarı kaydı; açıklamalar da aynı kadar kayar.
        let rise = totalHeight - CGFloat(baseImage.height)
        let shift = ((width - CGFloat(baseImage.width)) / 2).rounded()
        annotations = annotations.map { annotation in
            var moved = annotation
            moved.translate(by: CGSize(width: shift, height: rise))
            return moved
        }

        baseImage = combined
        frame = NSRect(x: 0, y: 0, width: combined.width, height: combined.height)
        needsDisplay = true
        onChange?()
    }

    // MARK: - Klavye

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_Delete, kVK_ForwardDelete:
            deleteSelected()
        case kVK_Escape:
            cancelOneStep()
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if cropRect != nil { applyCrop() }
        default:
            super.keyDown(with: event)
        }
    }

    /// Esc her basışta bir adımı geri alır: metin kutusu, kırpma, seçim, araç.
    /// Araç en sonda bırakılır. Bırakılmazsa sonraki tıklama istenmeyen bir açıklama çizer.
    private func cancelOneStep() {
        if textEditor != nil {
            discardTextEditor()
        } else if cropRect != nil {
            cancelCrop()
        } else if selectedID != nil {
            selectedID = nil
            needsDisplay = true
        } else if tool != .select {
            tool = .select
        }
    }

    private func discardTextEditor() {
        textEditor?.removeFromSuperview()
        textEditor = nil
        textRectInImage = nil
        reclaimKeyboard()
        needsDisplay = true
    }

    /// Yazı kutusu ilk yanıtlayıcıyı alır. Geri vermezsek Esc ve Delete kimseye ulaşmaz.
    private func reclaimKeyboard() {
        window?.makeFirstResponder(self)
    }

    // MARK: - Dışa aktarma

    func flattenedImage() -> CGImage? {
        commitTextEditor()
        guard background.enabled else {
            return AnnotationRenderer.flatten(base: baseImage, annotations: annotations)
        }
        return BackgroundRenderer.flatten(
            image: baseImage, style: background, annotations: annotations
        )
    }
}
