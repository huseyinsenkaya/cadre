import AppKit
import Vision

/// Ekrandan seçilen alandaki yazıyı okur ve panoya koyar.
@MainActor
enum TextRecognizer {

    static func captureAndRecognize() {
        Task { @MainActor in
            let overlay = SelectionOverlayController(mode: .area)
            await overlay.present { result, image in
                guard case .rect = result, let image else { return }
                Task { await recognize(image) }
            }
        }
    }

    static func recognize(_ image: CGImage) async {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["tr-TR", "en-US"]

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            Notifier.show(error: error)
            return
        }

        let observations = request.results ?? []
        let lines = observations.compactMap { $0.topCandidates(1).first?.string }
        let text = lines.joined(separator: "\n")

        guard !text.isEmpty else {
            Notifier.show("No text found.")
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        Notifier.playShutter()
        Notifier.show("\(lines.count) lines copied to the clipboard", detail: String(text.prefix(70)))
    }
}
