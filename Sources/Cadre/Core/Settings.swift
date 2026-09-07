import Foundation
import AppKit

enum ImageFormat: String, CaseIterable {
    case png, jpg, heic

    var fileExtension: String { rawValue }

    var title: String {
        switch self {
        case .png: return "PNG"
        case .jpg: return "JPEG"
        case .heic: return "HEIC"
        }
    }
}

enum AfterCapture: String, CaseIterable {
    case overlay, editor, copyOnly, saveOnly

    var title: String {
        switch self {
        case .overlay: return "Show a small preview in the corner"
        case .editor: return "Open the editor directly"
        case .copyOnly: return "Copy to the clipboard only"
        case .saveOnly: return "Save to disk only"
        }
    }
}

/// Tek bir yerden okunan tercihler. Değişiklik `didChange` ile yayılır.
final class Settings {
    static let shared = Settings()

    static let didChange = Notification.Name("cadre.settings.changed")

    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [
            "format": ImageFormat.png.rawValue,
            "jpegQuality": 0.9,
            "afterCapture": AfterCapture.overlay.rawValue,
            "copyToClipboard": true,
            "saveToDisk": true,
            "playSound": true,
            "showCursor": false,
            "hideDesktopIcons": false,
            "timerSeconds": 0,
            "overlaySeconds": 8.0,
            "recordMicrophone": false,
            "recordSystemAudio": true,
            "usesDoNotDisturb": false,
            "showsClicks": true,
            "showsKeystrokes": false,
            "showsCamera": false,
            "cameraSize": 200,
            "clickColor": "sari",
            "gifFrameRate": 15,
            "editorUsesDarkTheme": false,
            "showsDockIcon": true,
            "confirmBeforeCapture": false,
            "keepHistory": true,
            "freezeScreen": false,
            "combineSpacing": 12,
        ])
    }

    private func notifyChange() {
        NotificationCenter.default.post(name: Settings.didChange, object: nil)
    }

    var format: ImageFormat {
        get { ImageFormat(rawValue: defaults.string(forKey: "format") ?? "") ?? .png }
        set { defaults.set(newValue.rawValue, forKey: "format"); notifyChange() }
    }

    var jpegQuality: Double {
        get { defaults.double(forKey: "jpegQuality") }
        set { defaults.set(newValue, forKey: "jpegQuality"); notifyChange() }
    }

    var afterCapture: AfterCapture {
        get { AfterCapture(rawValue: defaults.string(forKey: "afterCapture") ?? "") ?? .overlay }
        set { defaults.set(newValue.rawValue, forKey: "afterCapture"); notifyChange() }
    }

    var copyToClipboard: Bool {
        get { defaults.bool(forKey: "copyToClipboard") }
        set { defaults.set(newValue, forKey: "copyToClipboard"); notifyChange() }
    }

    var saveToDisk: Bool {
        get { defaults.bool(forKey: "saveToDisk") }
        set { defaults.set(newValue, forKey: "saveToDisk"); notifyChange() }
    }

    var playSound: Bool {
        get { defaults.bool(forKey: "playSound") }
        set { defaults.set(newValue, forKey: "playSound"); notifyChange() }
    }

    var showCursor: Bool {
        get { defaults.bool(forKey: "showCursor") }
        set { defaults.set(newValue, forKey: "showCursor"); notifyChange() }
    }

    /// Kapalıyken yakalama hiçbir kopya bırakmaz ve Recent Captures listesi boş kalır.
    var keepHistory: Bool {
        get { defaults.bool(forKey: "keepHistory") }
        set { defaults.set(newValue, forKey: "keepHistory"); notifyChange() }
    }

    var hideDesktopIcons: Bool {
        get { defaults.bool(forKey: "hideDesktopIcons") }
        set { defaults.set(newValue, forKey: "hideDesktopIcons"); notifyChange() }
    }

    var timerSeconds: Int {
        get { defaults.integer(forKey: "timerSeconds") }
        set { defaults.set(newValue, forKey: "timerSeconds"); notifyChange() }
    }

    var overlaySeconds: Double {
        get { defaults.double(forKey: "overlaySeconds") }
        set { defaults.set(newValue, forKey: "overlaySeconds"); notifyChange() }
    }

    /// Kayıt sırasında Odak kipini açar. Kısayollar uygulamasında iki kısayol ister.
    var usesDoNotDisturb: Bool {
        get { defaults.bool(forKey: "usesDoNotDisturb") }
        set { defaults.set(newValue, forKey: "usesDoNotDisturb"); notifyChange() }
    }

    var recordSystemAudio: Bool {
        get { defaults.bool(forKey: "recordSystemAudio") }
        set { defaults.set(newValue, forKey: "recordSystemAudio"); notifyChange() }
    }

    var showsClicks: Bool {
        get { defaults.bool(forKey: "showsClicks") }
        set { defaults.set(newValue, forKey: "showsClicks"); notifyChange() }
    }

    var showsKeystrokes: Bool {
        get { defaults.bool(forKey: "showsKeystrokes") }
        set { defaults.set(newValue, forKey: "showsKeystrokes"); notifyChange() }
    }

    var showsCamera: Bool {
        get { defaults.bool(forKey: "showsCamera") }
        set { defaults.set(newValue, forKey: "showsCamera"); notifyChange() }
    }

    var cameraSize: Int {
        get { defaults.integer(forKey: "cameraSize") }
        set { defaults.set(newValue, forKey: "cameraSize"); notifyChange() }
    }

    var recordMicrophone: Bool {
        get { defaults.bool(forKey: "recordMicrophone") }
        set { defaults.set(newValue, forKey: "recordMicrophone"); notifyChange() }
    }

    /// Menü çubuğu dolu olduğunda simge çentiğin altında kalabilir.
    /// Dock simgesi uygulamaya ulaşan ikinci yoldur.
    var showsDockIcon: Bool {
        get { defaults.bool(forKey: "showsDockIcon") }
        set { defaults.set(newValue, forKey: "showsDockIcon"); notifyChange() }
    }

    /// Açıkken seçimden sonra onay düğmeleri çıkar ve seçim düzeltilebilir.
    /// Kapalıyken fare bırakılır bırakılmaz yakalanır. En sık kullanılan akış budur.
    /// Açıkken seçim başlarken ekranın tamamı yakalanır ve katmanın altına serilir.
    /// Büyüteç ve renk okuma bunu gerektirir, ama katman açılmadan önce her ekranı
    /// tam çözünürlükte yakalamak gözle görülür bir gecikme yapar. Öntanımlı kapalı.
    var freezeScreen: Bool {
        get { defaults.bool(forKey: "freezeScreen") }
        set { defaults.set(newValue, forKey: "freezeScreen"); notifyChange() }
    }

    var confirmBeforeCapture: Bool {
        get { defaults.bool(forKey: "confirmBeforeCapture") }
        set { defaults.set(newValue, forKey: "confirmBeforeCapture"); notifyChange() }
    }

    var editorUsesDarkTheme: Bool {
        get { defaults.bool(forKey: "editorUsesDarkTheme") }
        set { defaults.set(newValue, forKey: "editorUsesDarkTheme"); notifyChange() }
    }

    /// Birleştirilen görüntüler arasındaki boşluk.
    var combineSpacing: Int {
        get { defaults.integer(forKey: "combineSpacing") }
        set { defaults.set(newValue, forKey: "combineSpacing"); notifyChange() }
    }

    var gifFrameRate: Int {
        get { defaults.integer(forKey: "gifFrameRate") }
        set { defaults.set(newValue, forKey: "gifFrameRate"); notifyChange() }
    }

    /// Güvenlik kapsamlı yer imi: kullanıcı klasörü seçtiğinde erişim yeniden başlatmadan sonra da sürsün.
    var saveDirectory: URL {
        get {
            if let data = defaults.data(forKey: "saveDirectoryBookmark") {
                var stale = false
                if let url = try? URL(
                    resolvingBookmarkData: data,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &stale
                ) {
                    return url
                }
            }
            return FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser
        }
        set {
            if let data = try? newValue.bookmarkData(options: .withSecurityScope) {
                defaults.set(data, forKey: "saveDirectoryBookmark")
            }
            defaults.set(newValue.path, forKey: "saveDirectoryPath")
            notifyChange()
        }
    }

    var saveDirectoryDisplayPath: String {
        (defaults.string(forKey: "saveDirectoryPath") ?? saveDirectory.path)
            .replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    func hotKey(for action: HotKeyAction) -> HotKeyBinding? {
        guard let raw = defaults.string(forKey: "hotkey." + action.rawValue) else {
            return action.defaultBinding
        }
        if raw.isEmpty { return nil }
        return HotKeyBinding(storage: raw)
    }

    func setHotKey(_ binding: HotKeyBinding?, for action: HotKeyAction) {
        defaults.set(binding?.storage ?? "", forKey: "hotkey." + action.rawValue)
        notifyChange()
    }
}
