import AppKit
import ScreenCaptureKit
import CoreGraphics

enum CaptureError: LocalizedError {
    case noContent
    case noDisplay
    case permissionDenied
    case emptyRegion

    var errorDescription: String? {
        switch self {
        case .noContent: return "Could not read the screen content."
        case .noDisplay: return "No display found to capture."
        case .permissionDenied: return "Screen recording permission denied. System Settings → Privacy & Security → Screen Recording."
        case .emptyRegion: return "The selected area is empty."
        }
    }
}

/// Yakalanabilir bir pencerenin ekrandaki yeri ve kimliği.
struct WindowTarget {
    let scWindow: SCWindow
    /// Cocoa ekran koordinatları (sol-alt orijin).
    let frame: CGRect
    let appName: String
    let title: String
}

/// ScreenCaptureKit üstündeki tek yakalama yüzeyi. Ekran, pencere ve dikdörtgen alan aynı yoldan geçer.
enum CaptureEngine {

    static func shareableContent() async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            throw CaptureError.permissionDenied
        }
    }

    /// Kendi pencerelerimiz yakalamaya karışmasın diye dışlanır.
    private static func ownWindowIDs() -> Set<CGWindowID> {
        Set(NSApp.windows.compactMap { window -> CGWindowID? in
            let number = window.windowNumber
            return number > 0 ? CGWindowID(number) : nil
        })
    }

    /// Ekran listesi kısa süre saklanır.
    ///
    /// `SCShareableContent` her çağrıda ekrandaki bütün pencereleri sayar. Elli pencerede
    /// bu 30 ms tutuyor ve yakalama yolunun ortasında duruyordu. Ekran düzeni değişince
    /// önbellek atılır, böylece bayat bir `SCDisplay` ile yakalama yapılmaz.
    private static let displayCacheLife: TimeInterval = 10

    nonisolated(unsafe) private static var cachedDisplays: [SCDisplay] = []
    nonisolated(unsafe) private static var cachedAt: CFAbsoluteTime = 0
    nonisolated(unsafe) private static var screenObserver: NSObjectProtocol?

    private static func startWatchingScreenChanges() {
        guard screenObserver == nil else { return }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            cachedDisplays = []
            cachedAt = 0
        }
    }

    static func displays() async throws -> [SCDisplay] {
        startWatchingScreenChanges()
        if !cachedDisplays.isEmpty, CFAbsoluteTimeGetCurrent() - cachedAt < displayCacheLife {
            return cachedDisplays
        }
        let content = try await shareableContent()
        guard !content.displays.isEmpty else { throw CaptureError.noDisplay }
        cachedDisplays = content.displays
        cachedAt = CFAbsoluteTimeGetCurrent()
        return content.displays
    }

    /// Ekran listesini önden alır. Seçim katmanı açılırken çağrılır, böylece kullanıcı
    /// fareyi bıraktığında liste hazır olur.
    static func warmDisplays() {
        Task.detached(priority: .userInitiated) { _ = try? await displays() }
    }

    /// ScreenCaptureKit ilk yakalamada arka planda hizmetini kurar ve bu 60 ms kadar sürer.
    /// Açılışta bir piksel yakalayarak o bedel kullanıcının ilk ekran görüntüsünden alınır.
    static func warmUpCapture() async {
        guard let display = try? await displays().first else { return }
        let region = CGRect(x: 0, y: 0, width: 2, height: 2)
        _ = try? await capture(display: display, region: region)
    }

    /// Ekrandaki pencereler, en üstteki başta. Kendi pencerelerimiz ve kabuk katmanı elenir.
    static func windowTargets() async throws -> [WindowTarget] {
        let content = try await shareableContent()
        let own = ownWindowIDs()
        return content.windows.compactMap { window in
            guard !own.contains(window.windowID) else { return nil }
            guard window.isOnScreen else { return nil }
            guard window.frame.width > 24, window.frame.height > 24 else { return nil }
            let appName = window.owningApplication?.applicationName ?? ""
            guard appName != "Cadre" else { return nil }
            // Masaüstü ve menü çubuğu Dock/Finder'ın pencereleri olarak gelir; hedef sayılmazlar.
            if appName == "Dock" { return nil }
            return WindowTarget(
                scWindow: window,
                frame: CoordinateSpace.cocoaRect(fromDisplayRect: window.frame),
                appName: appName,
                title: window.title ?? ""
            )
        }
    }

    static func capture(display: SCDisplay, region: CGRect? = nil) async throws -> CGImage {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        let scale = scaleFactor(for: display)

        if let region {
            guard region.width >= 1, region.height >= 1 else { throw CaptureError.emptyRegion }
            let bounds = CGSize(width: CGFloat(display.width), height: CGFloat(display.height))
            let aligned = CaptureEngine.alignToPointGrid(region, within: bounds)
            config.sourceRect = aligned
            config.width = Int((aligned.width * scale).rounded())
            config.height = Int((aligned.height * scale).rounded())
        } else {
            config.width = Int((CGFloat(display.width) * scale).rounded())
            config.height = Int((CGFloat(display.height) * scale).rounded())
        }

        config.showsCursor = Settings.shared.showCursor
        config.captureResolution = .best
        config.scalesToFit = false
        config.ignoreGlobalClipDisplay = true

        return try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )
    }

    static func capture(window: SCWindow) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = scaleFactor(forFrame: CoordinateSpace.cocoaRect(fromDisplayRect: window.frame))
        config.width = Int((window.frame.width * scale).rounded())
        config.height = Int((window.frame.height * scale).rounded())
        config.showsCursor = false
        config.captureResolution = .best
        config.scalesToFit = false
        // Gölge ve yuvarlak köşeler saydam kalsın.
        config.backgroundColor = .clear
        return try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )
    }

    /// Cocoa koordinatlarındaki bir dikdörtgeni, hangi ekrana düşüyorsa oradan yakalar.
    static func capture(cocoaRect rect: CGRect) async throws -> CGImage {
        guard rect.width >= 1, rect.height >= 1 else { throw CaptureError.emptyRegion }
        guard let screen = CoordinateSpace.screen(containing: rect) else { throw CaptureError.noDisplay }
        let displays = try await displays()
        guard let display = displays.first(where: { $0.displayID == CoordinateSpace.displayID(of: screen) })
            ?? displays.first
        else { throw CaptureError.noDisplay }

        let local = CoordinateSpace.displayRect(fromCocoaRect: rect, on: screen)
        return try await capture(display: display, region: local)
    }

    /// Alanı tam nokta sınırına oturtur ve ekranın içinde tutar.
    ///
    /// ScreenCaptureKit kesirli bir `sourceRect` aldığında görüntüyü yeniden örnekler ve
    /// sonuç bulanık çıkar. Fareyle yapılan seçim neredeyse her zaman kesirli koordinat
    /// verir, bu yüzden bulanıklık her yakalamada vardı.
    ///
    /// Ölçüm, aynı 800x600 alan, Laplace varyansı: tam sayı köşede 331, yarım nokta
    /// kaymış köşede 79, hizalamadan sonra 330. Yarım piksele oturtmak yetmez, çünkü
    /// ScreenCaptureKit alanı nokta çözünürlüğünde işler.
    ///
    /// Köşe en yakın noktaya yuvarlanır ve boyut korunur, böylece kullanıcının seçtiği
    /// alan büyümez. `integral` kullanmak alanı her kenardan bir nokta genişletiyordu.
    static func alignToPointGrid(_ rect: CGRect, within size: CGSize) -> CGRect {
        let width = max(1, rect.width.rounded())
        let height = max(1, rect.height.rounded())
        let x = min(max(0, rect.minX.rounded()), max(0, size.width - width))
        let y = min(max(0, rect.minY.rounded()), max(0, size.height - height))
        return CGRect(x: x, y: y, width: width, height: height)
    }

    static func scaleFactor(for display: SCDisplay) -> CGFloat {
        NSScreen.screens.first { CoordinateSpace.displayID(of: $0) == display.displayID }?
            .backingScaleFactor ?? 2
    }

    static func scaleFactor(forFrame frame: CGRect) -> CGFloat {
        CoordinateSpace.screen(containing: frame)?.backingScaleFactor ?? 2
    }
}
