import AppKit
import UniformTypeIdentifiers


/// Yakalanmış tek bir görüntü ve onunla yapılabilecekler.
struct Shot {
    let image: CGImage
    let capturedAt: Date
    /// Alan yakalamada Cocoa koordinatlarındaki dikdörtgen; "son alanı tekrarla" bunu kullanır.
    let sourceRect: CGRect?
    var savedURL: URL?

    init(image: CGImage, sourceRect: CGRect? = nil, capturedAt: Date = Date()) {
        self.image = image
        self.sourceRect = sourceRect
        self.capturedAt = capturedAt
    }

    var pixelSize: CGSize { CGSize(width: image.width, height: image.height) }

    var nsImage: NSImage {
        NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    static func defaultFileName(at date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Cadre \(formatter.string(from: date))"
    }

    func data(format: ImageFormat) -> Data? {
        Shot.encode(image: image, format: format)
    }

    static func encode(image: CGImage, format: ImageFormat) -> Data? {
        let type: UTType
        switch format {
        case .png: type = .png
        case .jpg: type = .jpeg
        case .heic: type = .heic
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, type.identifier as CFString, 1, nil
        ) else { return nil }
        var options: [CFString: Any] = [:]
        if format == .jpg {
            options[kCGImageDestinationLossyCompressionQuality] = Settings.shared.jpegQuality
        }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    @discardableResult
    func copyToClipboard() -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard let data = data(format: .png) else { return false }
        pasteboard.setData(data, forType: .png)
        return true
    }

    /// Aynı saniyede iki yakalama olursa ad çakışmasın diye sayaç eklenir.
    func save(to directory: URL? = nil, format: ImageFormat? = nil) throws -> URL {
        let format = format ?? Settings.shared.format
        return try Shot.write(
            data: data(format: format),
            format: format,
            capturedAt: capturedAt,
            to: directory
        )
    }

    /// Kodlanmış veriyi diske yazar. Kodlama çağıran tarafta yapılır, böylece aynı
    /// görüntü pano ve geçmiş için ikinci kez kodlanmaz.
    static func write(
        data: Data?,
        format: ImageFormat,
        capturedAt: Date,
        to directory: URL? = nil
    ) throws -> URL {
        guard let data else {
            throw NSError(
                domain: "Cadre", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not encode the image."]
            )
        }
        let directory = directory ?? Settings.shared.saveDirectory

        let accessed = directory.startAccessingSecurityScopedResource()
        defer { if accessed { directory.stopAccessingSecurityScopedResource() } }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let base = Shot.defaultFileName(at: capturedAt)
        var url = directory.appendingPathComponent("\(base).\(format.fileExtension)")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(base) (\(counter)).\(format.fileExtension)")
            counter += 1
        }
        try data.write(to: url, options: .atomic)
        return url
    }
}
