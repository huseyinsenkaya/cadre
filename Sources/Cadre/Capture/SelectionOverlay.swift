import AppKit
import Carbon.HIToolbox
import ScreenCaptureKit

enum SelectionMode {
    case area
    case window
}

enum SelectionResult {
    case rect(CGRect)
    case window(WindowTarget)
    /// Hepsi bir arada kipinde tüm ekran seçildi; görüntü zaten donmuş karedir.
    case fullScreen
    /// Hepsi bir arada kipinde bu alanın kaydı istendi.
    case record(CGRect)
    case cancelled
}

/// Seçim katmanının penceresi.
///
/// Pencere kendi kapanma sigortasını taşır. Denetleyici bir hata yüzünden ölse bile
/// katman ekranı kilitli bırakmaz: sayaç dolunca pencere kendini kapatır.
/// Bu sigorta olmadan, ölü bir denetleyici tüm ekranı kaplayan ve girdiyi yutan
/// bir pencere bırakır; tek çıkış yolu makineyi yeniden başlatmak olur.
final class OverlayWindow: NSWindow {

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Etkileşim olmadan geçen süre. Her fare ve tuş olayı sayacı sıfırlar.
    private static let idleTimeout: TimeInterval = 45
    /// Etkileşim sürse bile katman bundan uzun yaşamaz.
    private static let hardTimeout: TimeInterval = 180

    private var idleTimer: Timer?
    private var hardTimer: Timer?
    private var closed = false

    var onTimeout: (() -> Void)?

    func startSafetyTimers() {
        pokeSafetyTimer()
        hardTimer?.invalidate()
        hardTimer = OverlayWindow.makeTimer(after: OverlayWindow.hardTimeout) { [weak self] in
            self?.emergencyClose()
        }
    }

    func pokeSafetyTimer() {
        idleTimer?.invalidate()
        idleTimer = OverlayWindow.makeTimer(after: OverlayWindow.idleTimeout) { [weak self] in
            self?.emergencyClose()
        }
    }

    /// Zamanlayıcı `.common` kiplerine eklenir. `scheduledTimer` yalnız `.default` kipine
    /// eklediği için fare sürükleme döngüsü sırasında ateşlenmez; sigortanın tam da o anda
    /// çalışması gerekir.
    private static func makeTimer(after seconds: TimeInterval, action: @escaping () -> Void) -> Timer {
        let timer = Timer(timeInterval: seconds, repeats: false) { _ in action() }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    func stopSafetyTimers() {
        idleTimer?.invalidate()
        hardTimer?.invalidate()
        idleTimer = nil
        hardTimer = nil
    }

    /// Sigorta ateşlendiğinde çağrılır. Denetleyici haberdar edilir ve kullanıcı uyarılır.
    func emergencyClose() {
        guard !closed else { return }
        close(notifying: true)
    }

    /// Olağan kapanış. Denetleyici işi zaten bitirdiği için geri çağrı yapılmaz.
    /// Burada `onTimeout` çağırmak, başarılı her yakalamada zaman aşımı uyarısı gösteriyordu.
    func closeQuietly() {
        guard !closed else { return }
        close(notifying: false)
    }

    private func close(notifying: Bool) {
        closed = true
        stopSafetyTimers()
        ignoresMouseEvents = true
        orderOut(nil)
        contentView = nil
        NSCursor.arrow.set()
        if notifying { onTimeout?() }
    }

    deinit {
        idleTimer?.invalidate()
        hardTimer?.invalidate()
    }
}

/// Seçim başlarken ekranın tamamı bir kez yakalanır ve donmuş kare katmanın altına serilir.
/// Donmuş kare üç işi birden çözer: büyüteç gerçek pikselleri gösterir, renk okunur,
/// ve onaydan sonra kırpma yeniden yakalama beklemeden anında biter.
@MainActor
final class SelectionOverlayController {

    private struct ScreenFreeze {
        let screen: NSScreen
        let image: CGImage?
        let window: OverlayWindow
        let view: OverlayView
    }

    /// Katman görünürken denetleyiciyi hayatta tutan tek güçlü referans.
    /// `OverlayView.controller` bilerek zayıftır; bu referans olmadan denetleyici
    /// `present` döner dönmez silinir ve katman ölü bir pencereye dönüşür.
    private static var current: SelectionOverlayController?

    static var isPresenting: Bool { current != nil }

    /// Ekran kilitlendiğinde başvurulacak son çare. Menü çubuğu ve kısayol buradan geçer.
    static func cancelActive() {
        current?.cancel()
    }

