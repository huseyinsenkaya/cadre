import AppKit

/// Bir yakalama isteğinin baştan sona geçtiği tek yol.
/// Kısayol, menü ve düzenleyici aynı buraya bağlanır.
@MainActor
final class CaptureCoordinator {

    static let shared = CaptureCoordinator()

    private(set) var lastArea: CGRect?
    private var busy = false
    private var desktopIconsHidden = false

    private init() {}

    // MARK: - Girişler

    func captureArea() {
        run { [weak self] in
            guard let self else { return }
            let overlay = SelectionOverlayController(mode: .area)
            await overlay.present { [weak self] result, image in
                guard let self else { return }
                Task { @MainActor in await self.handle(result: result, image: image) }
            }
        }
    }

    func captureWindow() {
        run { [weak self] in
            guard let self else { return }
            let overlay = SelectionOverlayController(mode: .window)
            await overlay.present { [weak self] result, image in
                guard let self else { return }
                Task { @MainActor in await self.handle(result: result, image: image) }
            }
        }
    }

    /// Tek kısayoldan bütün kiplere geçit: katmanın altında kip çubuğu görünür.
    func captureAllInOne() {
        run { [weak self] in
            guard let self else { return }
            let overlay = SelectionOverlayController(mode: .area, showsModeBar: true)
            await overlay.present { [weak self] result, image in
                guard let self else { return }
                Task { @MainActor in await self.handle(result: result, image: image) }
            }
        }
    }

    func captureFullScreen() {
        run { [weak self] in
            guard let self else { return }
            do {
                let displays = try await CaptureEngine.displays()
                let mouse = NSEvent.mouseLocation
                let wanted = CoordinateSpace.screen(containing: mouse).map(CoordinateSpace.displayID(of:))
                let display = displays.first { $0.displayID == wanted } ?? displays[0]
                let image = try await CaptureEngine.capture(display: display)
                self.finish(Shot(image: image))
            } catch {
                Notifier.show(error: error)
            }
            self.busy = false
        }
    }

    func captureLastArea() {
        guard let lastArea else {
            Notifier.show("There is no area to repeat.")
            return
        }
        run { [weak self] in
            guard let self else { return }
            do {
                let image = try await CaptureEngine.capture(cocoaRect: lastArea)
                self.finish(Shot(image: image, sourceRect: lastArea))
            } catch {
                Notifier.show(error: error)
            }
            self.busy = false
        }
    }

    // MARK: - Akış

    private func run(_ work: @escaping () async -> Void) {
        guard !busy else {
            // Bir önceki akış bir yerde takıldıysa kullanıcı ikinci basışta kurtulsun.
            Diagnostics.log("yakalama atlandi: onceki akis hala mesgul")
            SelectionOverlayController.cancelActive()
            busy = false
            return
        }
        busy = true
        Task { @MainActor in
            await self.applyTimerDelay()
            self.hideDesktopIconsIfNeeded()
            await work()
        }
    }

