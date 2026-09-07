import AppKit
import CoreGraphics

/// macOS iki koordinat sistemi kullanır: Cocoa (sol-alt orijin, y yukarı) ve
/// CoreGraphics ekran uzayı (sol-üst orijin, y aşağı). ScreenCaptureKit ikincisini
/// ister, pencerelerimiz birincisinde yaşar. Çeviri tek yerde durur.
enum CoordinateSpace {

    /// Menü çubuğunu taşıyan ekran; CG uzayının orijini buranın sol üst köşesidir.
    static var primaryHeight: CGFloat {
        NSScreen.screens.first { $0.frame.origin == .zero }?.frame.height
            ?? NSScreen.main?.frame.height
            ?? 0
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) } ?? CGMainDisplayID()
    }

    static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { CoordinateSpace.displayID(of: $0) == displayID }
    }

    static func cocoaRect(fromDisplayRect rect: CGRect) -> CGRect {
        CGRect(
            x: rect.origin.x,
            y: primaryHeight - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    static func displayRect(fromCocoaRect rect: CGRect) -> CGRect {
        CGRect(
            x: rect.origin.x,
            y: primaryHeight - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    /// SCStreamConfiguration.sourceRect ekranın kendi sol üst köşesine görelidir.
    static func displayRect(fromCocoaRect rect: CGRect, on screen: NSScreen) -> CGRect {
        CGRect(
            x: rect.minX - screen.frame.minX,
            y: screen.frame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// Dikdörtgenin en çok örtüştüğü ekran. Alan iki ekrana yayıldığında da bir yanıt verir.
    static func screen(containing rect: CGRect) -> NSScreen? {
        var best: NSScreen?
        var bestArea: CGFloat = -1
        for screen in NSScreen.screens {
            let overlap = screen.frame.intersection(rect)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            if area > bestArea {
                bestArea = area
                best = screen
            }
        }
        return best ?? NSScreen.main
    }

    static func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
    }
}
