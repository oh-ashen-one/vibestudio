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

    private let videoQueue = DispatchQueue(label: "dev.vibestudio.capture.screen.video")
    private let audioQueue = DispatchQueue(label: "dev.vibestudio.capture.screen.audio")
    private let clock: SharedPauseClock

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var sessionStarted = false

    private(set) var firstVideoHostSeconds: Double?
    private(set) var firstAudioHostSeconds: Double?

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

        let stream = SCStream(filter: filter, configuration: streamConfig, delegate: nil)
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

        try await stream.startCapture()
    }

    func finish() async throws {
        if let stream { try? await stream.stopCapture() }
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        if let writer {
            await writer.finishWriting()
            if writer.status == .failed {
                throw writer.error ?? RecorderError.writerFailed
            }
        }
        stream = nil
        writer = nil
        videoInput = nil
        audioInput = nil
    }

    func abort() async {
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
        guard let writer, input.isReadyForMoreMediaData else { return }
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
        input.append(copy)
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