    private var freezes: [ScreenFreeze] = []
    private var windowTargets: [WindowTarget] = []
    private var completion: ((SelectionResult, CGImage?) -> Void)?
    private var mode: SelectionMode
    /// Hepsi bir arada kipinde katmanın altında kip çubuğu görünür.
    let showsModeBar: Bool
    private var previousApp: NSRunningApplication?
    private var finished = false
    private var keyMonitor: Any?
    private var resignObserver: NSObjectProtocol?

    init(mode: SelectionMode, showsModeBar: Bool = false) {
        self.mode = mode
        self.showsModeBar = showsModeBar
    }

    /// Katmanın açıldığı an. Etkinlik kaybının kullanıcı hareketi olup olmadığı
    /// buna göre ayrılır.
    private var startedAt = CFAbsoluteTimeGetCurrent()

    func present(completion: @escaping (SelectionResult, CGImage?) -> Void) async {
        startedAt = CFAbsoluteTimeGetCurrent()
        guard SelectionOverlayController.current == nil else {
            Diagnostics.log("katman acilmadi: onceki katman hala kayitli")
            completion(.cancelled, nil)
            return
        }
        SelectionOverlayController.current = self
        self.completion = completion
        self.previousApp = NSWorkspace.shared.frontmostApplication

        // Etkinleşme eşzamansızdır ve menü çubuğu uygulamasında en pahalı adımdır.
        // İsteği en başta vermek, pencere kurulumunun onunla aynı anda yürümesini sağlar.
        NSApp.activate(ignoringOtherApps: true)

        do {
            // Dondurma kapalıyken katman açılmadan önce hiçbir yakalama yapılmaz.
            // Görüntü ancak kullanıcı fareyi bıraktığında, yalnız seçilen alan için alınır.
            // Her ekranı tam çözünürlükte önden yakalamak gözle görülür bir gecikme yapıyordu.
            guard Settings.shared.freezeScreen else {
                // Kullanıcı seçim yaparken ekran listesi arkadan hazırlanır.
                CaptureEngine.warmDisplays()
                if mode == .window {
                    windowTargets = (try? await CaptureEngine.windowTargets()) ?? []
                }
                for screen in NSScreen.screens {
                    makeOverlay(on: screen, image: nil)
                }
                showOverlays()
                return
            }

            let displays = try await CaptureEngine.displays()
            if mode == .window {
                windowTargets = (try? await CaptureEngine.windowTargets()) ?? []
            }
            // İmlecin bulunduğu ekran önce yakalanır ve hemen gösterilir.
            // Bütün ekranları beklemek, çok ekranlı kurulumda açılışı geciktiriyordu.
            let mouse = NSEvent.mouseLocation
            let focused = CoordinateSpace.screen(containing: mouse).map(CoordinateSpace.displayID(of:))
            let ordered = displays.sorted { first, _ in first.displayID == focused }

            for display in ordered {
                guard let screen = CoordinateSpace.screen(for: display.displayID) else { continue }
                let image = try await CaptureEngine.capture(display: display)
                makeOverlay(on: screen, image: image)
            }
        } catch {
            teardown()
            SelectionOverlayController.current = nil
            completion(.cancelled, nil)
            Notifier.show(error: error)
            return
        }

        showOverlays()
    }

    private func showOverlays() {
        guard !freezes.isEmpty else {
            Diagnostics.log("katman acilmadi: hic pencere kurulmadi")
            SelectionOverlayController.current = nil
            let handler = completion
            completion = nil
            handler?(.cancelled, nil)
            return
        }

        installEscapeHatches()

        takeFocus()
        let pointer = NSEvent.mouseLocation
        let focus = freezes.first { $0.screen.frame.contains(pointer) } ?? freezes[0]

        // Etkinleşme eşzamansızdır. Oturmazsa tuşlar katmana gelmez ve ilk tıklama
        // pencereyi öne almakla harcanır. Sonucu kayda geçir.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !self.finished else { return }
            if !NSApp.isActive || !focus.window.isKeyWindow {
                Diagnostics.log(
                    "katman odaklanamadi: uygulama etkin=\(NSApp.isActive) pencere anahtar=\(focus.window.isKeyWindow)"
                )
            }
        }

        for freeze in freezes { freeze.window.startSafetyTimers() }
    }

