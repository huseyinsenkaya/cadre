import AppKit

@MainActor
final class SettingsWindowController: NSWindowController {

    private static var shared: SettingsWindowController?

    static func show() {
        if shared == nil { shared = SettingsWindowController() }
        shared?.showWindow(nil)
        shared?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private var folderLabel: NSTextField?

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 430),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Cadre Settings"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)

        let tabs = NSTabView()
        tabs.addTabViewItem(tab("General", view: makeGeneralTab()))
        tabs.addTabViewItem(tab("Shortcuts", view: makeHotKeyTab()))
        tabs.addTabViewItem(tab("Recording", view: makeRecordingTab()))
        window.contentView = tabs
    }

    required init?(coder: NSCoder) { fatalError() }

    private func tab(_ title: String, view: NSView) -> NSTabViewItem {
        let item = NSTabViewItem(identifier: title)
        item.label = title
        item.view = view
        return item
    }

    // MARK: - Satır yardımcıları

    private func row(_ label: String, _ control: NSView) -> NSStackView {
        let title = NSTextField(labelWithString: label)
        title.alignment = .right
        title.widthAnchor.constraint(equalToConstant: 168).isActive = true
        let stack = NSStackView(views: [title, control])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.alignment = .centerY
        return stack
    }

    private func form(_ rows: [NSView]) -> NSView {
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 16, bottom: 20, right: 16)

        let container = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
        ])
        return container
    }

    private func popUp(_ titles: [String], selected: Int, action: Selector) -> NSPopUpButton {
        let button = NSPopUpButton()
        button.addItems(withTitles: titles)
        button.selectItem(at: min(selected, titles.count - 1))
        button.target = self
        button.action = action
        button.widthAnchor.constraint(equalToConstant: 230).isActive = true
        return button
    }

    private func check(_ title: String, on: Bool, action: Selector) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: self, action: action)
        button.state = on ? .on : .off
        return button
    }

    // MARK: - Genel

    private func makeGeneralTab() -> NSView {
        let settings = Settings.shared

        let format = popUp(
            ImageFormat.allCases.map(\.title),
            selected: ImageFormat.allCases.firstIndex(of: settings.format) ?? 0,
            action: #selector(changeFormat(_:))
        )
        let after = popUp(
            AfterCapture.allCases.map(\.title),
            selected: AfterCapture.allCases.firstIndex(of: settings.afterCapture) ?? 0,
            action: #selector(changeAfterCapture(_:))
        )
        let timer = popUp(
            ["Off", "3 seconds", "5 seconds", "10 seconds"],
            selected: [0, 3, 5, 10].firstIndex(of: settings.timerSeconds) ?? 0,
            action: #selector(changeTimer(_:))
        )

        let folder = NSTextField(labelWithString: settings.saveDirectoryDisplayPath)
        folder.lineBreakMode = .byTruncatingMiddle
        folder.widthAnchor.constraint(equalToConstant: 190).isActive = true
        folderLabel = folder
        let choose = NSButton(title: "Change…", target: self, action: #selector(chooseFolder))
        choose.bezelStyle = .texturedRounded
        let folderRow = NSStackView(views: [folder, choose])
        folderRow.spacing = 8

        return form([
            row("File format", format),
            row("After capture", after),
            row("Delayed capture", timer),
            row("Save folder", folderRow),
            row("", check("Ask for confirmation after selection", on: settings.confirmBeforeCapture, action: #selector(toggleConfirm(_:)))),
            row("", check("Copy to clipboard", on: settings.copyToClipboard, action: #selector(toggleCopy(_:)))),
            row("", check("Save to disk", on: settings.saveToDisk, action: #selector(toggleSave(_:)))),
            row("", check("Keep a list of recent captures", on: settings.keepHistory, action: #selector(toggleHistory(_:)))),
            row("", check("Open Cadre at login", on: LoginItem.isEnabled, action: #selector(toggleLoginItem(_:)))),
            row("", check("Show the icon in the Dock", on: settings.showsDockIcon, action: #selector(toggleDock(_:)))),
            row("", check("Play the shutter sound", on: settings.playSound, action: #selector(toggleSound(_:)))),
            row("", check("Include the cursor", on: settings.showCursor, action: #selector(toggleCursor(_:)))),
            row("", check("Hide desktop icons while capturing", on: settings.hideDesktopIcons, action: #selector(toggleIcons(_:)))),
        ])
    }

    @objc private func changeFormat(_ sender: NSPopUpButton) {
        Settings.shared.format = ImageFormat.allCases[sender.indexOfSelectedItem]
    }

    @objc private func changeAfterCapture(_ sender: NSPopUpButton) {
        Settings.shared.afterCapture = AfterCapture.allCases[sender.indexOfSelectedItem]
    }

    @objc private func changeTimer(_ sender: NSPopUpButton) {
        Settings.shared.timerSeconds = [0, 3, 5, 10][sender.indexOfSelectedItem]
    }

    @objc private func toggleConfirm(_ sender: NSButton) { Settings.shared.confirmBeforeCapture = sender.state == .on }
    @objc private func toggleCopy(_ sender: NSButton) { Settings.shared.copyToClipboard = sender.state == .on }
    @objc private func toggleSave(_ sender: NSButton) { Settings.shared.saveToDisk = sender.state == .on }
    @objc private func toggleHistory(_ sender: NSButton) { Settings.shared.keepHistory = sender.state == .on }
    @objc private func toggleDock(_ sender: NSButton) { Settings.shared.showsDockIcon = sender.state == .on }

    @objc private func toggleLoginItem(_ sender: NSButton) {
        let wanted = sender.state == .on
        guard let error = LoginItem.setEnabled(wanted) else { return }
        sender.state = wanted ? .off : .on
        Notifier.show("Could not change the login item", detail: error.localizedDescription, isError: true)
    }
    @objc private func toggleSound(_ sender: NSButton) { Settings.shared.playSound = sender.state == .on }
    @objc private func toggleCursor(_ sender: NSButton) { Settings.shared.showCursor = sender.state == .on }
    @objc private func toggleIcons(_ sender: NSButton) { Settings.shared.hideDesktopIcons = sender.state == .on }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = Settings.shared.saveDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Settings.shared.saveDirectory = url
        folderLabel?.stringValue = Settings.shared.saveDirectoryDisplayPath
    }

    // MARK: - Kısayollar

    private func makeHotKeyTab() -> NSView {
        var rows: [NSView] = HotKeyAction.allCases.map { action in
            row(action.title, HotKeyRecorderView(action: action))
        }
        let hint = NSTextField(labelWithString: "Click the box, then press ⌫ to remove a shortcut.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        rows.append(hint)
        return form(rows)
    }

    // MARK: - Kayıt

    private func makeRecordingTab() -> NSView {
        let settings = Settings.shared
        let gifRate = popUp(
            ["10 fps", "15 fps", "20 fps", "24 fps"],
            selected: [10, 15, 20, 24].firstIndex(of: settings.gifFrameRate) ?? 1,
            action: #selector(changeGifRate(_:))
        )
        let overlay = NSSlider(
            value: settings.overlaySeconds, minValue: 0, maxValue: 20,
            target: self, action: #selector(changeOverlaySeconds(_:))
        )
        overlay.widthAnchor.constraint(equalToConstant: 230).isActive = true

        let cameraSize = NSSlider(
            value: Double(settings.cameraSize), minValue: 120, maxValue: 360,
            target: self, action: #selector(changeCameraSize(_:))
        )
        cameraSize.widthAnchor.constraint(equalToConstant: 230).isActive = true

        let hint = NSTextField(labelWithString:
            "Keystroke display needs Accessibility permission. Focus mode needs two "
            + "shortcuts in the Shortcuts app, named \"\(DoNotDisturb.enableShortcutName)\" "
            + "and \"\(DoNotDisturb.disableShortcutName)\"."
        )
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byWordWrapping
        hint.maximumNumberOfLines = 4
        hint.preferredMaxLayoutWidth = 460

        return form([
            row("", check("Record system audio", on: settings.recordSystemAudio, action: #selector(toggleSystemAudio(_:)))),
            row("", check("Include the microphone", on: settings.recordMicrophone, action: #selector(toggleMicrophone(_:)))),
            row("", check("Show clicks", on: settings.showsClicks, action: #selector(toggleClicks(_:)))),
            row("", check("Show keystrokes", on: settings.showsKeystrokes, action: #selector(toggleKeystrokes(_:)))),
            row("", check("Show the camera in the corner", on: settings.showsCamera, action: #selector(toggleCamera(_:)))),
            row("", check("Turn on Focus while recording", on: settings.usesDoNotDisturb, action: #selector(toggleDND(_:)))),
            row("Camera size", cameraSize),
            row("GIF frame rate", gifRate),
            row("Preview duration", overlay),
            hint,
        ])
    }

    @objc private func toggleMicrophone(_ sender: NSButton) {
        Settings.shared.recordMicrophone = sender.state == .on
    }

    @objc private func toggleSystemAudio(_ sender: NSButton) {
        Settings.shared.recordSystemAudio = sender.state == .on
    }

    @objc private func toggleClicks(_ sender: NSButton) {
        Settings.shared.showsClicks = sender.state == .on
    }

    @objc private func toggleKeystrokes(_ sender: NSButton) {
        Settings.shared.showsKeystrokes = sender.state == .on
        if sender.state == .on { KeystrokeIndicator.requestPermission() }
    }

    @objc private func toggleCamera(_ sender: NSButton) {
        Settings.shared.showsCamera = sender.state == .on
    }

    @objc private func toggleDND(_ sender: NSButton) {
        Settings.shared.usesDoNotDisturb = sender.state == .on
    }

    @objc private func changeCameraSize(_ sender: NSSlider) {
        Settings.shared.cameraSize = Int(sender.doubleValue)
    }

    @objc private func changeGifRate(_ sender: NSPopUpButton) {
        Settings.shared.gifFrameRate = [10, 15, 20, 24][sender.indexOfSelectedItem]
    }

    @objc private func changeOverlaySeconds(_ sender: NSSlider) {
        Settings.shared.overlaySeconds = sender.doubleValue
    }
}
