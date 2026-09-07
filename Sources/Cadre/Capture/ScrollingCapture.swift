import AppKit
import CoreGraphics

/// Seçilen alanı kullanıcı kaydırdıkça yakalar ve tek uzun görüntüye diker.
///
/// Otomatik kaydırma sentetik olay göndermeyi gerektirir, o da Erişilebilirlik izni ister.
/// Elle kaydırma kipi ek izin istemez: kullanıcı kaydırır, burası art arda kare alır ve
/// yeni gelen satırları ekler.
@MainActor
final class ScrollingCapture {

    static let shared = ScrollingCapture()

    private var timer: Timer?
    private var region: CGRect = .zero
    private var pieces: [CGImage] = []
    private var lastSignature: [Double] = []
    private var hud: ScrollingHUD?
    private var busy = false

    private init() {}

    var isRunning: Bool { timer != nil }

    // MARK: - Akış

    func begin() {
        guard !isRunning else { finishAndBuild(); return }

        Task { @MainActor in
            let overlay = SelectionOverlayController(mode: .area)
            await overlay.present { [weak self] result, image in
                guard let self else { return }
                guard case .rect(let rect) = result, let image else { return }
                Task { @MainActor in self.start(region: rect, first: image) }
            }
        }
    }

    private func start(region: CGRect, first: CGImage) {
        self.region = region
        pieces = [first]
        lastSignature = ScrollingCapture.signature(of: first)

        hud = ScrollingHUD(near: region) { [weak self] in
            self?.finishAndBuild()
        } onCancel: { [weak self] in
            self?.abort()
        }

        let timer = Timer(timeInterval: 0.28, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        Notifier.show("Start scrolling", detail: "Press Return when you are done")
    }

    private func tick() {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            guard let frame = try? await CaptureEngine.capture(cocoaRect: region) else { return }
            append(frame)
        }
    }

    /// Yeni karenin üst kısmı bir öncekinin altıyla örtüşür. Örtüşme bulunur,
    /// yalnız altta kalan yeni satırlar eklenir.
    private func append(_ frame: CGImage) {
        let incoming = ScrollingCapture.signature(of: frame)
        guard !incoming.isEmpty, !lastSignature.isEmpty else { return }

        let newRows = ScrollingCapture.newRowCount(previous: lastSignature, incoming: incoming)
        guard newRows > 0 else { return }

        let cropHeight = min(newRows, frame.height)
        let crop = CGRect(
            x: 0,
            y: frame.height - cropHeight,
            width: frame.width,
            height: cropHeight
        )
        guard let piece = frame.cropping(to: crop) else { return }

        pieces.append(piece)
        lastSignature = incoming
        hud?.update(pieceCount: pieces.count)
    }

    private func abort() {
        stopTimer()
        pieces.removeAll()
        Notifier.show("Scrolling capture cancelled.")
    }

    private func finishAndBuild() {
        stopTimer()
        guard pieces.count > 1, let stitched = ScrollingCapture.compose(pieces) else {
            Notifier.show("No new content captured.", isError: true)
            pieces.removeAll()
            return
        }
        let result = pieces
        pieces.removeAll()
        _ = result
        CaptureCoordinator.shared.finish(Shot(image: stitched, sourceRect: region))
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        hud?.close()
        hud = nil
    }

    // MARK: - Dikme

    /// Her satır için örneklenmiş piksellerin ortalaması. Satır dizisi, kaydırma
    /// miktarını bulmak için kullanılan parmak izidir.
    static func signature(of image: CGImage) -> [Double] {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return [] }

        let sampleCount = min(48, width)
        let step = max(1, width / sampleCount)
        let bytesPerRow = width * 4

        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return [] }
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let context = buffer.withUnsafeMutableBytes({ pointer -> CGContext? in
            CGContext(
                data: pointer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        }) else { return [] }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var rows = [Double](repeating: 0, count: height)
        for y in 0..<height {
            var total = 0
            var count = 0
            var x = 0
            while x < width {
                let index = y * bytesPerRow + x * 4
                total += Int(buffer[index]) + Int(buffer[index + 1]) + Int(buffer[index + 2])
                count += 1
                x += step
            }
            rows[y] = count > 0 ? Double(total) / Double(count) : 0
        }
        return rows
    }

    /// Önceki karenin son satırlarını yeni karede arar. Bulunan yerin altında
    /// kalan satır sayısı, eklenecek yeni içeriktir.
    static func newRowCount(previous: [Double], incoming: [Double]) -> Int {
        let height = incoming.count
        guard previous.count == height, height > 40 else { return 0 }

        let probe = min(32, height / 4)
        let pattern = Array(previous.suffix(probe))

        var bestOffset = 0
        var bestScore = Double.greatestFiniteMagnitude

        // Kaydırma yukarıdan aşağıya olduğu için desen yeni karede daha yukarıda çıkar.
        for offset in 0...(height - probe) {
            var score = 0.0
            for index in 0..<probe {
                score += abs(pattern[index] - incoming[offset + index])
                if score >= bestScore { break }
            }
            if score < bestScore {
                bestScore = score
                bestOffset = offset
            }
        }

        // Eşleşme zayıfsa kare atlanır: yanlış hizalama uzun görüntüyü bozar.
        let tolerance = 2.5 * Double(probe)
        guard bestScore < tolerance else { return 0 }

        let matchedEnd = bestOffset + probe
        return max(0, height - matchedEnd)
    }

    static func compose(_ pieces: [CGImage]) -> CGImage? {
        guard let first = pieces.first else { return nil }
        let width = first.width
        let totalHeight = pieces.reduce(0) { $0 + $1.height }
        guard totalHeight > 0 else { return nil }

        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: totalHeight,
                bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        // CGContext sol-alt orijinlidir; parçalar üstten aşağı sıralı olduğu için tersten çizilir.
        var y = totalHeight
        for piece in pieces {
            y -= piece.height
            context.draw(
                piece,
                in: CGRect(x: 0, y: y, width: piece.width, height: piece.height)
            )
        }
        return context.makeImage()
    }
}

/// Kaydırma sürerken ekranda duran denetim.
@MainActor
final class ScrollingHUD {

    private var window: NSWindow?
    private let label = NSTextField(labelWithString: "1 piece")

    init(near rect: CGRect, onFinish: @escaping () -> Void, onCancel: @escaping () -> Void) {
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        label.textColor = .white

        let title = NSTextField(labelWithString: "Scroll, then press Finish")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = .white

        let finish = NSButton(title: "Finish", target: nil, action: nil)
        finish.bezelStyle = .texturedRounded
        finish.keyEquivalent = "\r"
        finish.onAction = onFinish

        let cancel = NSButton(title: "Cancel", target: nil, action: nil)
        cancel.bezelStyle = .texturedRounded
        cancel.onAction = onCancel

        let stack = NSStackView(views: [title, label, finish, cancel])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 10)

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])

        let size = background.fittingSize
        let screen = CoordinateSpace.screen(containing: rect) ?? NSScreen.main
        let origin = CGPoint(
            x: rect.midX - size.width / 2,
            y: max((screen?.visibleFrame.minY ?? 0) + 16, rect.minY - size.height - 14)
        )

        let window = NSWindow(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = background
        window.level = .statusBar
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        window.orderFrontRegardless()
        self.window = window
    }

    func update(pieceCount: Int) {
        label.stringValue = "\(pieceCount) pieces"
    }

    func close() {
        window?.orderOut(nil)
        window = nil
    }
}
