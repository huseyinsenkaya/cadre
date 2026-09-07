import Foundation
import ServiceManagement

/// Oturum açılışında başlatma.
///
/// Durum UserDefaults'ta tutulmaz. Kullanıcı kaydı Sistem Ayarları → Genel →
/// Oturum Açma Ögeleri altından da kapatabilir; tek doğru kaynak macOS'un kendisidir.
enum LoginItem {

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Başarılı olursa `nil`, olmazsa hatayı döndürür. Çağıran anahtarı geri almalıdır.
    static func setEnabled(_ enabled: Bool) -> Error? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else if SMAppService.mainApp.status != .notRegistered {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error
        }
    }
}
