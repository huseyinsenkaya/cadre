import AVFoundation
import ScreenCaptureKit
import AppKit

/// SCStream karelerini doğrudan bir video dosyasına yazar.
/// Kareler ara belleğe alınmaz; uzun kayıtta bellek sabit kalır.
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate {

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var microphoneInput: AVAssetWriterInput?
    private var systemAudioInput: AVAssetWriterInput?
    private var sessionStarted = false
    private let sampleQueue = DispatchQueue(label: "cadre.recorder.samples")
    private let audioQueue = DispatchQueue(label: "cadre.recorder.audio")

    private(set) var outputURL: URL?
    private(set) var startedAt: Date?

    var onFailure: ((Error) -> Void)?

    var isRecording: Bool { stream != nil }

    // MARK: - Başlat

    func start(display: SCDisplay, region: CGRect?, scale: CGFloat) async throws {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()

        let size: CGSize
        if let region {
            config.sourceRect = region
            size = region.size
        } else {
            size = CGSize(width: CGFloat(display.width), height: CGFloat(display.height))
        }

        // H.264 çift sayı olmayan boyutu kabul etmez.
        config.width = Int((size.width * scale).rounded()) & ~1
        config.height = Int((size.height * scale).rounded()) & ~1
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        config.queueDepth = 6
        config.capturesAudio = Settings.shared.recordSystemAudio
        config.captureMicrophone = Settings.shared.recordMicrophone
        config.sampleRate = 48_000
        config.channelCount = 2

        try prepareWriter(width: config.width, height: config.height)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        if Settings.shared.recordSystemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        }
        if Settings.shared.recordMicrophone {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: audioQueue)
        }
        try await stream.startCapture()

        self.stream = stream
        self.startedAt = Date()
    }

    private func prepareWriter(width: Int, height: Int) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Cadre", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(Shot.defaultFileName()).mp4")

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(2_000_000, width * height * 6),
                AVVideoMaxKeyFrameIntervalKey: 60,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else {
            throw NSError(domain: "Cadre", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Could not set up the video writer."])
        }
        writer.add(videoInput)

        // Sistem sesi ve mikrofon ayrı izlerde yazılır. Gerçek zamanlı karıştırma
        // ek gecikme ve kod getirir; oynatıcılar iki izi birlikte çalar.
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ]

        if Settings.shared.recordSystemAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                systemAudioInput = input
            }
        }

        if Settings.shared.recordMicrophone {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                microphoneInput = input
            }
        }

        writer.startWriting()

        self.writer = writer
        self.videoInput = videoInput
        self.outputURL = url
    }

    // MARK: - Durdur

    func stop() async -> URL? {
        guard let stream, let writer, let videoInput else { return nil }
        self.stream = nil

        try? await stream.stopCapture()

        videoInput.markAsFinished()
        systemAudioInput?.markAsFinished()
        microphoneInput?.markAsFinished()

        // Yazıcı hiç kare almadıysa finishWriting takılır.
        guard sessionStarted else {
            writer.cancelWriting()
            reset()
            return nil
        }

        await writer.finishWriting()
        let url = writer.status == .completed ? outputURL : nil
        if writer.status == .failed, let error = writer.error {
            onFailure?(error)
        }
        reset()
        return url
    }

    private func reset() {
        writer = nil
        videoInput = nil
        microphoneInput = nil
        systemAudioInput = nil
        sessionStarted = false
        startedAt = nil
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard CMSampleBufferDataIsReady(sampleBuffer), let writer else { return }

        switch type {
        case .screen:
            guard isComplete(sampleBuffer) else { return }
            if !sessionStarted {
                writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
                sessionStarted = true
            }
            guard let videoInput, videoInput.isReadyForMoreMediaData else { return }
            videoInput.append(sampleBuffer)

        case .audio:
            guard sessionStarted, let systemAudioInput, systemAudioInput.isReadyForMoreMediaData else { return }
            systemAudioInput.append(sampleBuffer)

        case .microphone:
            guard sessionStarted, let microphoneInput, microphoneInput.isReadyForMoreMediaData else { return }
            microphoneInput.append(sampleBuffer)

        default:
            break
        }
    }

    /// Ekran değişmediğinde SCStream "boş" kare gönderir; bunlar dosyaya yazılmaz.
    private func isComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw)
        else { return false }
        return status == .complete
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onFailure?(error)
    }
}