    private func makeOverlay(on screen: NSScreen, image: CGImage?) {
        let window = OverlayWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        // .screenSaver seviyesi sistem uyarılarının da üstüne çıkar. .popUpMenu menü
        // çubuğunu ve normal pencereleri örter ama Zorla Çık penceresini örtmez.
        window.level = .popUpMenu
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.setFrame(screen.frame, display: false)
        window.acceptsMouseMovedEvents = true
        window.onTimeout = { [weak self] in
            MainActor.assumeIsolated {
                Notifier.show("The selection overlay closed on its own.")
                self?.finish(.cancelled, image: nil)
            }
        }

        // Donmuş kare kendi görüntü katmanında durur, üstündeki çizim yüzeyi saydamdır.
        // Böylece tam çözünürlüklü kare bir kez bileşiklenir, her karede yeniden çizilmez.
        let container = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        container.wantsLayer = true

        if let image {
            let backdrop = NSImageView(frame: container.bounds)
            backdrop.image = NSImage(cgImage: image, size: screen.frame.size)
            backdrop.imageScaling = .scaleAxesIndependently
            backdrop.autoresizingMask = [.width, .height]
            backdrop.wantsLayer = true
            backdrop.layerContentsRedrawPolicy = .never
            container.addSubview(backdrop)
        }

        let view = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.freezeImage = image
        view.screenFrame = screen.frame
        view.mode = mode
        view.showsModeBar = showsModeBar
        view.windowTargets = windowTargets.filter { $0.frame.intersects(screen.frame) }
        view.controller = self
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)

        window.contentView = container
        window.orderFrontRegardless()

