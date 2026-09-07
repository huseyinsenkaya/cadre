import AppKit
import Carbon.HIToolbox

/// Tek bir kısayolu yakalayan düğme. Tıklanınca bir sonraki tuş birleşimini alır.
final class HotKeyRecorderView: NSButton {

    private let hotKeyAction: HotKeyAction
    private var monitor: Any?
    private var listening = false {
        didSet { refresh() }
    }

    init(action: HotKeyAction) {
        self.hotKeyAction = action
        super.init(frame: .zero)
        bezelStyle = .texturedRounded
        target = self
        self.action = #selector(startListening)
        refresh()
        widthAnchor.constraint(equalToConstant: 130).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    private func refresh() {
        if listening {
            title = "Press a key…"
        } else if let binding = Settings.shared.hotKey(for: hotKeyAction) {
            title = binding.displayString
        } else {
            title = "None"
        }
    }

    @objc private func startListening() {
        guard !listening else {
            stopListening()
            return
        }
        listening = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, event.type == .keyDown else { return event }

            if Int(event.keyCode) == kVK_Escape {
                self.stopListening()
                return nil
            }
            if Int(event.keyCode) == kVK_Delete {
                Settings.shared.setHotKey(nil, for: self.hotKeyAction)
                self.stopListening()
                return nil
            }

            let binding = HotKeyBinding(event: event)
            // Değiştirici tuşsuz bir kısayol her yazıya karışır.
            guard binding.modifiers != 0 else { return nil }

            Settings.shared.setHotKey(binding, for: self.hotKeyAction)
            self.stopListening()
            return nil
        }
    }

    private func stopListening() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        listening = false
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}
