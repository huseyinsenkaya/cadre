import AppKit

/// `.cadre` proje dosyası: taban görüntü, açıklamalar ve zemin bir arada.
///
/// Dışa aktarılan PNG düzleştirilmiştir, geri alınamaz. Proje dosyası açıklamaları
/// ayrı tutar, bu yüzden bir hafta sonra oku değiştirilebilir ya da silinebilir.
struct CadreDocument: Codable {

    static let fileExtension = "cadre"
    private static let currentVersion = 1

    var version = CadreDocument.currentVersion
    var imageData: Data
    var annotations: [StoredAnnotation]
    var background: StoredBackground

    // MARK: - Kurulum

    init(image: CGImage, annotations: [Annotation], background: CanvasBackground) throws {
        guard let data = Shot.encode(image: image, format: .png) else {
            throw NSError(domain: "Cadre", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "Could not encode the image."])
        }
        self.imageData = data
        self.annotations = annotations.map(StoredAnnotation.init)
        self.background = StoredBackground(background)
    }

    func image() -> CGImage? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    func restoredAnnotations() -> [Annotation] {
        annotations.compactMap { $0.annotation() }
    }

    // MARK: - Disk

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    static func read(from url: URL) throws -> CadreDocument {
        let data = try Data(contentsOf: url)
        let document = try JSONDecoder().decode(CadreDocument.self, from: data)
        guard document.version <= currentVersion else {
            throw NSError(domain: "Cadre", code: 11, userInfo: [
                NSLocalizedDescriptionKey: "This project file belongs to a newer version of Cadre."
            ])
        }
        return document
    }
}

// MARK: - Saklanabilir karşılıklar

struct StoredColor: Codable {
    var red: Double, green: Double, blue: Double, alpha: Double

    init(_ color: NSColor) {
        let rgb = color.usingColorSpace(.sRGB) ?? .black
        red = Double(rgb.redComponent)
        green = Double(rgb.greenComponent)
        blue = Double(rgb.blueComponent)
        alpha = Double(rgb.alphaComponent)
    }

    var color: NSColor {
        NSColor(srgbRed: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: CGFloat(alpha))
    }
}

struct StoredStyle: Codable {
    var color: StoredColor
    var lineWidth: Double
    var fontSize: Double
    var filled: Bool
    var textPreset: String
    var dim: Double

    init(_ style: AnnotationStyle) {
        color = StoredColor(style.color)
        lineWidth = Double(style.lineWidth)
        fontSize = Double(style.fontSize)
        filled = style.filled
        textPreset = style.textPreset.rawValue
        dim = Double(style.dim)
    }

    var style: AnnotationStyle {
        var result = AnnotationStyle()
        result.color = color.color
        result.lineWidth = CGFloat(lineWidth)
        result.fontSize = CGFloat(fontSize)
        result.filled = filled
        result.textPreset = TextPreset(rawValue: textPreset) ?? .plain
        result.dim = CGFloat(dim)
        return result
    }
}

struct StoredAnnotation: Codable {
    /// Şekli ayıran etiket. Yeni şekil eklenirken bu adlar değişmemeli.
    var kind: String
    var style: StoredStyle
    var rect: CGRect?
    var from: CGPoint?
    var to: CGPoint?
    var points: [CGPoint]?
    var text: String?
    var number: Int?

    init(_ annotation: Annotation) {
        style = StoredStyle(annotation.style)
        switch annotation.shape {
        case .arrow(let a, let b): kind = "arrow"; from = a; to = b
        case .line(let a, let b): kind = "line"; from = a; to = b
        case .rectangle(let r): kind = "rectangle"; rect = r
        case .ellipse(let r): kind = "ellipse"; rect = r
        case .blur(let r): kind = "blur"; rect = r
        case .pixelate(let r): kind = "pixelate"; rect = r
        case .spotlight(let r): kind = "spotlight"; rect = r
        case .pen(let p): kind = "pen"; points = p
        case .highlighter(let p): kind = "highlighter"; points = p
        case .text(let r, let s): kind = "text"; rect = r; text = s
        case .counter(let p, let n): kind = "counter"; from = p; number = n
        }
    }

    func annotation() -> Annotation? {
        let shape: AnnotationShape
        switch kind {
        case "arrow":
            guard let from, let to else { return nil }
            shape = .arrow(from: from, to: to)
        case "line":
            guard let from, let to else { return nil }
            shape = .line(from: from, to: to)
        case "rectangle":
            guard let rect else { return nil }
            shape = .rectangle(rect)
        case "ellipse":
            guard let rect else { return nil }
            shape = .ellipse(rect)
        case "blur":
            guard let rect else { return nil }
            shape = .blur(rect)
        case "pixelate":
            guard let rect else { return nil }
            shape = .pixelate(rect)
        case "spotlight":
            guard let rect else { return nil }
            shape = .spotlight(rect)
        case "pen":
            guard let points else { return nil }
            shape = .pen(points)
        case "highlighter":
            guard let points else { return nil }
            shape = .highlighter(points)
        case "text":
            guard let rect, let text else { return nil }
            shape = .text(rect, text)
        case "counter":
            guard let from, let number else { return nil }
            shape = .counter(from, number)
        default:
            return nil
        }
        return Annotation(shape: shape, style: style.style)
    }
}

struct StoredBackground: Codable {
    var enabled: Bool
    var padding: Double
    var cornerRadius: Double
    var shadowRadius: Double
    var shadowOpacity: Double
    var aspect: String
    var fillKind: String
    var primary: StoredColor
    var secondary: StoredColor?

    init(_ background: CanvasBackground) {
        enabled = background.enabled
        padding = Double(background.padding)
        cornerRadius = Double(background.cornerRadius)
        shadowRadius = Double(background.shadowRadius)
        shadowOpacity = Double(background.shadowOpacity)
        aspect = background.aspect.rawValue
        switch background.fill {
        case .solid(let color):
            fillKind = "solid"
            primary = StoredColor(color)
        case .gradient(let start, let end):
            fillKind = "gradient"
            primary = StoredColor(start)
            secondary = StoredColor(end)
        }
    }

    var background: CanvasBackground {
        var result = CanvasBackground()
        result.enabled = enabled
        result.padding = CGFloat(padding)
        result.cornerRadius = CGFloat(cornerRadius)
        result.shadowRadius = CGFloat(shadowRadius)
        result.shadowOpacity = CGFloat(shadowOpacity)
        result.aspect = AspectPreset(rawValue: aspect) ?? .original
        if fillKind == "gradient", let secondary {
            result.fill = .gradient(primary.color, secondary.color)
        } else {
            result.fill = .solid(primary.color)
        }
        return result
    }
}
