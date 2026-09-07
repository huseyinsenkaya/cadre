import AppKit

/// Yakalanan görüntünün üstüne açıklama eklenen pencere.
@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {

    private static var openControllers: [EditorWindowController] = []

    private let canvas: AnnotationCanvasView
    private var shot: Shot
    private var toolButtons: [Tool: NSButton] = [:]
    private var colorButtons: [NSButton] = []
    private var undoButton: NSButton?
    private var redoButton: NSButton?
    private var cropBar: NSStackView?
    private var thicknessSlider: NSSlider?
    private var backgroundRow: NSStackView?
    private var backgroundSwatches: [NSButton] = []

    private let palette: [NSColor] = [
        NSColor(srgbRed: 0.95, green: 0.26, blue: 0.31, alpha: 1),
        NSColor(srgbRed: 1.00, green: 0.72, blue: 0.20, alpha: 1),
        NSColor(srgbRed: 0.24, green: 0.75, blue: 0.44, alpha: 1),
        NSColor(srgbRed: 0.24, green: 0.55, blue: 0.98, alpha: 1),
        NSColor(srgbRed: 0.62, green: 0.36, blue: 0.92, alpha: 1),
        NSColor(srgbRed: 0.11, green: 0.12, blue: 0.14, alpha: 1),
        NSColor.white,
    ]

    static func open(with shot: Shot) {
        let controller = EditorWindowController(shot: shot)
        openControllers.append(controller)
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init(shot: Shot) {
        self.shot = shot
        self.canvas = AnnotationCanvasView(image: shot.image)

        let scale = min(
            1,
            (NSScreen.main?.visibleFrame.width ?? 1440) * 0.8 / CGFloat(shot.image.width),
            (NSScreen.main?.visibleFrame.height ?? 900) * 0.7 / CGFloat(shot.image.height)
        )
        let contentSize = NSSize(
            width: max(560, CGFloat(shot.image.width) * scale),
            height: max(320, CGFloat(shot.image.height) * scale) + EditorWindowController.barHeight
        )

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Cadre — \(shot.image.width) × \(shot.image.height)"
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
        window.appearance = NSAppearance(
            named: Settings.shared.editorUsesDarkTheme ? .darkAqua : .aqua
        )
        window.delegate = self
        buildContent()
        canvas.onChange = { [weak self] in self?.refreshControls() }
        refreshControls()
    }

    required init?(coder: NSCoder) { fatalError() }

    private static let barHeight: CGFloat = 132

    // MARK: - Yerleşim

    private func buildContent() {
        guard let window else { return }

        let root = NSView()
        let toolRow = makeToolRow()
        let styleRow = makeStyleRow()
        let bgRow = makeBackgroundRow()

        canvas.translatesAutoresizingMaskIntoConstraints = false
        toolRow.translatesAutoresizingMaskIntoConstraints = false
        styleRow.translatesAutoresizingMaskIntoConstraints = false
        bgRow.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(canvas)
        root.addSubview(separator)
        root.addSubview(toolRow)
        root.addSubview(styleRow)
        root.addSubview(bgRow)

        NSLayoutConstraint.activate([
            canvas.topAnchor.constraint(equalTo: root.topAnchor),
            canvas.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: separator.topAnchor),

            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: toolRow.topAnchor, constant: -8),

            toolRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            toolRow.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -12),
            toolRow.bottomAnchor.constraint(equalTo: styleRow.topAnchor, constant: -8),

            styleRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            styleRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            styleRow.bottomAnchor.constraint(equalTo: bgRow.topAnchor, constant: -8),

            bgRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            bgRow.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -12),
            bgRow.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])

        window.contentView = root
        refuseFocus(in: root)
        window.makeFirstResponder(canvas)
    }

    /// Araç çubuğundaki denetimler klavye odağını almaz. Alan bir düğme Esc'yi yutar
    /// ve kullanıcı aracı bırakamaz.
    private func refuseFocus(in view: NSView) {
        guard view !== canvas else { return }
        (view as? NSControl)?.refusesFirstResponder = true
        view.subviews.forEach(refuseFocus)
    }

    private func makeToolRow() -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 3

        for tool in Tool.allCases {
            let button = NSButton(
                image: NSImage(systemSymbolName: tool.symbol, accessibilityDescription: tool.title)
                    ?? NSImage(size: NSSize(width: 14, height: 14)),
                target: self,
                action: #selector(selectTool(_:))
            )
            button.bezelStyle = .texturedRounded
            button.setButtonType(.toggle)
            button.toolTip = tool.title
            button.tag = Tool.allCases.firstIndex(of: tool) ?? 0
            button.widthAnchor.constraint(equalToConstant: 34).isActive = true
            toolButtons[tool] = button
            stack.addArrangedSubview(button)
        }

        stack.addArrangedSubview(spacer(width: 10))

        let undo = NSButton(
            image: NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: "Undo")!,
            target: self, action: #selector(undo)
        )
        undo.bezelStyle = .texturedRounded
        undo.toolTip = "Undo (⌘Z)"
        undoButton = undo

        let redo = NSButton(
            image: NSImage(systemSymbolName: "arrow.uturn.forward", accessibilityDescription: "Redo")!,
            target: self, action: #selector(redoAction)
        )
        redo.bezelStyle = .texturedRounded
        redo.toolTip = "Redo (⇧⌘Z)"
        redoButton = redo

        let clear = NSButton(title: "Clear", target: self, action: #selector(clearAll))
        clear.bezelStyle = .texturedRounded

        stack.addArrangedSubview(undo)
        stack.addArrangedSubview(redo)
        stack.addArrangedSubview(clear)

        return stack
    }

    private func makeStyleRow() -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY

        for (index, color) in palette.enumerated() {
            let button = NSButton(title: "", target: self, action: #selector(selectColor(_:)))
            button.tag = index
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.backgroundColor = color.cgColor
            button.layer?.cornerRadius = 9
            button.layer?.borderWidth = 1
            button.layer?.borderColor = NSColor.black.withAlphaComponent(0.18).cgColor
            button.widthAnchor.constraint(equalToConstant: 18).isActive = true
            button.heightAnchor.constraint(equalToConstant: 18).isActive = true
            colorButtons.append(button)
            stack.addArrangedSubview(button)
        }

        let thickness = NSSlider(value: 4, minValue: 1, maxValue: 24, target: self, action: #selector(changeThickness(_:)))
        thickness.controlSize = .small
        thickness.widthAnchor.constraint(equalToConstant: 110).isActive = true
        thickness.toolTip = "Thickness"
        thicknessSlider = thickness
        stack.addArrangedSubview(thickness)

        let textPreset = NSPopUpButton()
        textPreset.addItems(withTitles: TextPreset.allCases.map(\.title))
        textPreset.target = self
        textPreset.action = #selector(changeTextPreset(_:))
        textPreset.toolTip = "Text style"
        textPreset.widthAnchor.constraint(equalToConstant: 108).isActive = true
        stack.addArrangedSubview(textPreset)

        let fill = NSButton(title: "Fill", target: self, action: #selector(toggleFill(_:)))
        fill.setButtonType(.switch)
        fill.font = .systemFont(ofSize: 11)
        stack.addArrangedSubview(fill)

        let cropApply = NSButton(title: "Crop", target: self, action: #selector(applyCrop))
        cropApply.bezelStyle = .texturedRounded
        cropApply.keyEquivalent = "\r"
        let cropCancel = NSButton(title: "Cancel", target: self, action: #selector(cancelCrop))
        cropCancel.bezelStyle = .texturedRounded
        let cropStack = NSStackView(views: [cropApply, cropCancel])
        cropStack.spacing = 4
        cropStack.isHidden = true
        cropBar = cropStack
        stack.addArrangedSubview(cropStack)

        stack.addArrangedSubview(NSView())

        let theme = NSButton(
            image: NSImage(systemSymbolName: "circle.lefthalf.filled", accessibilityDescription: "Theme")!,
            target: self, action: #selector(toggleTheme)
        )
        theme.bezelStyle = .texturedRounded
        theme.toolTip = "Dark and light theme"
        stack.addArrangedSubview(theme)

        let combine = NSButton(title: "Combine…", target: self, action: #selector(combineImages))
        combine.bezelStyle = .texturedRounded
        combine.toolTip = "Add other images below"
        stack.addArrangedSubview(combine)

        let backgroundToggle = NSButton(title: "Background", target: self, action: #selector(toggleBackground(_:)))
        backgroundToggle.bezelStyle = .texturedRounded
        backgroundToggle.setButtonType(.pushOnPushOff)
        stack.addArrangedSubview(backgroundToggle)

        let pin = NSButton(title: "Pin", target: self, action: #selector(pinImage))
        pin.bezelStyle = .texturedRounded
        stack.addArrangedSubview(pin)

        let copy = NSButton(title: "Copy", target: self, action: #selector(copyImage))
        copy.bezelStyle = .texturedRounded
        let save = NSButton(title: "Save", target: self, action: #selector(saveImage))
        save.bezelStyle = .texturedRounded
        save.keyEquivalent = "s"
        save.keyEquivalentModifierMask = [.command]
        let saveAs = NSButton(title: "Save As…", target: self, action: #selector(saveImageAs))
        saveAs.bezelStyle = .texturedRounded
        let share = NSButton(
            image: NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Share")!,
            target: self, action: #selector(share(_:))
        )
        share.bezelStyle = .texturedRounded

        for button in [copy, save, saveAs, share] { stack.addArrangedSubview(button) }

        return stack
    }

    /// Zemin denetimleri. "Background" düğmesi basılana kadar gizli durur.
    private func makeBackgroundRow() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        stack.isHidden = true
        backgroundRow = stack

        for (index, preset) in CanvasBackground.presets.enumerated() {
            let button = NSButton(title: "", target: self, action: #selector(selectBackgroundPreset(_:)))
            button.tag = index
            button.isBordered = false
            button.wantsLayer = true
            button.toolTip = preset.name
            button.layer?.cornerRadius = 5
            button.layer?.borderWidth = 1
            button.layer?.borderColor = NSColor.black.withAlphaComponent(0.2).cgColor
            button.widthAnchor.constraint(equalToConstant: 24).isActive = true
            button.heightAnchor.constraint(equalToConstant: 18).isActive = true
            applyPresetPreview(preset.fill, to: button)
            backgroundSwatches.append(button)
            stack.addArrangedSubview(button)
        }

        stack.addArrangedSubview(labelled("Padding", slider(
            value: 0.08, min: 0.01, max: 0.28, action: #selector(changePadding(_:))
        )))
        stack.addArrangedSubview(labelled("Corner", slider(
            value: 12, min: 0, max: 48, action: #selector(changeCorner(_:))
        )))
        stack.addArrangedSubview(labelled("Shadow", slider(
            value: 0.32, min: 0, max: 0.8, action: #selector(changeShadow(_:))
        )))

        let aspect = NSPopUpButton()
        aspect.addItems(withTitles: AspectPreset.allCases.map(\.title))
        aspect.target = self
        aspect.action = #selector(changeAspect(_:))
        stack.addArrangedSubview(aspect)

        return stack
    }

    private func slider(value: Double, min: Double, max: Double, action: Selector) -> NSSlider {
        let control = NSSlider(value: value, minValue: min, maxValue: max, target: self, action: action)
        control.controlSize = .small
        control.widthAnchor.constraint(equalToConstant: 78).isActive = true
        return control
    }

    private func labelled(_ title: String, _ control: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 10)
        label.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [label, control])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        return stack
    }

    private func applyPresetPreview(_ fill: BackgroundFill, to button: NSButton) {
        switch fill {
        case .solid(let color):
            button.layer?.backgroundColor = color.cgColor
            button.layer?.sublayers?.removeAll()
        case .gradient(let start, let end):
            let gradient = CAGradientLayer()
            gradient.frame = CGRect(x: 0, y: 0, width: 24, height: 18)
            gradient.colors = [start.cgColor, end.cgColor]
            gradient.startPoint = CGPoint(x: 0, y: 0)
            gradient.endPoint = CGPoint(x: 1, y: 1)
            gradient.cornerRadius = 5
            button.layer?.sublayers?.removeAll()
            button.layer?.addSublayer(gradient)
        }
    }

    private func spacer(width: CGFloat) -> NSView {
        let view = NSView()
        view.widthAnchor.constraint(equalToConstant: width).isActive = true
        return view
    }

    private func refreshControls() {
        for (tool, button) in toolButtons {
            button.state = (tool == canvas.tool) ? .on : .off
        }
        for (index, button) in colorButtons.enumerated() {
            let selected = palette[index] == canvas.style.color
            button.layer?.borderWidth = selected ? 3 : 1
            button.layer?.borderColor = selected
                ? NSColor.controlAccentColor.cgColor
                : NSColor.black.withAlphaComponent(0.18).cgColor
        }
        for (index, button) in backgroundSwatches.enumerated() {
            let selected = CanvasBackground.presets[index].fill == canvas.background.fill
            button.layer?.borderWidth = selected ? 3 : 1
            button.layer?.borderColor = selected
                ? NSColor.controlAccentColor.cgColor
                : NSColor.black.withAlphaComponent(0.2).cgColor
        }
        undoButton?.isEnabled = canvas.canUndo
        redoButton?.isEnabled = canvas.canRedo
        cropBar?.isHidden = !canvas.hasCropSelection
        window?.title = "Cadre — \(canvas.baseImage.width) × \(canvas.baseImage.height)"
    }

    // MARK: - Eylemler

    @objc private func selectTool(_ sender: NSButton) {
        guard sender.tag < Tool.allCases.count else { return }
        canvas.commitTextEditor()
        canvas.tool = Tool.allCases[sender.tag]
        window?.makeFirstResponder(canvas)
        refreshControls()
    }

    @objc private func selectColor(_ sender: NSButton) {
        guard sender.tag < palette.count else { return }
        canvas.style.color = palette[sender.tag]
        refreshControls()
    }

    @objc private func changeThickness(_ sender: NSSlider) {
        canvas.style.lineWidth = CGFloat(sender.doubleValue)
        canvas.style.fontSize = 14 + CGFloat(sender.doubleValue) * 3
    }

    @objc private func changeTextPreset(_ sender: NSPopUpButton) {
        canvas.style.textPreset = TextPreset.allCases[sender.indexOfSelectedItem]
    }

    /// Düzenleyici koyu ve açık tema arasında geçer. Seçim tercihlerde saklanır.
    @objc private func toggleTheme() {
        let dark = window?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let next: NSAppearance.Name = dark ? .aqua : .darkAqua
        window?.appearance = NSAppearance(named: next)
        Settings.shared.editorUsesDarkTheme = (next == .darkAqua)
    }

    /// Seçilen görüntüleri geçerli görüntünün altına ekler.
    @objc private func combineImages() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff]
        panel.directoryURL = Settings.shared.saveDirectory
        panel.message = "Choose images to add below"

        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, !panel.urls.isEmpty else { return }
            let images = panel.urls.compactMap { url -> CGImage? in
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                return CGImageSourceCreateImageAtIndex(source, 0, nil)
            }
            guard !images.isEmpty else {
                Notifier.show("Could not read the images.", isError: true)
                return
            }
            self.canvas.append(images: images)
            self.refreshControls()
        }
    }

    @objc private func toggleFill(_ sender: NSButton) {
        canvas.style.filled = sender.state == .on
    }

    @objc private func undo() { canvas.undo() }
    @objc private func redoAction() { canvas.redo() }
    @objc private func clearAll() { canvas.clearAll() }
    @objc private func applyCrop() { canvas.applyCrop(); refreshControls() }
    @objc private func cancelCrop() { canvas.cancelCrop(); refreshControls() }

    private func currentShot() -> Shot? {
        guard let image = canvas.flattenedImage() else {
            Notifier.show("Could not prepare the image.", isError: true)
            return nil
        }
        var result = Shot(image: image, sourceRect: shot.sourceRect, capturedAt: shot.capturedAt)
        result.savedURL = shot.savedURL
        return result
    }

    @objc private func toggleBackground(_ sender: NSButton) {
        let on = sender.state == .on
        backgroundRow?.isHidden = !on
        canvas.background.enabled = on
        refreshControls()
    }

    @objc private func selectBackgroundPreset(_ sender: NSButton) {
        guard sender.tag < CanvasBackground.presets.count else { return }
        canvas.background.fill = CanvasBackground.presets[sender.tag].fill
        refreshControls()
    }

    @objc private func changePadding(_ sender: NSSlider) {
        canvas.background.padding = CGFloat(sender.doubleValue)
    }

    @objc private func changeCorner(_ sender: NSSlider) {
        canvas.background.cornerRadius = CGFloat(sender.doubleValue)
    }

    @objc private func changeShadow(_ sender: NSSlider) {
        canvas.background.shadowOpacity = CGFloat(sender.doubleValue)
    }

    @objc private func changeAspect(_ sender: NSPopUpButton) {
        canvas.background.aspect = AspectPreset.allCases[sender.indexOfSelectedItem]
    }

    @objc private func pinImage() {
        guard let result = currentShot() else { return }
        PinnedShotWindow.pin(result)
    }

    @objc private func copyImage() {
        guard let result = currentShot() else { return }
        result.copyToClipboard()
        Notifier.show("Copied to clipboard")
    }

    @objc private func saveImage() {
        guard let result = currentShot() else { return }
        do {
            let url = try result.save()
            shot.savedURL = url
            Notifier.show("Saved", detail: url.lastPathComponent)
        } catch {
            Notifier.show(error: error)
        }
    }

    @objc private func saveImageAs() {
        guard let window, let result = currentShot() else { return }
        let format = Settings.shared.format
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(Shot.defaultFileName()).\(format.fileExtension)"
        panel.directoryURL = Settings.shared.saveDirectory
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url,
                  let data = result.data(format: format) else { return }
            do {
                try data.write(to: url, options: .atomic)
                Notifier.show("Saved", detail: url.lastPathComponent)
            } catch {
                Notifier.show(error: error)
            }
        }
    }

    @objc private func share(_ sender: NSButton) {
        guard let result = currentShot(), let url = TempFiles.write(result) else { return }
        let picker = NSSharingServicePicker(items: [url])
        picker.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    // MARK: - Pencere

    func windowWillClose(_ notification: Notification) {
        EditorWindowController.openControllers.removeAll { $0 === self }
    }
}