        freezes.append(ScreenFreeze(screen: screen, image: image, window: window, view: view))
    }

    /// Esc tuşu ana yoldan gelmezse diye ikinci ve üçüncü çıkış yolu.
    private func installEscapeHatches() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            if Int(event.keyCode) == kVK_Escape {
                MainActor.assumeIsolated { self.cancel() }
                return nil
            }
            return event
        }

        // Kullanıcı ⌘Tab ile başka uygulamaya geçerse katman kapanır.
        //
        // Bildirim tek başına yeterli değildir. Uygulama katman açılırken etkin hâle
        // geçer ve önceki uygulama bir an için odağı geri alır. O anlık bildirim
        // katmanı daha kullanıcı sürüklemeden kapatıyordu ve kısayol çalışmamış gibi
        // görünüyordu. Bu yüzden bildirimden sonra beklenir ve durum yeniden okunur.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleResign() }
        }
    }

    /// Katman açıldıktan sonra bu süre içinde gelen etkinlik kaybı kullanıcının
    /// uygulama değiştirmesi sayılmaz. Kısayola basan kullanıcı yarım saniye sonra
    /// ⌘Tab yapmaz; o bildirim önceki uygulamanın odağı geri almasından gelir.
    private static let switchGrace: TimeInterval = 1.5

    /// Etkinlik kaybı bildirimi geldiğinde çağrılır.
    private func handleResign() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            guard let self, !self.finished else { return }
            guard !NSApp.isActive else {
                Diagnostics.log("etkinlik anlik kayboldu, katman acik kaldi")
                return
            }

            // Kullanıcı seçim yapıyorsa katman kapanmaz. Odak geri alınır ve iş sürer.
            // Bu bildirimi körü körüne dinlemek, sürüklemenin ortasında yakalamayı
            // iptal ediyordu ve kısayol çalışmamış gibi görünüyordu.
            if self.isSelecting {
                Diagnostics.log("odak geri alindi: kullanici secim yapiyor")
                self.takeFocus()
                return
            }

            if CFAbsoluteTimeGetCurrent() - self.startedAt < SelectionOverlayController.switchGrace {
                Diagnostics.log("odak geri alindi: katman yeni acilmisti")
                self.takeFocus()
                return
            }

            Diagnostics.log("katman kapandi: uygulama etkinligi kaybetti")
            self.cancel()
        }
    }

    /// Uygulamayı etkin yapar ve imlecin bulunduğu ekranın penceresini anahtar yapar.
    private func takeFocus() {
        guard !freezes.isEmpty else { return }
        NSApp.activate(ignoringOtherApps: true)
        let pointer = NSEvent.mouseLocation
        let focus = freezes.first { $0.screen.frame.contains(pointer) } ?? freezes[0]
        focus.window.makeKeyAndOrderFront(nil)
        NSCursor.crosshair.set()
    }

    // MARK: - Katmandan gelen olaylar

    /// Sigorta sayacının son sıfırlanma anı.
    private var lastPoke: CFAbsoluteTime = 0

    /// Sigorta sayacı en fazla saniyede bir sıfırlanır.
    ///
    /// Önceki sürüm her fare hareketinde her ekran için iki `Timer` nesnesini iptal edip
    /// yenisini RunLoop'a ekliyordu. 120 Hz ekranda bu saniyede 240 ayırma demekti.
    /// Sayacın çözünürlüğü 45 saniyedir, bir saniyelik gecikme onu etkilemez.
    func noteInteraction() {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastPoke >= 1 else { return }
        lastPoke = now
        for freeze in freezes { freeze.window.pokeSafetyTimer() }
    }

    func setMode(_ newMode: SelectionMode) {
        guard mode != newMode else { return }
        mode = newMode
        if newMode == .window, windowTargets.isEmpty {
            Task { @MainActor in
                windowTargets = (try? await CaptureEngine.windowTargets()) ?? []
                for freeze in freezes {
                    freeze.view.windowTargets = windowTargets.filter { $0.frame.intersects(freeze.screen.frame) }
                    freeze.view.needsDisplay = true
                }
            }
        }
        for freeze in freezes {
            freeze.view.mode = newMode
            freeze.view.needsDisplay = true
        }
    }

    var currentMode: SelectionMode { mode }

    /// Ekranlardan herhangi birinde seçim başladıysa doğrudur.
    private var isSelecting: Bool { freezes.contains { $0.view.isSelecting } }

    func cancel() {
        finish(.cancelled, image: nil)
    }

    /// Alan seçimi donmuş kareden kırpılır; ölçek etkeni ekranın kendi ölçeğidir.
    func confirmArea(_ rectInScreen: CGRect, on view: OverlayView) {
        guard let freeze = freezes.first(where: { $0.view === view }) else {
            finish(.cancelled, image: nil)
            return
        }
        let globalRect = CGRect(
            x: freeze.screen.frame.minX + rectInScreen.minX,
            y: freeze.screen.frame.minY + rectInScreen.minY,
            width: rectInScreen.width,
            height: rectInScreen.height
        )

        // Dondurma kapalıyken görüntü yok; alanı bildiririz, yakalamayı çağıran yapar.
        guard let frozen = freeze.image else {
            finish(.rect(globalRect), image: nil)
            return
        }

        let scale = freeze.screen.backingScaleFactor
        let local = CGRect(
            x: rectInScreen.minX * scale,
            y: (freeze.screen.frame.height - rectInScreen.maxY) * scale,
            width: rectInScreen.width * scale,
            height: rectInScreen.height * scale
        ).integral

        guard local.width >= 1, local.height >= 1,
              let cropped = frozen.cropping(to: local)
        else {
            finish(.cancelled, image: nil)
            return
        }
        finish(.rect(globalRect), image: cropped)
    }

    /// Pencere seçimi donmuş kareden değil, katman kapandıktan sonra yeniden yakalanır:
    /// böylece üstteki pencereler ve gölge görüntüye karışmaz.
    func confirmWindow(_ target: WindowTarget) {
        finish(.window(target), image: nil)
    }

    /// Tüm ekran donmuş kareden gelir; yeniden yakalamaya gerek yok.
    func confirmFullScreen(on view: OverlayView) {
        guard let freeze = freezes.first(where: { $0.view === view }) else {
            finish(.cancelled, image: nil)
            return
        }
        finish(.fullScreen, image: freeze.image)  // görüntü yoksa çağıran yakalar
    }

    func confirmRecord(_ rectInScreen: CGRect, on view: OverlayView) {
        guard let freeze = freezes.first(where: { $0.view === view }) else {
            finish(.cancelled, image: nil)
            return
        }
        let global = CGRect(
            x: freeze.screen.frame.minX + rectInScreen.minX,
            y: freeze.screen.frame.minY + rectInScreen.minY,
            width: rectInScreen.width,
            height: rectInScreen.height
        )
        finish(.record(global), image: nil)
    }

    private func finish(_ result: SelectionResult, image: CGImage?) {
        guard !finished else { return }
        finished = true

        teardown()
        SelectionOverlayController.current = nil
        NSCursor.arrow.set()

        if case .cancelled = result {
            previousApp?.activate()
        }

        let handler = completion
        completion = nil
        handler?(result, image)
    }

    private func teardown() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil

        for freeze in freezes { freeze.window.closeQuietly() }
        freezes.removeAll()
    }

    deinit {
        // Denetleyici beklenmedik bir yoldan silinirse pencereler ekranda kalmasın.
        for freeze in freezes { freeze.window.closeQuietly() }
    }
}
