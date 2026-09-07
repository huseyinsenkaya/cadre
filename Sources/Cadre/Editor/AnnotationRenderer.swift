import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Açıklamaları çizen tek yer. Ekrandaki tuval ve dışa aktarma aynı fonksiyondan geçer,
/// böylece kaydedilen dosya ekranda görülenin aynısı olur.
enum AnnotationRenderer {

    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    static func draw(
        _ annotations: [Annotation],
        base: CGImage,
        in context: CGContext,
        imageSize: CGSize
    ) {
        for annotation in annotations {
            draw(annotation, base: base, in: context, imageSize: imageSize)
        }
    }

    static func draw(
        _ annotation: Annotation,
        base: CGImage,
        in context: CGContext,
        imageSize: CGSize
    ) {
        let style = annotation.style
        context.saveGState()
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setStrokeColor(style.color.cgColor)
        context.setFillColor(style.color.cgColor)
        context.setLineWidth(style.lineWidth)

        switch annotation.shape {
        case .line(let from, let to):
            context.beginPath()
            context.move(to: from)
            context.addLine(to: to)
            context.strokePath()

        case .arrow(let from, let to):
            drawArrow(from: from, to: to, style: style, in: context)

        case .rectangle(let rect):
            if style.filled {
                context.fill(rect)
            } else {
                context.stroke(rect.insetBy(dx: style.lineWidth / 2, dy: style.lineWidth / 2))
            }

        case .ellipse(let rect):
            if style.filled {
                context.fillEllipse(in: rect)
            } else {
                context.strokeEllipse(in: rect.insetBy(dx: style.lineWidth / 2, dy: style.lineWidth / 2))
            }

        case .pen(let points):
            strokePath(points, in: context)

        case .highlighter(let points):
            context.setBlendMode(.multiply)
            context.setStrokeColor(style.color.withAlphaComponent(0.35).cgColor)
            context.setLineWidth(style.lineWidth * 4)
            context.setLineCap(.square)
            strokePath(points, in: context)

        case .text(let rect, let string):
            drawText(string, in: rect, style: style, context: context)

        case .counter(let center, let number):
            drawCounter(number, at: center, style: style, in: context)

        case .blur(let rect):
            drawFiltered(rect, base: base, imageSize: imageSize, in: context, pixelate: false)

        case .pixelate(let rect):
            drawFiltered(rect, base: base, imageSize: imageSize, in: context, pixelate: true)

        case .spotlight(let rect):
            drawSpotlight(rect, style: style, in: context, imageSize: imageSize)
        }

        context.restoreGState()
    }

    /// Seçilen alan dışında kalan her yeri karartır. Dikkati tek noktaya toplar.
    private static func drawSpotlight(
        _ rect: CGRect,
        style: AnnotationStyle,
        in context: CGContext,
        imageSize: CGSize
    ) {
        let full = CGRect(origin: .zero, size: imageSize)
        let hole = rect.intersection(full)
        guard hole.width >= 2, hole.height >= 2 else { return }

        let radius = min(style.cornerRadiusForSpotlight, hole.width / 2, hole.height / 2)
        let holePath = CGPath(
            roundedRect: hole, cornerWidth: radius, cornerHeight: radius, transform: nil
        )

        context.saveGState()
        context.setFillColor(NSColor.black.withAlphaComponent(style.dim).cgColor)
        context.addRect(full)
        context.addPath(holePath)
        context.fillPath(using: .evenOdd)
        context.restoreGState()

        context.saveGState()
        context.setStrokeColor(style.color.withAlphaComponent(0.9).cgColor)
        context.setLineWidth(max(1, style.lineWidth * 0.5))
        context.addPath(holePath)
        context.strokePath()
        context.restoreGState()
    }

    private static func strokePath(_ points: [CGPoint], in context: CGContext) {
        guard let first = points.first else { return }
        context.beginPath()
        context.move(to: first)
        if points.count == 1 {
            context.addLine(to: CGPoint(x: first.x + 0.1, y: first.y))
        }
        // İki nokta arasını orta noktadan geçen eğriyle bağlamak eli titrek çizgiyi yumuşatır.
        for index in 1..<max(1, points.count) {
            let point = points[index]
            let previous = points[index - 1]
            let mid = CGPoint(x: (previous.x + point.x) / 2, y: (previous.y + point.y) / 2)
            context.addQuadCurve(to: mid, control: previous)
        }
        if let last = points.last { context.addLine(to: last) }
        context.strokePath()
    }

    private static func drawArrow(from: CGPoint, to: CGPoint, style: AnnotationStyle, in context: CGContext) {
        let angle = atan2(to.y - from.y, to.x - from.x)
        let headLength = max(14, style.lineWidth * 4.2)
        let headWidth = max(11, style.lineWidth * 3.4)

        // Gövde uç üçgeninin altında kalmasın diye kısaltılır.
        let shaftEnd = CGPoint(
            x: to.x - cos(angle) * headLength * 0.72,
            y: to.y - sin(angle) * headLength * 0.72
        )
        context.beginPath()
        context.move(to: from)
        context.addLine(to: shaftEnd)
        context.strokePath()

        let left = CGPoint(
            x: to.x - cos(angle) * headLength + cos(angle + .pi / 2) * headWidth,
            y: to.y - sin(angle) * headLength + sin(angle + .pi / 2) * headWidth
        )
        let right = CGPoint(
            x: to.x - cos(angle) * headLength + cos(angle - .pi / 2) * headWidth,
            y: to.y - sin(angle) * headLength + sin(angle - .pi / 2) * headWidth
        )
        context.beginPath()
        context.move(to: to)
        context.addLine(to: left)
        context.addLine(to: right)
        context.closePath()
        context.fillPath()
    }

