import AVFoundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Kaydedilmiş videoyu döngüsüz bir GIF'e çevirir.
enum GIFEncoder {

    static func convert(videoURL: URL, frameRate: Int, maxWidth: CGFloat = 900) async throws -> URL {
        let asset = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)
        guard seconds > 0 else {
            throw NSError(domain: "Cadre", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "The video is empty."])
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        if let track = try await asset.loadTracks(withMediaType: .video).first {
            let size = try await track.load(.naturalSize)
            if size.width > maxWidth {
                let scale = maxWidth / size.width
                generator.maximumSize = CGSize(
                    width: maxWidth,
                    height: (size.height * scale).rounded()
                )
            }
        }

        let step = 1.0 / Double(max(1, frameRate))
        var times: [CMTime] = []
        var current = 0.0
        while current < seconds {
            times.append(CMTime(seconds: current, preferredTimescale: 600))
            current += step
        }
        guard !times.isEmpty else {
            throw NSError(domain: "Cadre", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "No frames found for the GIF."])
        }

        let outputURL = videoURL.deletingPathExtension().appendingPathExtension("gif")
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL, UTType.gif.identifier as CFString, times.count, nil
        ) else {
            throw NSError(domain: "Cadre", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "Could not open the GIF file."])
        }

        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary)

        let frameProperties = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: step]
        ] as CFDictionary

        for time in times {
            guard let image = try? await generator.image(at: time).image else { continue }
            CGImageDestinationAddImage(destination, image, frameProperties)
        }

        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "Cadre", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "Could not write the GIF."])
        }
        return outputURL
    }
}
