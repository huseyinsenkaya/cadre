import AppKit

enum AspectPreset: String, CaseIterable {
    case original, square, wide16x9, standard4x3, photo3x2

    var title: String {
        switch self {
        case .original: return "Original"
        case .square: return "1:1"
        case .wide16x9: return "16:9"
        case .standard4x3: return "4:3"
        case .photo3x2: return "3:2"
        }
    }

    var ratio: CGFloat? {
        switch self {
        case .original: return nil
        case .square: return 1
        case .wide16x9: return 16.0 / 9.0
        case .standard4x3: return 4.0 / 3.0
        case .photo3x2: return 3.0 / 2.0
        }
    }
}

enum BackgroundFill: Equatable {
    case solid(NSColor)
    case gradient(NSColor, NSColor)
}

/// Görüntünün çevresine eklenen zemin: boşluk, köşe yuvarlaması, gölge ve dolgu.
struct CanvasBackground: Equatable {
    var enabled = false
    /// Görüntü genişliğine oranla boşluk. 0.06 dar, 0.20 geniş.
    var padding: CGFloat = 0.08
    var cornerRadius: CGFloat = 12
    var shadowRadius: CGFloat = 28
    var shadowOpacity: CGFloat = 0.32
    var fill: BackgroundFill = .gradient(
        NSColor(srgbRed: 0.38, green: 0.49, blue: 0.92, alpha: 1),
        NSColor(srgbRed: 0.68, green: 0.42, blue: 0.87, alpha: 1)
    )
    var aspect: AspectPreset = .original

    static let presets: [(name: String, fill: BackgroundFill)] = [
        ("Violet", .gradient(NSColor(srgbRed: 0.38, green: 0.49, blue: 0.92, alpha: 1),
                          NSColor(srgbRed: 0.68, green: 0.42, blue: 0.87, alpha: 1))),
        ("Dawn", .gradient(NSColor(srgbRed: 0.99, green: 0.62, blue: 0.36, alpha: 1),
                            NSColor(srgbRed: 0.95, green: 0.33, blue: 0.46, alpha: 1))),
        ("Ocean", .gradient(NSColor(srgbRed: 0.16, green: 0.66, blue: 0.78, alpha: 1),
                            NSColor(srgbRed: 0.14, green: 0.38, blue: 0.62, alpha: 1))),
        ("Forest", .gradient(NSColor(srgbRed: 0.20, green: 0.62, blue: 0.44, alpha: 1),
                            NSColor(srgbRed: 0.10, green: 0.35, blue: 0.30, alpha: 1))),
        ("Charcoal", .solid(NSColor(srgbRed: 0.11, green: 0.12, blue: 0.14, alpha: 1))),
        ("Paper", .solid(NSColor(srgbRed: 0.96, green: 0.95, blue: 0.93, alpha: 1))),
    ]
}

/// Zemini çizen tek yer. Tuval ve dışa aktarma aynı hesabı kullanır.
enum BackgroundRenderer {

    /// Zeminle birlikte toplam görüntü boyu.
    static func canvasSize(for imageSize: CGSize, style: CanvasBackground) -> CGSize {
        guard style.enabled else { return imageSize }

        let inset = (imageSize.width * style.padding).rounded()
        var width = imageSize.width + inset * 2
        var height = imageSize.height + inset * 2

        if let ratio = style.aspect.ratio {
            if width / height < ratio {
                width = (height * ratio).rounded()
            } else {
                height = (width / ratio).rounded()
            }
        }
        return CGSize(width: width, height: height)
    }

    /// Görüntünün zemin içindeki sol-alt köşesi.
    static func imageOrigin(for imageSize: CGSize, style: CanvasBackground) -> CGPoint {
        guard style.enabled else { return .zero }
        let canvas = canvasSize(for: imageSize, style: style)
        return CGPoint(
            x: ((canvas.width - imageSize.width) / 2).rounded(),
            y: ((canvas.height - imageSize.height) / 2).rounded()
        )
    }

    static func drawBackground(_ style: CanvasBackground, in context: CGContext, canvas: CGRect) {
        guard style.enabled else { return }
        context.saveGState()
        switch style.fill {
        case .solid(let color):
            context.setFillColor(color.cgColor)
            context.fill(canvas)
        case .gradient(let start, let end):
            let space = CGColorSpaceCreateDeviceRGB()
            let colors = [start.cgColor, end.cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
                context.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: canvas.minX, y: canvas.maxY),
                    end: CGPoint(x: canvas.maxX, y: canvas.minY),
                    options: []
                )
            }
        }
        context.restoreGState()
    }

    /// Görüntüyü yuvarlatılmış köşe ve gölgeyle zeminin üstüne çizer.
    static func drawImage(
        _ image: CGImage,
        style: CanvasBackground,
        in context: CGContext,
        rect: CGRect,
        scale: CGFloat
    ) {
        guard style.enabled else {
            context.draw(image, in: rect)
            return
        }

        let radius = style.cornerRadius * scale
        let path = CGPath(
            roundedRect: rect,
            cornerWidth: min(radius, rect.width / 2),
            cornerHeight: min(radius, rect.height / 2),
            transform: nil
        )

        if style.shadowOpacity > 0 {
            context.saveGState()
            context.setShadow(
                offset: CGSize(width: 0, height: -style.shadowRadius * scale * 0.25),
                blur: style.shadowRadius * scale,
                color: NSColor.black.withAlphaComponent(style.shadowOpacity).cgColor
            )
            context.setFillColor(NSColor.black.cgColor)
            context.addPath(path)
            context.fillPath()
            context.restoreGState()
        }

        context.saveGState()
        context.addPath(path)
        context.clip()
        context.draw(image, in: rect)
        context.restoreGState()
    }

    /// Zemin uygulanmış tek bir görüntü üretir. Dışa aktarma bunu kullanır.
    static func flatten(image: CGImage, style: CanvasBackground, annotations: [Annotation]) -> CGImage? {
        let imageSize = CGSize(width: image.width, height: image.height)
        let canvas = canvasSize(for: imageSize, style: style)
        let origin = imageOrigin(for: imageSize, style: style)

        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: Int(canvas.width), height: Int(canvas.height),
                bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        let canvasRect = CGRect(origin: .zero, size: canvas)
        drawBackground(style, in: context, canvas: canvasRect)

        let imageRect = CGRect(origin: origin, size: imageSize)
        drawImage(image, style: style, in: context, rect: imageRect, scale: 1)

        // Açıklamalar görüntü uzayında durur; zeminin kaydırdığı kadar ötelenir.
        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y)
        AnnotationRenderer.draw(annotations, base: image, in: context, imageSize: imageSize)
        context.restoreGState()

        return context.makeImage()
    }
}
