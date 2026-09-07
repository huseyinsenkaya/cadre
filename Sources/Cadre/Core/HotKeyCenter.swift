import AppKit
import Carbon.HIToolbox

enum HotKeyAction: String, CaseIterable {
    case captureArea
    case captureWindow
    case captureFullScreen
    case captureLastArea
    case captureAllInOne
    case captureScrolling
    case recordScreen
    case recognizeText
    case closePinned
    case quitApp

    var title: String {
        switch self {
        case .captureArea: return "Capture Area"
        case .captureWindow: return "Capture Window"
        case .captureFullScreen: return "Capture Full Screen"
        case .captureLastArea: return "Repeat Last Area"
        case .captureAllInOne: return "All In One"
        case .captureScrolling: return "Scrolling Capture"
        case .recordScreen: return "Record Screen"
        case .recognizeText: return "Recognize Text"
        case .closePinned: return "Close Pinned Shots"
        case .quitApp: return "Quit Cadre"
        }
    }

    /// macOS ⌘⇧4 tuşunu kendi ekran görüntüsü aracı için tutar. Sistem onu bırakmazsa
    /// kayıt başarısız olur; o durumda uygulama bu yedeğe döner ve kullanılabilir kalır.
    var fallbackBinding: HotKeyBinding? {
        switch self {
        case .captureArea: return HotKeyBinding(keyCode: UInt32(kVK_ANSI_4), modifiers: controlKey | shiftKey)
        default: return nil
        }
    }

    var defaultBinding: HotKeyBinding? {
        switch self {
        case .captureArea: return HotKeyBinding(keyCode: UInt32(kVK_ANSI_4), modifiers: cmdKey | shiftKey)
        case .captureWindow: return HotKeyBinding(keyCode: UInt32(kVK_ANSI_5), modifiers: controlKey | shiftKey)
        case .captureFullScreen: return HotKeyBinding(keyCode: UInt32(kVK_ANSI_3), modifiers: controlKey | shiftKey)
        case .captureLastArea: return HotKeyBinding(keyCode: UInt32(kVK_ANSI_6), modifiers: controlKey | shiftKey)
        case .captureAllInOne: return HotKeyBinding(keyCode: UInt32(kVK_ANSI_2), modifiers: controlKey | shiftKey)
        case .captureScrolling: return HotKeyBinding(keyCode: UInt32(kVK_ANSI_1), modifiers: controlKey | shiftKey)
        case .recordScreen: return HotKeyBinding(keyCode: UInt32(kVK_ANSI_7), modifiers: controlKey | shiftKey)
        case .recognizeText: return HotKeyBinding(keyCode: UInt32(kVK_ANSI_8), modifiers: controlKey | shiftKey)
        case .closePinned: return HotKeyBinding(keyCode: UInt32(kVK_ANSI_0), modifiers: controlKey | shiftKey)
        case .quitApp: return HotKeyBinding(keyCode: UInt32(kVK_Escape), modifiers: controlKey | shiftKey)
        }
    }
}

struct HotKeyBinding: Equatable {
    let keyCode: UInt32
    let modifiers: Int

    var storage: String { "\(keyCode):\(modifiers)" }

    init(keyCode: UInt32, modifiers: Int) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init?(storage: String) {
        let parts = storage.split(separator: ":")
        guard parts.count == 2, let code = UInt32(parts[0]), let mods = Int(parts[1]) else { return nil }
        self.keyCode = code
        self.modifiers = mods
    }

    init(event: NSEvent) {
        self.keyCode = UInt32(event.keyCode)
        var mods = 0
        if event.modifierFlags.contains(.command) { mods |= cmdKey }
        if event.modifierFlags.contains(.shift) { mods |= shiftKey }
        if event.modifierFlags.contains(.option) { mods |= optionKey }
        if event.modifierFlags.contains(.control) { mods |= controlKey }
        self.modifiers = mods
    }

