import AppKit
import AVKit
import AVFoundation

/// Kaydedilmiş videoyu kırpar, sesini ayarlar ve yeniden dışa aktarır.
@MainActor
final class VideoTrimWindow: NSWindowController {

    private static var openControllers: [VideoTrimWindow] = []

    private let sourceURL: URL
    private let player: AVPlayer
    private var duration: Double = 0

    private let startSlider = NSSlider()
    private let endSlider = NSSlider()
    private let volumeSlider = NSSlider()
    private let rangeLabel = NSTextField(labelWithString: "")
    private let resolution = NSPopUpButton()
    private let exportButton = NSButton()

    /// Dışa aktarma sırasında dosya yeniden yazılmasın diye tek seferlik kilit.
    private var exporting = false

    private let presets: [(title: String, preset: String)] = [
        ("Original size", AVAssetExportPresetHighestQuality),
        ("1080p", AVAssetExportPreset1920x1080),
        ("720p", AVAssetExportPreset1280x720),
        ("540p", AVAssetExportPreset960x540),
    ]

    static func open(videoURL: URL) {
        let controller = VideoTrimWindow(videoURL: videoURL)
        openControllers.append(controller)
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init(videoURL: URL) {
        self.sourceURL = videoURL
        self.player = AVPlayer(url: videoURL)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Cadre — \(videoURL.lastPathComponent)"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)

        buildContent()
        loadDuration()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Yerleşim

    private func buildContent() {
        guard let window else { return }

        let playerView = AVPlayerView()
        playerView.player = player
        playerView.controlsStyle = .inline
        playerView.translatesAutoresizingMaskIntoConstraints = false

        rangeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        rangeLabel.textColor = .secondaryLabelColor

        for slider in [startSlider, endSlider] {
            slider.minValue = 0
            slider.maxValue = 1
            slider.target = self
            slider.action = #selector(rangeChanged(_:))
            slider.controlSize = .small
        }
        startSlider.doubleValue = 0
        endSlider.doubleValue = 1

        volumeSlider.minValue = 0
        volumeSlider.maxValue = 1
        volumeSlider.doubleValue = 1
        volumeSlider.controlSize = .small
        volumeSlider.target = self
        volumeSlider.action = #selector(volumeChanged(_:))
        volumeSlider.widthAnchor.constraint(equalToConstant: 110).isActive = true

        resolution.addItems(withTitles: presets.map(\.title))

        exportButton.title = "Export"
        exportButton.bezelStyle = .texturedRounded
        exportButton.target = self
        exportButton.action = #selector(export)
        exportButton.keyEquivalent = "\r"

        let controls = NSStackView(views: [
            labelled("Start", startSlider),
            labelled("End", endSlider),
            labelled("Volume", volumeSlider),
            labelled("Resolution", resolution),
            NSView(),
            exportButton,
        ])
        controls.orientation = .horizontal
        controls.spacing = 12
        controls.alignment = .bottom
        controls.translatesAutoresizingMaskIntoConstraints = false

        rangeLabel.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(playerView)
        root.addSubview(rangeLabel)
        root.addSubview(controls)

        NSLayoutConstraint.activate([
            playerView.topAnchor.constraint(equalTo: root.topAnchor),
            playerView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            playerView.bottomAnchor.constraint(equalTo: rangeLabel.topAnchor, constant: -8),

            rangeLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            rangeLabel.bottomAnchor.constraint(equalTo: controls.topAnchor, constant: -6),

            controls.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            controls.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            controls.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
        ])

        window.contentView = root
    }

    private func labelled(_ title: String, _ control: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 10)
        label.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [label, control])
        stack.orientation = .vertical
        stack.spacing = 1
        stack.alignment = .leading
        return stack
    }

    private func loadDuration() {
        Task { @MainActor in
            let asset = AVURLAsset(url: sourceURL)
            guard let value = try? await asset.load(.duration) else { return }
            duration = CMTimeGetSeconds(value)
            updateRangeLabel()
        }
    }

    // MARK: - Denetimler

    private var startSeconds: Double { startSlider.doubleValue * duration }
    private var endSeconds: Double { endSlider.doubleValue * duration }

    @objc private func rangeChanged(_ sender: NSSlider) {
        // Bitiş başlangıcın gerisine düşerse aralık ters çevrilir ve dışa aktarma boş çıkar.
        if endSlider.doubleValue <= startSlider.doubleValue + 0.01 {
            if sender === startSlider {
                startSlider.doubleValue = max(0, endSlider.doubleValue - 0.01)
            } else {
                endSlider.doubleValue = min(1, startSlider.doubleValue + 0.01)
            }
        }
        updateRangeLabel()
        let target = sender === startSlider ? startSeconds : endSeconds
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }

    @objc private func volumeChanged(_ sender: NSSlider) {
        player.volume = Float(sender.doubleValue)
    }

    private func updateRangeLabel() {
        guard duration > 0 else { return }
        rangeLabel.stringValue = String(
            format: "%@ – %@  ·  %@ selected",
            format(startSeconds), format(endSeconds), format(endSeconds - startSeconds)
        )
    }

    private func format(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - Dışa aktarma

    @objc private func export() {
        guard !exporting, duration > 0, let window else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = sourceURL.deletingPathExtension().lastPathComponent + " trimmed.mp4"
        panel.directoryURL = Settings.shared.saveDirectory
        panel.canCreateDirectories = true

        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let target = panel.url else { return }
            Task { @MainActor in await self.runExport(to: target) }
        }
    }

    private func runExport(to target: URL) async {
        exporting = true
        exportButton.isEnabled = false
        defer {
            exporting = false
            exportButton.isEnabled = true
        }

        let asset = AVURLAsset(url: sourceURL)
        let presetName = presets[resolution.indexOfSelectedItem].preset

        guard let session = AVAssetExportSession(asset: asset, presetName: presetName) else {
            Notifier.show("Could not set up the export.", isError: true)
            return
        }

        let start = CMTime(seconds: startSeconds, preferredTimescale: 600)
        let end = CMTime(seconds: endSeconds, preferredTimescale: 600)
        session.timeRange = CMTimeRange(start: start, end: end)

        if let audio = try? await asset.loadTracks(withMediaType: .audio).first {
            let parameters = AVMutableAudioMixInputParameters(track: audio)
            parameters.setVolume(Float(volumeSlider.doubleValue), at: .zero)
            let mix = AVMutableAudioMix()
            mix.inputParameters = [parameters]
            session.audioMix = mix
        }

        try? FileManager.default.removeItem(at: target)
        Notifier.show("Exporting…")

        do {
            try await session.export(to: target, as: .mp4)
            Notifier.show("Exported", detail: target.lastPathComponent)
            NSWorkspace.shared.activateFileViewerSelecting([target])
        } catch {
            Notifier.show(error: error)
        }
    }

    func windowWillClose(_ notification: Notification) {
        player.pause()
        VideoTrimWindow.openControllers.removeAll { $0 === self }
    }
}