    private static func drawText(_ string: String, in rect: CGRect, style: AnnotationStyle, context: CGContext) {
        guard !string.isEmpty else { return }

        let font = NSFont.systemFont(ofSize: style.fontSize, weight: .semibold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping

        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraph,
        ]

        let text = string as NSString
        let measured = text.boundingRect(
            with: CGSize(width: rect.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            attributes: [.font: font, .paragraphStyle: paragraph]
        )
        let inset: CGFloat = style.fontSize * 0.32
        // Metin kutusu üstten aşağı büyür; kutunun üst kenarı sabit kalsın.
        let box = CGRect(
            x: rect.minX,
            y: rect.maxY - measured.height,
            width: min(rect.width, measured.width + 2),
            height: measured.height
        )
        let plate = box.insetBy(dx: -inset, dy: -inset * 0.7)

        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics

        switch style.textPreset {
        case .plain:
            attributes[.foregroundColor] = style.color

        case .outlined:
            attributes[.foregroundColor] = style.color
            attributes[.strokeColor] = NSColor.white
            // Negatif kalınlık hem doldurur hem kontur çizer.
            attributes[.strokeWidth] = -3.0

        case .filled:
            style.color.setFill()
            NSBezierPath(roundedRect: plate, xRadius: 6, yRadius: 6).fill()
            attributes[.foregroundColor] = style.color.readableForeground

        case .highlighted:
            style.color.withAlphaComponent(0.4).setFill()
            NSBezierPath(rect: plate).fill()
            attributes[.foregroundColor] = NSColor.black

        case .bubble:
            NSColor.white.setFill()
            let bubble = NSBezierPath(roundedRect: plate, xRadius: 10, yRadius: 10)
            bubble.fill()
            style.color.setStroke()
            bubble.lineWidth = 2
            bubble.stroke()
            attributes[.foregroundColor] = style.color

        case .badge:
            style.color.setFill()
            NSBezierPath(roundedRect: plate, xRadius: plate.height / 2, yRadius: plate.height / 2).fill()
            attributes[.foregroundColor] = style.color.readableForeground

        case .shadowed:
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.75)
            shadow.shadowBlurRadius = 4
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            attributes[.shadow] = shadow
            attributes[.foregroundColor] = style.color
        }

        text.draw(with: box, options: [.usesLineFragmentOrigin], attributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawCounter(_ number: Int, at center: CGPoint, style: AnnotationStyle, in context: CGContext) {
        let radius = style.fontSize * 0.85
        let circle = CGRect(
            x: center.x - radius, y: center.y - radius,
            width: radius * 2, height: radius * 2
        )
        context.setFillColor(style.color.cgColor)
        context.fillEllipse(in: circle)
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(max(2, style.lineWidth * 0.5))
        context.strokeEllipse(in: circle.insetBy(dx: 1, dy: 1))

        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        let text = "\(number)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: radius * 1.15, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2),
            withAttributes: attributes
        )
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Bulanıklık ve pikselleştirme kaynağı taban görüntüdür; üstteki açıklamaları bulandırmaz.
    private static func drawFiltered(
        _ rect: CGRect,
        base: CGImage,
        imageSize: CGSize,
        in context: CGContext,
        pixelate: Bool
    ) {
        let clipped = rect.intersection(CGRect(origin: .zero, size: imageSize)).integral
        guard clipped.width >= 2, clipped.height >= 2 else { return }

        let input = CIImage(cgImage: base)
        let output: CIImage?

        if pixelate {
            let filter = CIFilter.pixellate()
            filter.inputImage = input
            filter.scale = Float(max(6, min(clipped.width, clipped.height) / 12))
            filter.center = CGPoint(x: clipped.midX, y: clipped.midY)
            output = filter.outputImage
        } else {
            // Kenarda saydamlığa düşmesin diye önce sonsuza uzatılır, sonra kırpılır.
            let filter = CIFilter.gaussianBlur()
            filter.inputImage = input.clampedToExtent()
            filter.radius = Float(max(8, min(clipped.width, clipped.height) / 8))
            output = filter.outputImage?.cropped(to: input.extent)
        }

        guard let output,
              let rendered = ciContext.createCGImage(output, from: clipped)
        else { return }

        context.saveGState()
        context.clip(to: clipped)
        context.draw(rendered, in: clipped)
        context.restoreGState()
    }

    /// Tuval ve dosya aynı çıktıyı üretsin diye dışa aktarma da bu yoldan geçer.
    static func flatten(base: CGImage, annotations: [Annotation]) -> CGImage? {
        let width = base.width
        let height = base.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        let full = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(base, in: full)
        draw(annotations, base: base, in: context, imageSize: full.size)
        return context.makeImage()
    }
}