    var cocoaModifiers: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & cmdKey != 0 { flags.insert(.command) }
        if modifiers & shiftKey != 0 { flags.insert(.shift) }
        if modifiers & optionKey != 0 { flags.insert(.option) }
        if modifiers & controlKey != 0 { flags.insert(.control) }
        return flags
    }

    var displayString: String {
        var text = ""
        if modifiers & controlKey != 0 { text += "⌃" }
        if modifiers & optionKey != 0 { text += "⌥" }
        if modifiers & shiftKey != 0 { text += "⇧" }
        if modifiers & cmdKey != 0 { text += "⌘" }
        return text + KeyCodeNames.name(for: keyCode)
    }
}

enum KeyCodeNames {
    private static let table: [UInt32: String] = [
        UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C",
        UInt32(kVK_ANSI_D): "D", UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
        UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_I): "I",
        UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
        UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O",
        UInt32(kVK_ANSI_P): "P", UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
        UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T", UInt32(kVK_ANSI_U): "U",
        UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
        UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z",
        UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1", UInt32(kVK_ANSI_2): "2",
        UInt32(kVK_ANSI_3): "3", UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5",
        UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7", UInt32(kVK_ANSI_8): "8",
        UInt32(kVK_ANSI_9): "9",
        UInt32(kVK_Space): "Space", UInt32(kVK_Return): "↩", UInt32(kVK_Escape): "⎋",
        UInt32(kVK_Tab): "⇥", UInt32(kVK_Delete): "⌫",
        UInt32(kVK_LeftArrow): "←", UInt32(kVK_RightArrow): "→",
        UInt32(kVK_UpArrow): "↑", UInt32(kVK_DownArrow): "↓",
        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3",
        UInt32(kVK_F4): "F4", UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6",
        UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8", UInt32(kVK_F9): "F9",
        UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
        UInt32(kVK_ANSI_Minus): "-", UInt32(kVK_ANSI_Equal): "=",
        UInt32(kVK_ANSI_LeftBracket): "[", UInt32(kVK_ANSI_RightBracket): "]",
        UInt32(kVK_ANSI_Backslash): "\\", UInt32(kVK_ANSI_Semicolon): ";",
        UInt32(kVK_ANSI_Quote): "'", UInt32(kVK_ANSI_Comma): ",",
        UInt32(kVK_ANSI_Period): ".", UInt32(kVK_ANSI_Slash): "/",
        UInt32(kVK_ANSI_Grave): "`",
    ]

    static func name(for keyCode: UInt32) -> String {
        table[keyCode] ?? "Key \(keyCode)"
    }
}

/// Carbon `RegisterEventHotKey` sarmalayıcısı. NSEvent global monitor'ün aksine
/// Erişilebilirlik izni istemez ve tuşu diğer uygulamalara sızdırmaz.
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var handlers: [UInt32: () -> Void] = [:]
    private var registered: [UInt32: EventHotKeyRef] = [:]
    private var nextID: UInt32 = 1
    private var eventHandler: EventHandlerRef?

    private init() { installHandler() }

    private func installHandler() {
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return noErr }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr else { return status }
            let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
            center.fire(id: hotKeyID.id)
            return noErr
        }
        InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
    }

    private func fire(id: UInt32) {
        guard let handler = handlers[id] else { return }
        DispatchQueue.main.async(execute: handler)
    }

    func unregisterAll() {
        for (_, ref) in registered { UnregisterEventHotKey(ref) }
        registered.removeAll()
        handlers.removeAll()
        nextID = 1
    }

    @discardableResult
    func register(_ binding: HotKeyBinding, handler: @escaping () -> Void) -> Bool {
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4B534954), id: id)  // 'KSIT'
        let status = RegisterEventHotKey(
            binding.keyCode,
            UInt32(binding.modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else { return false }
        registered[id] = ref
        handlers[id] = handler
        return true
    }
}
