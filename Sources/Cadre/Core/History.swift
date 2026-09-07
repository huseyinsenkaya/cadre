import AppKit

enum ShotKind: String, Codable, CaseIterable {
    case screenshot
    case recording

    var title: String {
        switch self {
        case .screenshot: return "Screenshots"
        case .recording: return "Recordings"
        }
    }
}

struct HistoryEntry: Codable {
    let id: UUID
    let kind: ShotKind
    let capturedAt: Date
    /// Görüntü geçmişinde önizleme dosyası, kayıtta videonun kendisi.
    let fileName: String
    let width: Int
    let height: Int
    /// Kayıtta ve diske kaydedilmiş görüntüde kullanıcının dosyası nerede duruyor.
    var originalPath: String?
}

/// Son yakalamalar. Bellekte değil diskte durur, uygulama kapansa da kalır.
@MainActor
final class History {

    static let shared = History()
    static let didChange = Notification.Name("cadre.history.changed")

    /// CleanShot'ın bir aylık saklama süresiyle aynı ölçü.
    private let retention: TimeInterval = 30 * 24 * 60 * 60
    private let limit = 200

    private(set) var entries: [HistoryEntry] = []

    /// Arka plandaki kodlama görevi geçmiş dosyasını buraya yazar.
    nonisolated let directory: URL
    private let indexURL: URL

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = support.appendingPathComponent("Cadre/history", isDirectory: true)
        indexURL = directory.appendingPathComponent("index.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        load()
        prune()
    }

    // MARK: - Okuma

    func entries(of kind: ShotKind?) -> [HistoryEntry] {
        guard let kind else { return entries }
        return entries.filter { $0.kind == kind }
    }

    func fileURL(for entry: HistoryEntry) -> URL {
        directory.appendingPathComponent(entry.fileName)
    }

    func image(for entry: HistoryEntry) -> CGImage? {
        guard entry.kind == .screenshot else { return nil }
        let url = fileURL(for: entry)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    func thumbnail(for entry: HistoryEntry, width: CGFloat) -> NSImage? {
        let url = fileURL(for: entry)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: width * 2,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        let height = width * CGFloat(image.height) / CGFloat(max(1, image.width))
        return NSImage(cgImage: image, size: NSSize(width: width, height: height))
    }

    // MARK: - Yazma

    func add(_ shot: Shot) {
        guard let data = Shot.encode(image: shot.image, format: .png) else { return }
        let id = UUID()
        let fileName = "\(id.uuidString).png"
        try? data.write(to: directory.appendingPathComponent(fileName), options: .atomic)
        record(id: id, fileName: fileName, shot: shot)
    }

    /// Önizleme dosyası arka planda yazıldıktan sonra dizin girdisini ekler.
    /// Kodlamayı ve disk yazmayı ana iş parçacığından ayırmak için ikiye bölünmüştür.
    func record(id: UUID, fileName: String, shot: Shot) {
        let entry = HistoryEntry(
            id: id,
            kind: .screenshot,
            capturedAt: shot.capturedAt,
            fileName: fileName,
            width: shot.image.width,
            height: shot.image.height,
            originalPath: shot.savedURL?.path
        )
        insert(entry)
    }

    /// Kayıt için önizleme olarak videonun ilk karesi saklanır.
    func addRecording(videoURL: URL, poster: CGImage?, size: CGSize) {
        let id = UUID()
        let fileName = "\(id.uuidString).png"
        if let poster, let data = Shot.encode(image: poster, format: .png) {
            try? data.write(to: directory.appendingPathComponent(fileName), options: .atomic)
        }
        let entry = HistoryEntry(
            id: id,
            kind: .recording,
            capturedAt: Date(),
            fileName: fileName,
            width: Int(size.width),
            height: Int(size.height),
            originalPath: videoURL.path
        )
        insert(entry)
    }

    private func insert(_ entry: HistoryEntry) {
        entries.insert(entry, at: 0)
        if entries.count > limit {
            for old in entries.suffix(from: limit) { removeFile(of: old) }
            entries.removeLast(entries.count - limit)
        }
        save()
        NotificationCenter.default.post(name: History.didChange, object: nil)
    }

    func remove(_ entry: HistoryEntry) {
        removeFile(of: entry)
        entries.removeAll { $0.id == entry.id }
        save()
        NotificationCenter.default.post(name: History.didChange, object: nil)
    }

    func clear() {
        for entry in entries { removeFile(of: entry) }
        entries.removeAll()
        save()
        NotificationCenter.default.post(name: History.didChange, object: nil)
    }

    private func removeFile(of entry: HistoryEntry) {
        try? FileManager.default.removeItem(at: fileURL(for: entry))
    }

    /// Saklama süresi dolmuş kayıtlar açılışta silinir.
    private func prune() {
        let cutoff = Date().addingTimeInterval(-retention)
        let expired = entries.filter { $0.capturedAt < cutoff }
        guard !expired.isEmpty else { return }
        for entry in expired { removeFile(of: entry) }
        entries.removeAll { $0.capturedAt < cutoff }
        save()
    }

    // MARK: - Disk

    private func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = (try? decoder.decode([HistoryEntry].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}

enum TempFiles {
    /// Sürükleyip bırakma ve "paylaş" için diskte geçici bir kopya gerekir.
    static func write(_ shot: Shot) -> URL? {
        let format = Settings.shared.format
        guard let data = shot.data(format: format) else { return nil }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Cadre", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(
            "\(Shot.defaultFileName(at: shot.capturedAt)).\(format.fileExtension)"
        )
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}
