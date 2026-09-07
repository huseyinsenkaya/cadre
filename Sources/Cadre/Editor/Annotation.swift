import AppKit
import CoreImage

enum Tool: String, CaseIterable {
    case select, arrow, line, rectangle, ellipse, pen, highlighter, text, counter, blur, pixelate, spotlight, crop

    var title: String {
        switch self {
        case .select: return "Select"
        case .arrow: return "Arrow"
        case .line: return "Line"
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .pen: return "Pen"
        case .highlighter: return "Highlighter"
        case .text: return "Text"
        case .counter: return "Counter"
        case .blur: return "Blur"
        case .pixelate: return "Pixelate"
        case .spotlight: return "Spotlight"
        case .crop: return "Crop"
        }
    }

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .arrow: return "arrow.up.right"
        case .line: return "line.diagonal"
        case .rectangle: return "rectangle"
        case .ellipse: return "oval"
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .text: return "textformat"
        case .counter: return "1.circle"
        case .blur: return "drop"
        case .pixelate: return "squareshape.split.3x3"
        case .spotlight: return "flashlight.on.fill"
        case .crop: return "crop"
        }
    }

    /// Sürükleyerek dikdörtgen kuran araçlar.
    var isRectangular: Bool {
        switch self {
        case .rectangle, .ellipse, .blur, .pixelate, .spotlight, .crop, .text: return true
        default: return false
        }
    }
}

/// Yazı kutusunun görünümü. Aynı metin farklı zeminlerde okunur kalsın diye biçim değişir.
enum TextPreset: String, CaseIterable {
    case plain, outlined, filled, highlighted, bubble, badge, shadowed

    var title: String {
        switch self {
        case .plain: return "Plain"
        case .outlined: return "Outlined"
        case .filled: return "Filled"
        case .highlighted: return "Highlighted"
        case .bubble: return "Bubble"
        case .badge: return "Badge"
        case .shadowed: return "Shadowed"
        }
    }
}

extension AnnotationStyle {
    /// Spot ışığı deliğinin köşe yuvarlaması.
    var cornerRadiusForSpotlight: CGFloat { 10 }
}

extension NSColor {
    /// Dolgu üstünde okunur kalan yazı rengi.
    var readableForeground: NSColor {
        guard let rgb = usingColorSpace(.sRGB) else { return .white }
        let luminance = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        return luminance > 0.6 ? .black : .white
    }
}

struct AnnotationStyle: Equatable {
    var color: NSColor = NSColor(srgbRed: 0.95, green: 0.26, blue: 0.31, alpha: 1)
    var lineWidth: CGFloat = 4
    var fontSize: CGFloat = 26
    var filled: Bool = false
    var textPreset: TextPreset = .plain
    /// Spot ışığında dışarıda kalan alanın karartma oranı.
    var dim: CGFloat = 0.55
}

enum AnnotationShape {
    case arrow(from: CGPoint, to: CGPoint)
    case line(from: CGPoint, to: CGPoint)
    case rectangle(CGRect)
    case ellipse(CGRect)
    case pen([CGPoint])
    case highlighter([CGPoint])
    case text(CGRect, String)
    case counter(CGPoint, Int)
    case blur(CGRect)
    case pixelate(CGRect)
    case spotlight(CGRect)
}

/// Tek bir açıklama. Koordinatlar görüntünün piksel uzayındadır (sol-alt orijin),
/// böylece dışa aktarma ekrandaki ölçekten bağımsız olarak birebir çıkar.
struct Annotation: Identifiable {
    let id = UUID()
    var shape: AnnotationShape
    var style: AnnotationStyle

    var boundingBox: CGRect {
        switch shape {
        case .arrow(let a, let b), .line(let a, let b):
            return CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                          width: abs(b.x - a.x), height: abs(b.y - a.y))
                .insetBy(dx: -style.lineWidth * 2, dy: -style.lineWidth * 2)
        case .rectangle(let rect), .ellipse(let rect), .blur(let rect), .pixelate(let rect), .spotlight(let rect):
            return rect.insetBy(dx: -style.lineWidth, dy: -style.lineWidth)
        case .text(let rect, _):
            return rect
        case .counter(let point, _):
            let radius = style.fontSize
            return CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        case .pen(let points), .highlighter(let points):
            guard let first = points.first else { return .zero }
            var box = CGRect(origin: first, size: .zero)
            for point in points.dropFirst() {
                box = box.union(CGRect(origin: point, size: .zero))
            }
            return box.insetBy(dx: -style.lineWidth, dy: -style.lineWidth)
        }
    }

    func hitTest(_ point: CGPoint) -> Bool {
        boundingBox.insetBy(dx: -6, dy: -6).contains(point)
    }

    mutating func translate(by offset: CGSize) {
        func move(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x + offset.width, y: p.y + offset.height)
        }
        switch shape {
        case .arrow(let a, let b): shape = .arrow(from: move(a), to: move(b))
        case .line(let a, let b): shape = .line(from: move(a), to: move(b))
        case .rectangle(let r): shape = .rectangle(r.offsetBy(dx: offset.width, dy: offset.height))
        case .ellipse(let r): shape = .ellipse(r.offsetBy(dx: offset.width, dy: offset.height))
        case .blur(let r): shape = .blur(r.offsetBy(dx: offset.width, dy: offset.height))
        case .pixelate(let r): shape = .pixelate(r.offsetBy(dx: offset.width, dy: offset.height))
        case .spotlight(let r): shape = .spotlight(r.offsetBy(dx: offset.width, dy: offset.height))
        case .text(let r, let s): shape = .text(r.offsetBy(dx: offset.width, dy: offset.height), s)
        case .counter(let p, let n): shape = .counter(move(p), n)
        case .pen(let points): shape = .pen(points.map(move))
        case .highlighter(let points): shape = .highlighter(points.map(move))
        }
    }
}
