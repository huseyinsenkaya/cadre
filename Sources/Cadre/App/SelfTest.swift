import AppKit

/// Uygulamayı gerçek kod yollarından geçirip sonucu diske yazar.
///
/// `open Cadre.app --args --self-test` ile çalışır. Elle deneme yapmadan
/// yakalama akışının bozulup bozulmadığını söyler.
@MainActor
enum SelfTest {

    private static var failures = 0
    private static var checks = 0

    static var isRequested: Bool {
        CommandLine.arguments.contains("--self-test")
    }

    static func run() {
        Task { @MainActor in
            Diagnostics.log("=== KENDI TESTI BASLADI ===")
            // Pano onceki calismadan dolu kalabilir. Temizlemeden olcmek,
            // yakalama hic calismadigi halde "gecti" diyen bir teste yol aciyor.
            NSPasteboard.general.clearContents()
            await testAreaCapture()
            await testClipboard()
            await testSavedFile()
            await testPreviewCard()
            await testHistory()
            Diagnostics.log("=== SONUC: \(checks - failures)/\(checks) gecti ===")
            NSApp.terminate(nil)
        }
    }

    private static func check(_ name: String, _ passed: Bool, detail: String = "") {
        checks += 1
        if !passed { failures += 1 }
        let mark = passed ? "GECTI" : "KALDI"
        Diagnostics.log("  [\(mark)] \(name)\(detail.isEmpty ? "" : " — \(detail)")")
    }

    // MARK: - Sınamalar

    private static var probeRect: CGRect {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        return CGRect(x: screen.frame.minX + 100, y: screen.frame.minY + 100, width: 320, height: 200)
    }

    /// Katmanın dışarı verdiği alanla gerçek yakalama arasındaki yolu sınar.
    private static func testAreaCapture() async {
        do {
            let image = try await CaptureEngine.capture(cocoaRect: probeRect)
            let scale = (NSScreen.main ?? NSScreen.screens[0]).backingScaleFactor
            let expected = Int((320 * scale).rounded())
            check(
                "alan yakalama",
                image.width == expected,
                detail: "\(image.width)×\(image.height), beklenen genislik \(expected)"
            )
            // Akışın kalanı gerçek yoldan geçsin.
            NSPasteboard.general.clearContents()
            CaptureCoordinator.shared.finish(Shot(image: image, sourceRect: probeRect))
            try await Task.sleep(for: .milliseconds(600))
        } catch {
            check("alan yakalama", false, detail: error.localizedDescription)
            captureFailed = true
        }
    }

    /// Yakalama olmadan pano, dosya ve kart sinamalari bir sey olcmez.
    private static var captureFailed = false

    private static func testClipboard() async {
        guard !captureFailed else {
            Diagnostics.log("  [ATLANDI] panoya kopyalandi — yakalama basarisiz")
            return
        }
        let hasImage = NSPasteboard.general.data(forType: .png) != nil
        check("panoya kopyalandi", hasImage)
    }

    private static func testSavedFile() async {
        let directory = Settings.shared.saveDirectory
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        let recent = files.filter { url in
            guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate else { return false }
            return Date().timeIntervalSince(date) < 20
        }
        check("diske kaydedildi", !recent.isEmpty, detail: "\(recent.count) yeni dosya")
    }

    private static func testPreviewCard() async {
        check(
            "onizleme karti acildi",
            ThumbnailOverlayController.shared.isPresenting,
            detail: Settings.shared.afterCapture.title
        )
    }

    private static func testHistory() async {
        check("gecmise eklendi", !History.shared.entries.isEmpty,
              detail: "\(History.shared.entries.count) kayit")
    }
}
