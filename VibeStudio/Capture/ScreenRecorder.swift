import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

enum RecorderError: Error {
    case cannotAddInput
    case writerFailed
    case missingSelection
    case unsupportedMode
}

/// ScreenCaptureKit -> H.264 .mov via AVAssetWriter. Video and system-audio
/// buffers arrive on dedicated serial queues and are appended only when the
/// input is ready (frames are dropped otherwise, never blocked on).
final class ScreenRecorder: NSObject, @unchecked Sendable {
    struct Configuration {
        var pixelWidth: Int
        var pixelHeight: Int
        var frameRate: Int
        var sourceRectPixels: CGRect?
        var captureSystemAudio: Bool
    }

    /// Unbuffered diagnostics — stdout is block-buffered when redirected.
    static func log(_ message: String) {
        FileHandle.standardError.write(Data(("[VibeStudio/screenrec] \(message)\n").utf8))
    }

    private let videoQueue = DispatchQueue(label: "dev.vibestudio.capture.screen.video")
    private let audioQueue = DispatchQueue(label: "dev.vibestudio.capture.screen.audio")
    private let clock: SharedPauseClock

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var sessionStarted = false
    private var diagnosticsTimer: DispatchSourceTimer?

    private(set) var firstVideoHostSeconds: Double?
    private(set) var firstAudioHostSeconds: Double?

    // Pipeline health counters (guarded by each queue's serial execution).
    private var videoReceived = 0
    private var videoAppended = 0
    private var videoDropped = 0
    private var videoFailed = 0
    private var audioReceived = 0
    private var audioAppended = 0
    private var audioDropped = 0
    private var audioFailed = 0

    init(clock: SharedPauseClock) {
        self.clock = clock
    }

    func start(filter: SCContentFilter, configuration cfg: Configuration, outputURL: URL) async throws {
        let streamConfig = SCStreamConfiguration()
        streamConfig.width = cfg.pixelWidth
        streamConfig.height = cfg.pixelHeight
        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(cfg.frameRate))
        streamConfig.pixelFormat = kCVPixelFormatType_32BGRA
        streamConfig.showsCursor = true
        streamConfig.queueDepth = 6
        streamConfig.capturesAudio = cfg.captureSystemAudio
        streamConfig.excludesCurrentProcessAudio = true
        if let rect = cfg.sourceRectPixels {
            streamConfig.sourceRect = rect
        }

        let writer = try AVAssetWriter(url: outputURL, fileType: .mov)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: cfg.pixelWidth,
            AVVideoHeightKey: cfg.pixelHeight,
        ])
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else { throw RecorderError.cannotAddInput }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if cfg.captureSystemAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000,
            ])
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw RecorderError.cannotAddInput }
            writer.add(input)
            audioInput = input
        }

        guard writer.startWriting() else {
            throw writer.error ?? RecorderError.writerFailed
        }

        let stream = SCStream(filter: filter, configuration: streamConfig, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        if cfg.captureSystemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        }

        self.writer = writer
        self.videoInput = videoInput
        self.audioInput = audioInput
        self.stream = stream
        sessionStarted = false
        firstVideoHostSeconds = nil
        firstAudioHostSeconds = nil
        videoReceived = 0; videoAppended = 0; videoDropped = 0; videoFailed = 0
        audioReceived = 0; audioAppended = 0; audioDropped = 0; audioFailed = 0

        try await stream.startCapture()
        Self.log("capture started \(cfg.pixelWidth)x\(cfg.pixelHeight)@\(cfg.frameRate) audio=\(cfg.captureSystemAudio)")
        startDiagnosticsTimer()
    }

    private func startDiagnosticsTimer() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            Self.log("video recv=\(self.videoReceived) appended=\(self.videoAppended) dropped=\(self.videoDropped) failed=\(self.videoFailed) | audio recv=\(self.audioReceived) appended=\(self.audioAppended) dropped=\(self.audioDropped) failed=\(self.audioFailed) | writer=\(self.writer?.status.rawValue ?? -1)")
        }
        timer.resume()
        diagnosticsTimer = timer
    }

    func finish() async throws {
        diagnosticsTimer?.cancel()
        diagnosticsTimer = nil
        if let stream { try? await stream.stopCapture() }
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        if let writer {
            await writer.finishWriting()
            if writer.status == .failed {
                Self.log("FINISH FAILED status=\(writer.status.rawValue) error=\(writer.error?.localizedDescription ?? "nil")")
                throw writer.error ?? RecorderError.writerFailed
            }
            Self.log("finished OK video=\(videoAppended)/\(videoReceived) audio=\(audioAppended)/\(audioReceived)")
        }
        stream = nil
        writer = nil
        videoInput = nil
        audioInput = nil
    }

    func abort() async {
        diagnosticsTimer?.cancel()
        diagnosticsTimer = nil
        if let stream { try? await stream.stopCapture() }
        if let writer, writer.status == .writing { writer.cancelWriting() }
        stream = nil
        writer = nil
        videoInput = nil
        audioInput = nil
    }

    private func retimedCopy(of sampleBuffer: CMSampleBuffer, presentationTimeStamp pts: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(sampleBuffer),
                                        presentationTimeStamp: pts,
                                        decodeTimeStamp: .invalid)
        var output: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: nil,
                                                    sampleBuffer: sampleBuffer,
                                                    sampleTimingEntryCount: 1,
                                                    sampleTimingArray: &timing,
                                                    sampleBufferOut: &output) == noErr else {
            return nil
        }
        return output
    }

    private func append(_ sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput, isVideo: Bool) {
        if isVideo { videoReceived += 1 } else { audioReceived += 1 }
        guard let writer, input.isReadyForMoreMediaData else {
            if isVideo { videoDropped += 1 } else { audioDropped += 1 }
            return
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let hostSeconds = CMTimeGetSeconds(pts)
        let adjusted = CMTime(seconds: clock.adjusted(hostSeconds),
                              preferredTimescale: pts.timescale)
        guard let copy = retimedCopy(of: sampleBuffer, presentationTimeStamp: adjusted) else { return }
        if !sessionStarted {
            writer.startSession(atSourceTime: adjusted)
            sessionStarted = true
        }
        if isVideo {
            if firstVideoHostSeconds == nil { firstVideoHostSeconds = hostSeconds }
        } else {
            if firstAudioHostSeconds == nil { firstAudioHostSeconds = hostSeconds }
        }
        if input.append(copy) {
            if isVideo { videoAppended += 1 } else { audioAppended += 1 }
        } else {
            if isVideo { videoFailed += 1 } else { audioFailed += 1 }
            if (isVideo ? videoFailed : audioFailed) == 1 {
                Self.log("FIRST APPEND FAILURE isVideo=\(isVideo) writerError=\(writer.error?.localizedDescription ?? "nil") writerStatus=\(writer.status.rawValue)")
            }
        }
    }
}

extension ScreenRecorder: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        if clock.isPaused { return }
        switch type {
        case .screen:
            if let videoInput { append(sampleBuffer, to: videoInput, isVideo: true) }
        case .audio:
            if let audioInput { append(sampleBuffer, to: audioInput, isVideo: false) }
        default:
            break
        }
    }
}

extension ScreenRecorder: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Self.log("STREAM STOPPED WITH ERROR: \(error.localizedDescription)")
    }
}
