import AppKit

/// Menü çubuğundaki giriş noktası. Uygulamanın Dock simgesi yok, tek yüzü burası.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var historyFilter: ShotKind?

    override init() {
        super.init()
        configureButton()
        statusItem.menu = buildMenu()
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(
            systemSymbolName: "camera.viewfinder",
            accessibilityDescription: "Cadre"
        )
        button.image?.isTemplate = true
        button.toolTip = "Cadre"
    }

    private func item(_ title: String, _ action: Selector, _ hotKey: HotKeyAction?) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
        menuItem.target = self
        if let hotKey, let binding = Settings.shared.hotKey(for: hotKey) {
            menuItem.keyEquivalent = KeyCodeNames.name(for: binding.keyCode).lowercased()
            menuItem.keyEquivalentModifierMask = binding.cocoaModifiers
        }
        return menuItem
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        menu.addItem(item("Capture Area", #selector(captureArea), .captureArea))
        menu.addItem(item("Capture Window", #selector(captureWindow), .captureWindow))
        menu.addItem(item("Capture Full Screen", #selector(captureFullScreen), .captureFullScreen))
        menu.addItem(item("Repeat Last Area", #selector(captureLastArea), .captureLastArea))
        menu.addItem(item("All In One…", #selector(captureAllInOne), .captureAllInOne))
        menu.addItem(item("Scrolling Capture", #selector(captureScrolling), .captureScrolling))
        menu.addItem(.separator())

        menu.addItem(item("Record Screen", #selector(toggleRecording), .recordScreen))
        menu.addItem(item("Recognize Text", #selector(recognizeText), .recognizeText))
        menu.addItem(.separator())

        let recents = NSMenuItem(title: "Recent Captures", action: nil, keyEquivalent: "")
        recents.submenu = NSMenu()
        recents.tag = 100
        menu.addItem(recents)
        menu.addItem(.separator())

        let unlock = NSMenuItem(
            title: "Unlock Pinned Shots",
            action: #selector(unlockPinned), keyEquivalent: ""
        )
        unlock.target = self
        unlock.tag = 200
        menu.addItem(unlock)

        let closePinned = NSMenuItem(
            title: "Close Pinned Shots",
            action: #selector(closePinned), keyEquivalent: ""
        )
        closePinned.target = self
        closePinned.tag = 201
        menu.addItem(closePinned)
        menu.addItem(.separator())

        menu.addItem(item("Open Save Folder", #selector(openSaveFolder), nil))
        menu.addItem(item("Settings…", #selector(openSettings), nil))
        menu.addItem(.separator())
        menu.addItem(item("Quit Cadre", #selector(quit), nil))
        return menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.item(withTag: 200)?.isHidden = !PinnedShotWindow.hasLockedWindow
        menu.item(withTag: 201)?.isHidden = PinnedShotWindow.pinnedCount == 0

        guard let recents = menu.item(withTag: 100), let submenu = recents.submenu else { return }
        submenu.removeAllItems()

        // Geçmiş kapalıyken kip düğmelerini göstermenin anlamı yok.
        guard Settings.shared.keepHistory else {
            recents.isEnabled = true
            let off = NSMenuItem(title: "Turned off in Settings", action: nil, keyEquivalent: "")
            off.isEnabled = false
            submenu.addItem(off)
            return
        }

        let entries = History.shared.entries(of: historyFilter)
        recents.isEnabled = true

        for (index, kind) in ([nil] + ShotKind.allCases.map { Optional($0) }).enumerated() {
            let title = kind?.title ?? "All"
            let item = NSMenuItem(title: title, action: #selector(setFilter(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = (kind == historyFilter) ? .on : .off
            submenu.addItem(item)
        }
        submenu.addItem(.separator())

        guard !entries.isEmpty else {
            let empty = NSMenuItem(title: "Nothing yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
            return
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d MMM HH:mm"

        for (index, entry) in entries.prefix(25).enumerated() {
            let mark = entry.kind == .recording ? "▶︎ " : ""
            let title = "\(mark)\(formatter.string(from: entry.capturedAt))  ·  \(entry.width)×\(entry.height)"
            let menuItem = NSMenuItem(title: title, action: #selector(openRecent(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.tag = index
            menuItem.image = History.shared.thumbnail(for: entry, width: 44)
            submenu.addItem(menuItem)
        }

        submenu.addItem(.separator())
        let clear = NSMenuItem(title: "Clear List", action: #selector(clearHistory), keyEquivalent: "")
        clear.target = self
        submenu.addItem(clear)
    }

    @objc private func setFilter(_ sender: NSMenuItem) {
        let options: [ShotKind?] = [nil] + ShotKind.allCases.map { Optional($0) }
        guard sender.tag < options.count else { return }
        historyFilter = options[sender.tag]
    }

    // MARK: - Eylemler

    @objc private func captureArea() { CaptureCoordinator.shared.captureArea() }
    @objc private func captureWindow() { CaptureCoordinator.shared.captureWindow() }
    @objc private func captureFullScreen() { CaptureCoordinator.shared.captureFullScreen() }
    @objc private func captureLastArea() { CaptureCoordinator.shared.captureLastArea() }
    @objc private func captureAllInOne() { CaptureCoordinator.shared.captureAllInOne() }
    @objc private func captureScrolling() { ScrollingCapture.shared.begin() }
    @objc private func toggleRecording() { RecordingCoordinator.shared.toggle() }
    @objc private func recognizeText() { TextRecognizer.captureAndRecognize() }
    @objc private func openSettings() { SettingsWindowController.show() }
    @objc private func clearHistory() { History.shared.clear() }

    @objc private func openRecent(_ sender: NSMenuItem) {
        let entries = History.shared.entries(of: historyFilter)
        guard sender.tag < entries.count else { return }
        let entry = entries[sender.tag]

        if entry.kind == .recording {
            guard let path = entry.originalPath else { return }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            return
        }
        guard let image = History.shared.image(for: entry) else { return }
        EditorWindowController.open(with: Shot(image: image, capturedAt: entry.capturedAt))
    }

    @objc private func unlockPinned() { PinnedShotWindow.unlockAll() }
    @objc private func closePinned() { PinnedShotWindow.closeAll() }

    @objc private func openSaveFolder() {
        NSWorkspace.shared.open(Settings.shared.saveDirectory)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    /// Kayıt sürerken menü çubuğundaki simge durumu bildirir.
    func setRecording(_ recording: Bool) {
        guard let button = statusItem.button else { return }
        button.image = NSImage(
            systemSymbolName: recording ? "stop.circle.fill" : "camera.viewfinder",
            accessibilityDescription: "Cadre"
        )
        button.image?.isTemplate = !recording
        button.contentTintColor = recording ? .systemRed : nil
    }
}
