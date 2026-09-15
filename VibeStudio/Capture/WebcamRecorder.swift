import AVFoundation
import CoreMedia
import Foundation
import QuartzCore

/// Webcam + microphone -> webcam.mov via its own AVAssetWriter. Mic muting and
/// the camera on/off toggle use per-track compensators so re-enabled samples
/// continue without a timestamp jump.
final class WebcamRecorder: NSObject, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "dev.vibestudio.capture.webcam")
    private let clock: SharedPauseClock

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var sessionStarted = false
    private var muteCompensator = PauseCompensator()
    private var cameraOffCompensator = PauseCompensator()
    private var hasVideo = false
    private var hasAudio = false

    private(set) var firstVideoHostSeconds: Double?
    private(set) var firstAudioHostSeconds: Double?

    init(clock: SharedPauseClock) {
        self.clock = clock
    }

    func start(camera: AVCaptureDevice?, microphone: AVCaptureDevice?, outputURL: URL) throws {
        guard camera != nil || microphone != nil else { return }

        session.beginConfiguration()
        session.sessionPreset = .high

        var pixelSize = CGSize(width: 1280, height: 720)
        if let camera {
            let input = try AVCaptureDeviceInput(device: camera)
            if session.canAddInput(input) { session.addInput(input) }
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            videoOutput.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
            let dimensions = CMVideoFormatDescriptionGetDimensions(camera.activeFormat.formatDescription)
            if dimensions.width > 0, dimensions.height > 0 {
                pixelSize = CGSize(width: CGFloat(dimensions.width), height: CGFloat(dimensions.height))
            }
            hasVideo = true
        }
        if let microphone {
            let input = try AVCaptureDeviceInput(device: microphone)
            if session.canAddInput(input) { session.addInput(input) }
            audioOutput.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }
            hasAudio = true
        }
        session.commitConfiguration()

        let writer = try AVAssetWriter(url: outputURL, fileType: .mov)
        if hasVideo {
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(pixelSize.width) - (Int(pixelSize.width) % 2),
                AVVideoHeightKey: Int(pixelSize.height) - (Int(pixelSize.height) % 2),
            ])
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw RecorderError.cannotAddInput }
            writer.add(input)
            videoInput = input
        }
        if hasAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 96_000,
            ])
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw RecorderError.cannotAddInput }
            writer.add(input)
            audioInput = input
        }
        guard writer.startWriting() else {
            throw writer.error ?? RecorderError.writerFailed
        }
        self.writer = writer

        queue.async { [session] in
            session.startRunning()
        }
    }

    func setMicMuted(_ muted: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            if muted {
                self.muteCompensator.pause(at: CACurrentMediaTime())
            } else {
                self.muteCompensator.resume(at: CACurrentMediaTime())
            }
        }
    }

    func setCameraOff(_ off: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            if off {
                self.cameraOffCompensator.pause(at: CACurrentMediaTime())
            } else {
                self.cameraOffCompensator.resume(at: CACurrentMediaTime())
            }
        }
    }

    func finish() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [weak self] in
                guard let self else { continuation.resume(); return }
                self.session.stopRunning()
                self.videoInput?.markAsFinished()
                self.audioInput?.markAsFinished()
                if let writer = self.writer {
                    Task {
                        await writer.finishWriting()
                        continuation.resume()
                    }
                } else {
                    continuation.resume()
                }
            }
        }
        writer = nil
        videoInput = nil
        audioInput = nil
    }

    func abort() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [weak self] in
                guard let self else { continuation.resume(); return }
                self.session.stopRunning()
                if let writer = self.writer, writer.status == .writing {
                    writer.cancelWriting()
                }
                continuation.resume()
            }
        }
        writer = nil
        videoInput = nil
        audioInput = nil
    }

    private func append(_ sampleBuffer: CMSampleBuffer, isVideo: Bool) {
        if clock.isPaused { return }
        if isVideo {
            guard let input = videoInput, input.isReadyForMoreMediaData else { return }
            if cameraOffCompensator.isPaused { return }
            appendRetimed(sampleBuffer, to: input, extraCompensator: cameraOffCompensator, isVideo: true)
        } else {
            guard let input = audioInput, input.isReadyForMoreMediaData else { return }
            if muteCompensator.isPaused { return }
            appendRetimed(sampleBuffer, to: input, extraCompensator: muteCompensator, isVideo: false)
        }
    }

    private func appendRetimed(_ sampleBuffer: CMSampleBuffer,
                               to input: AVAssetWriterInput,
                               extraCompensator: PauseCompensator,
                               isVideo: Bool) {
        guard let writer else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let hostSeconds = CMTimeGetSeconds(pts)
        let adjustedSeconds = extraCompensator.adjusted(clock.adjusted(hostSeconds))
        let adjusted = CMTime(seconds: adjustedSeconds, preferredTimescale: pts.timescale)
        var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(sampleBuffer),
                                        presentationTimeStamp: adjusted,
                                        decodeTimeStamp: .invalid)
        var copy: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: nil,
                                                    sampleBuffer: sampleBuffer,
                                                    sampleTimingEntryCount: 1,
                                                    sampleTimingArray: &timing,
                                                    sampleBufferOut: &copy) == noErr,
              let copy else { return }
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

extension WebcamRecorder: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        append(sampleBuffer, isVideo: output is AVCaptureVideoDataOutput)
    }
}
