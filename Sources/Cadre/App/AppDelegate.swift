import AppKit

/// Açılış durumunu diske yazar. Menü çubuğu görünmediğinde ya da kısayol
/// çalışmadığında sorunun nerede olduğunu görmenin tek yolu budur.
enum Diagnostics {
    static let url = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Cadre/diagnostic.log")

    static func reset() {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? "".write(to: url, atomically: true, encoding: .utf8)
    }

    static func log(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let text = "\(stamp)  \(line)\n"
        guard let handle = try? FileHandle(forWritingTo: url) else {
            try? text.write(to: url, atomically: true, encoding: .utf8)
            return
        }
        handle.seekToEndOfFile()
        handle.write(Data(text.utf8))
        try? handle.close()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Diagnostics.reset()
        Diagnostics.log("acilis basladi")
        applyActivationPolicy()
        Diagnostics.log("etkinlik ilkesi: \(Settings.shared.showsDockIcon ? "regular" : "accessory")")
        statusItem = StatusItemController()
        Diagnostics.log("menu cubugu ogesi kuruldu")
        AppDelegateBridge.status = statusItem
        registerHotKeys()

        NotificationCenter.default.addObserver(
            forName: Settings.didChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.registerHotKeys()
                self?.applyActivationPolicy()
            }
        }

        Task {
            await warmUpPermission()
            // İlk yakalamanın bedeli açılışa alınır: ses diskten okunur ve
            // ScreenCaptureKit iki piksel yakalayarak hizmetini kurar.
            Notifier.prepareShutter()
            await CaptureEngine.warmUpCapture()
            Diagnostics.log("yakalama isindirildi")
            if SelfTest.isRequested { SelfTest.run() }
        }
    }

    var status: StatusItemController? { statusItem }

    private func applyActivationPolicy() {
        NSApp.setActivationPolicy(Settings.shared.showsDockIcon ? .regular : .accessory)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// İzin penceresi ilk yakalamanın ortasında çıkmasın diye açılışta bir kez sorulur.
    private func warmUpPermission() async {
        do {
            let content = try await CaptureEngine.shareableContent()
            Diagnostics.log("ekran izni TAMAM — \(content.displays.count) ekran, \(content.windows.count) pencere")
        } catch {
            Diagnostics.log("ekran izni YOK — \(error.localizedDescription)")
            Notifier.show(
                "Screen recording permission needed",
                detail: "System Settings → Privacy & Security → Screen Recording",
                isError: true
            )
        }
    }

    private func registerHotKeys() {
        HotKeyCenter.shared.unregisterAll()
        var failed: [String] = []
        for action in HotKeyAction.allCases {
            guard let binding = Settings.shared.hotKey(for: action) else { continue }
            var ok = HotKeyCenter.shared.register(binding) {
                MainActor.assumeIsolated { AppDelegate.perform(action) }
            }
            Diagnostics.log("kisayol \(action.title) \(binding.displayString): \(ok ? "alindi" : "ALINAMADI")")

            if !ok, let fallback = action.fallbackBinding {
                ok = HotKeyCenter.shared.register(fallback) {
                    MainActor.assumeIsolated { AppDelegate.perform(action) }
                }
                Diagnostics.log("yedek \(action.title) \(fallback.displayString): \(ok ? "alindi" : "ALINAMADI")")
                if ok {
                    Notifier.show(
                        "\(binding.displayString) is taken by the system",
                        detail: "\(action.title) is on \(fallback.displayString) for now"
                    )
                }
            }

            if !ok { failed.append("\(action.title) (\(binding.displayString))") }
        }
        // Başka bir uygulama aynı tuşu tutuyorsa Carbon kaydı reddeder.
        if !failed.isEmpty {
            Notifier.show(
                "Could not register these shortcuts",
                detail: failed.joined(separator: ", "),
                isError: true
            )
        }
    }

    static func perform(_ action: HotKeyAction) {
        // Kaçış kısayolları her durumda önce çalışır. Menü çubuğu simgesi çentiğin
        // altında kalabilir; kullanıcının uygulamaya ulaşan başka yolu kalmayabilir.
        switch action {
        case .closePinned:
            let count = PinnedShotWindow.pinnedCount
            PinnedShotWindow.closeAll()
            Notifier.show(count > 0 ? "\(count) pinned shots closed" : "No pinned shots")
            return
        case .quitApp:
            NSApp.terminate(nil)
            return
        default:
            break
        }

        // Katman açıkken herhangi bir kısayol onu kapatır. Kilitlenmeye karşı çıkış yolu.
        if SelectionOverlayController.isPresenting {
            SelectionOverlayController.cancelActive()
            return
        }
        if ScrollingCapture.shared.isRunning {
            ScrollingCapture.shared.begin()
            return
        }
        switch action {
        case .captureArea: CaptureCoordinator.shared.captureArea()
        case .captureWindow: CaptureCoordinator.shared.captureWindow()
        case .captureFullScreen: CaptureCoordinator.shared.captureFullScreen()
        case .captureLastArea: CaptureCoordinator.shared.captureLastArea()
        case .captureAllInOne: CaptureCoordinator.shared.captureAllInOne()
        case .captureScrolling: ScrollingCapture.shared.begin()
        case .recordScreen: RecordingCoordinator.shared.toggle()
        case .recognizeText: TextRecognizer.captureAndRecognize()
        case .closePinned, .quitApp: break
        }
    }
}