    private func applyTimerDelay() async {
        let seconds = Settings.shared.timerSeconds
        guard seconds > 0 else { return }
        for remaining in stride(from: seconds, to: 0, by: -1) {
            Notifier.show("\(remaining)")
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func hideDesktopIconsIfNeeded() {
        guard Settings.shared.hideDesktopIcons, !desktopIconsHidden else { return }
        desktopIconsHidden = true
        DesktopIcons.setVisible(false)
    }

    private func restoreDesktopIcons() {
        guard desktopIconsHidden else { return }
        desktopIconsHidden = false
        DesktopIcons.setVisible(true)
    }

    private func handle(result: SelectionResult, image: CGImage?) async {
        defer { busy = false }
        switch result {
        case .cancelled:
            restoreDesktopIcons()
        case .rect(let rect):
            lastArea = rect
            if let image {
                finish(Shot(image: image, sourceRect: rect))
                return
            }
            // Dondurma kapalıyken katman hiç yakalama yapmaz. Görüntü burada,
            // katman ekrandan kalktıktan sonra, yalnız seçilen alan için alınır.
            do {
                let captured = try await captureAfterOverlayClosed(rect: rect)
                finish(Shot(image: captured, sourceRect: rect))
            } catch {
                restoreDesktopIcons()
                Notifier.show(error: error)
            }

        case .fullScreen:
            if let image {
                finish(Shot(image: image))
                return
            }
            do {
                try await waitForOverlayToClear()
                let displays = try await CaptureEngine.displays()
                let mouse = NSEvent.mouseLocation
                let wanted = CoordinateSpace.screen(containing: mouse).map(CoordinateSpace.displayID(of:))
                let display = displays.first { $0.displayID == wanted } ?? displays[0]
                finish(Shot(image: try await CaptureEngine.capture(display: display)))
            } catch {
                restoreDesktopIcons()
                Notifier.show(error: error)
            }

        case .record(let rect):
            restoreDesktopIcons()
            await RecordingCoordinator.shared.start(in: rect)

        case .window(let target):
            do {
                // Katmanın kapanması ekrana yansısın, sonra pencereyi temiz yakala.
                try await Task.sleep(for: .milliseconds(120))
                let captured = try await CaptureEngine.capture(window: target.scWindow)
                finish(Shot(image: captured))
            } catch {
                restoreDesktopIcons()
                Notifier.show(error: error)
            }
        }
    }

    /// Katman ekrandan kalkmadan yakalarsak karartma görüntüye karışır.
    ///
    /// Sabit 55 ms yerine ekranın kendi tazeleme hızı kullanılır. Pencere sunucusuna
    /// bekleyen çizim önce boşaltılır, sonra iki kare beklenir. 120 Hz ekranda bu 17 ms,
    /// 60 Hz ekranda 33 ms tutar ve karartma her iki durumda da ekrandan kalkmış olur.
    private func waitForOverlayToClear() async throws {
        CATransaction.flush()
        let rate = NSScreen.main?.maximumFramesPerSecond ?? 60
        let frame = 1000.0 / Double(max(30, rate))
        try await Task.sleep(for: .milliseconds(Int((frame * 2).rounded())))
    }

    private func captureAfterOverlayClosed(rect: CGRect) async throws -> CGImage {
        try await waitForOverlayToClear()
        return try await CaptureEngine.capture(cocoaRect: rect)
    }

    /// Yakalama bittikten sonraki davranışı tercihler belirler.
    ///
    /// Sonuç önce ekrana gelir, kodlama ve disk işi arkadan yapılır. Pano, disk ve geçmiş
    /// ana iş parçacığında sırayla işlendiğinde araya 140 ms giriyordu ve kullanıcı
    /// yakalamadan sonra ekranın donduğunu görüyordu.
    func finish(_ shot: Shot) {
        restoreDesktopIcons()

        let settings = Settings.shared

        switch settings.afterCapture {
        case .copyOnly:
            store(shot, copy: true, save: false, announce: true)
        case .saveOnly:
            store(shot, copy: false, save: true, announce: true)
        case .editor:
            EditorWindowController.open(with: shot)
            store(shot, copy: settings.copyToClipboard, save: settings.saveToDisk, announce: false)
        case .overlay:
            ThumbnailOverlayController.shared.present(shot: shot)
            store(shot, copy: settings.copyToClipboard, save: settings.saveToDisk, announce: false)
        }

        // Ses en sona kalır. `NSSound.play()` ana iş parçacığını 46 ms tutar ve
        // önizlemenin önünde durursa kullanıcı o gecikmeyi gözle görür.
        Notifier.playShutter()
    }

    /// Görüntüyü bir kez kodlar, sonra panoya, diske ve geçmişe aynı veriyle yazar.
    /// Bütün iş ana iş parçacığının dışında yapılır.
    private func store(_ shot: Shot, copy: Bool, save: Bool, announce: Bool) {
        let settings = Settings.shared
        let saveFormat = settings.format
        let keepHistory = settings.keepHistory
        let historyDirectory = History.shared.directory

        Task.detached(priority: .userInitiated) {
            guard let png = Shot.encode(image: shot.image, format: .png) else {
                await MainActor.run { Notifier.show("Could not encode the image.", isError: true) }
                return
            }

            if copy {
                await MainActor.run {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setData(png, forType: .png)
                    if announce { Notifier.show("Copied to clipboard") }
                }
            }

            // Geçmişin önizlemesi her zaman PNG'dir, kullanıcının biçimi ne olursa olsun.
            let historyID = UUID()
            let historyFile = "\(historyID.uuidString).png"
            if keepHistory {
                try? png.write(to: historyDirectory.appendingPathComponent(historyFile), options: .atomic)
            }

            var stored = shot
            if save {
                // PNG zaten kodlandı. Kullanıcı JPEG veya HEIC seçtiyse bir kodlama daha gerekir.
                let data = saveFormat == .png ? png : Shot.encode(image: shot.image, format: saveFormat)
                do {
                    stored.savedURL = try Shot.write(data: data, format: saveFormat, capturedAt: shot.capturedAt)
                } catch {
                    await MainActor.run { Notifier.show(error: error) }
                }
                if announce, let url = stored.savedURL {
                    await MainActor.run { Notifier.show("Saved", detail: url.lastPathComponent) }
                }
            }

            let finished = stored
            if keepHistory {
                await MainActor.run {
                    History.shared.record(id: historyID, fileName: historyFile, shot: finished)
                }
            }
        }
    }
}

/// Yakalama sırasında masaüstü simgelerini gizler. Finder'ın kendi tercihi değiştirilir.
enum DesktopIcons {
    static func setVisible(_ visible: Bool) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        task.arguments = ["write", "com.apple.finder", "CreateDesktop", "-bool", visible ? "true" : "false"]
        try? task.run()
        task.waitUntilExit()

        let restart = Process()
        restart.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        restart.arguments = ["Finder"]
        try? restart.run()
    }
}
