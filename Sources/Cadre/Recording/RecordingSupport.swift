import AppKit
import AVFoundation

/// macOS Odak kiplerini açıp kapatan genel bir arayüz vermez.
/// Tek güvenilir yol Kısayollar uygulamasıdır: kullanıcı iki kısayol yazar,
/// burası onları çağırır. Kısayol yoksa sessizce geçilir.
enum DoNotDisturb {

    static let enableShortcutName = "Cadre Focus On"
    static let disableShortcutName = "Cadre Focus Off"

    static func setEnabled(_ enabled: Bool) {
        guard Settings.shared.usesDoNotDisturb else { return }
        run(shortcut: enabled ? enableShortcutName : disableShortcutName)
    }

    private static func run(shortcut: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        task.arguments = ["run", shortcut]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
    }
}

/// Kayıt geçmişinde gösterilecek önizleme karesi ve boyut.
enum VideoPoster {

    static func firstFrame(of url: URL) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        let time = CMTime(seconds: 0.1, preferredTimescale: 600)
        return try? await generator.image(at: time).image
    }

    static func size(of url: URL) async -> CGSize {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize)
        else { return .zero }
        return size
    }
}
