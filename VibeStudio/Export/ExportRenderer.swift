import AVFoundation
import CoreVideo
import Foundation
import MetalKit

enum ExportAspect: String, Codable, CaseIterable {
    case a16x9 = "16:9"
    case a9x16 = "9:16"
    case a1x1 = "1:1"

    var ratio: CGFloat {
        switch self {
        case .a16x9: return 16.0 / 9.0
        case .a9x16: return 9.0 / 16.0
        case .a1x1: return 1
        }
    }
}

enum ExportPreset: String, Codable, CaseIterable {
    case sourceNative
    case p1080_60
    case p1080_30
    case p4k_60

    var frameRate: Int? {
        switch self {
        case .p1080_30: return 30
        default: return nil   // source rate
        }
    }

    /// Long-edge pixel size for the output canvas (before aspect).
    var longEdge: CGFloat? {
        switch self {
        case .sourceNative: return nil
        case .p1080_60, .p1080_30: return 1920
        case .p4k_60: return 3840
        }
    }

    func isAllowed(sourceSize: CGSize) -> Bool {
        switch self {
        case .p4k_60: return sourceSize.height >= 2160
        default: return true
        }
    }

    func outputSize(aspect: ExportAspect, sourceSize: CGSize, sourceFPS: Int) -> CGSize {
        let ratio = aspect.ratio
        let longEdge = self.longEdge ?? max(sourceSize.width, sourceSize.height)
        let width: CGFloat
        let height: CGFloat
        if ratio > 1 {
            width = longEdge
            height = longEdge / ratio
        } else if ratio < 1 {
            height = longEdge
            width = longEdge * ratio
        } else {
            // 1:1: the nominal short edge (1080p = 1080, 4K = 2160).
            width = longEdge * 9.0 / 16.0
            height = width
        }
        func even(_ value: CGFloat) -> Int { Int(value.rounded()) - (Int(value.rounded()) % 2) }
        return CGSize(width: even(width), height: even(height))
    }
}

enum ExportFormat: String, Codable, CaseIterable {
    case mp4
    case gif
}

struct ExportConfiguration {
    var bundleURL: URL
    var outputURL: URL
    var preset: ExportPreset = .sourceNative
    var aspect: ExportAspect = .a16x9
    var format: ExportFormat = .mp4
    var trimRange: ClosedRange<Double>?
}

struct ExportResult: Equatable {
    var outputURL: URL
    var duration: Double
    var frameCount: Int
    var fileSize: Int64
}

final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

enum ExportError: Error {
    case noVideoTrack
    case writerFailed
    case cancelled
    case composerUnavailable
}

/// Offline exporter: AVAssetReader (screen + webcam, synced via meta
/// host-time offsets) → shared FrameComposer → AVAssetWriter H.264.
/// Renders the SAME frames the preview shows (same FrameStateBuilder, same
/// FrameComposer, same shaders). Audio: recording.mov's audio track is passed
/// through compressed (system audio); webcam.mov audio is not mixed.
final class ExportRenderer: @unchecked Sendable {
    static let videoBitrateFactor: Double = 0.12   // bits per pixel per frame

    /// Webcam media time for a given screen media time, from the first-buffer
    /// host-clock offsets recorded in recording-meta.json.
    static func webcamMediaTime(forScreenTime t: Double,
                                screenFirstHostSeconds: Double?,
                                webcamFirstHostSeconds: Double?) -> Double {
        let offset = (webcamFirstHostSeconds ?? 0) - (screenFirstHostSeconds ?? 0)
        return max(0, t - offset)
    }

    /// Output frame times in source-media seconds for a trim range.
    /// GIF canvas: capped at 480px height per §3.5 social presets.
    static func gifCanvasSize(aspect: ExportAspect) -> CGSize {
        func even(_ value: CGFloat) -> Int { Int(value.rounded()) - (Int(value.rounded()) % 2) }
        return CGSize(width: even(480 * aspect.ratio), height: 480)
    }

    static func frameTimes(trimStart: Double, trimEnd: Double, fps: Int) -> [Double] {
        let count = max(Int(((trimEnd - trimStart) * Double(fps)).rounded(.toNearestOrAwayFromZero)), 1)
        return (0..<count).map { trimStart + Double($0) / Double(fps) }
    }

    static func run(configuration config: ExportConfiguration,
                    progress: @escaping @Sendable (Double) -> Void,
                    cancel: CancelToken? = nil) async throws -> ExportResult {
        guard let composer = FrameComposer() else { throw ExportError.composerUnavailable }
        let analysis = try await ProjectAnalysis.load(bundleURL: config.bundleURL)
        let settings = analysis.resolvedSettings
        let sourceFPS = Int(analysis.frameRate.rounded())
        let isGIF = config.format == .gif
        let fps = isGIF ? min(30, sourceFPS) : (config.preset.frameRate ?? sourceFPS)
        let outputSize = isGIF
            ? gifCanvasSize(aspect: config.aspect)
            : config.preset.outputSize(aspect: config.aspect,
                                       sourceSize: analysis.videoSize,
                                       sourceFPS: sourceFPS)

        let keyframes = AspectRetarget.keyframes(analysis.resolvedKeyframes,
                                                 sourceSize: analysis.videoSize,
                                                 targetAspect: config.aspect.ratio)
        let cameraModel = CameraModel(keyframes: keyframes, style: settings.zoomStyle)
        let smoothed = analysis.smoothedPath(preset: settings.smoothnessPreset)
        let frameDT = 1.0 / Double(fps)
        let trimStart = max(config.trimRange?.lowerBound ?? 0, 0)
        var trimEnd = min(config.trimRange?.upperBound ?? analysis.duration, analysis.duration)
        // Loop cursor end appends a synthetic return-to-start segment.
        if settings.loopCursorEnd == true {
            trimEnd += LoopCursorEnd.loopSeconds
        }
        let times = frameTimes(trimStart: trimStart, trimEnd: trimEnd, fps: fps)
        let keyBadges: [(t: Double, text: String)] = analysis.project.events.compactMap { event in
            guard event.kind == .key else { return nil }
            return KeystrokeBadges.badgeText(modifiers: event.modifiers, key: event.key)
                .map { (event.t, $0) }
        }

        // Readers
        let screenAsset = AVAsset(url: analysis.project.recordingURL)
        guard let screenTrack = try await screenAsset.loadTracks(withMediaType: .video).first else {
            throw ExportError.noVideoTrack
        }
        let screenReader = try SequentialFrameReader(asset: screenAsset, track: screenTrack)

        var webcamReader: SequentialFrameReader?
        if settings.cameraLayout != .screenOnly, let webcamURL = analysis.webcamURL {
            let webcamAsset = AVAsset(url: webcamURL)
            if let track = try await webcamAsset.loadTracks(withMediaType: .video).first {
                webcamReader = try SequentialFrameReader(asset: webcamAsset, track: track)
            }
        }

        let audioTrack = isGIF ? nil : try await screenAsset.loadTracks(withMediaType: .audio).first

        if FileManager.default.fileExists(atPath: config.outputURL.path) {
            try FileManager.default.removeItem(at: config.outputURL)
        }

        // Shared per-frame render: readers -> FrameStateBuilder -> composer.
        func renderFrame(into pixelBuffer: CVPixelBuffer, at t: Double) async {
            var screenTexture: MTLTexture?
            var screenSource: CVMetalTexture?
            if let frame = screenReader.frame(at: t),
               let wrapped = composer.texture(from: frame) {
                screenSource = wrapped.source
                screenTexture = wrapped.texture
            }
            var webcamTexture: MTLTexture?
            var webcamSource: CVMetalTexture?
            if let webcamReader,
               let frame = webcamReader.frame(at: webcamMediaTime(forScreenTime: t,
                                                                  screenFirstHostSeconds: analysis.project.meta.screenFirstHostSeconds,
                                                                  webcamFirstHostSeconds: analysis.project.meta.webcamFirstHostSeconds)),
               let wrapped = composer.texture(from: frame) {
                webcamSource = wrapped.source
                webcamTexture = wrapped.texture
            }
            let state = FrameStateBuilder.make(t: t,
                                               cameraModel: cameraModel,
                                               smoothedPath: smoothed,
                                               videoSize: analysis.videoSize,
                                               settings: settings,
                                               frameDT: frameDT,
                                               sourceAspect: config.aspect.ratio,
                                               clicks: analysis.clicks,
                                               keyBadges: keyBadges,
                                               duration: analysis.duration)
            guard let target = composer.texture(from: pixelBuffer) else { return }
            let descriptor = MTLRenderPassDescriptor()
            descriptor.colorAttachments[0].texture = target.texture
            descriptor.colorAttachments[0].loadAction = .clear
            descriptor.colorAttachments[0].storeAction = .store
            descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            if let buffer = composer.commandQueue.makeCommandBuffer(),
               let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor) {
                composer.encodeFrame(encoder: encoder,
                                     screen: screenTexture,
                                     webcam: webcamTexture,
                                     state: state,
                                     outputSize: outputSize)
                encoder.endEncoding()
                buffer.commit()
                await buffer.completed()
            }
            _ = screenSource
            _ = webcamSource
            _ = target
        }

        if isGIF {
            return try await runGIF(config: config,
                                    times: times,
                                    fps: fps,
                                    outputSize: outputSize,
                                    progress: progress,
                                    cancel: cancel,
                                    renderFrame: renderFrame)
        }

        // MARK: MP4 writer
        let writer = try AVAssetWriter(url: config.outputURL, fileType: .mp4)
        let bitrate = Int(Double(outputSize.width * outputSize.height) * Double(fps) * videoBitrateFactor)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(outputSize.width),
            AVVideoHeightKey: Int(outputSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw ExportError.writerFailed }
        writer.add(videoInput)

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(outputSize.width),
                kCVPixelBufferHeightKey as String: Int(outputSize.height),
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ])

        var audioInput: AVAssetWriterInput?
        var audioReaderOutput: AVAssetReaderTrackOutput?
        var audioReader: AVAssetReader?
        if let audioTrack,
           let formatDescription = try await audioTrack.load(.formatDescriptions).first {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil,
                                           sourceFormatHint: formatDescription)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
                let reader = try AVAssetReader(asset: screenAsset)
                let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
                reader.add(output)
                reader.startReading()
                audioReader = reader
                audioReaderOutput = output
            }
        }
        _ = audioReader

        guard writer.startWriting() else { throw writer.error ?? ExportError.writerFailed }
        writer.startSession(atSourceTime: .zero)

        var audioDone = audioInput == nil
        var pendingAudio = audioReaderOutput?.copyNextSampleBuffer()
        func pumpAudio(upTo sourceTime: Double) {
            guard let audioInput else { return }
            while let buffer = pendingAudio {
                let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
                let seconds = CMTimeGetSeconds(pts)
                if seconds > sourceTime { return }
                if !audioInput.isReadyForMoreMediaData { return }   // retried later
                pendingAudio = audioReaderOutput?.copyNextSampleBuffer()
                if seconds + CMTimeGetSeconds(CMSampleBufferGetDuration(buffer)) < trimStart { continue }
                let shifted = CMTime(seconds: max(0, seconds - trimStart), preferredTimescale: pts.timescale)
                if let retimed = retime(buffer, to: shifted) {
                    audioInput.append(retimed)
                }
            }
            audioDone = true
        }

        for (index, t) in times.enumerated() {
            if cancel?.isCancelled == true {
                videoInput.markAsFinished()
                audioInput?.markAsFinished()
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: config.outputURL)
                throw ExportError.cancelled
            }
            guard let pool = adaptor.pixelBufferPool,
                  let pixelBuffer = createPixelBuffer(pool: pool) else { continue }
            await renderFrame(into: pixelBuffer, at: t)

            while !videoInput.isReadyForMoreMediaData {
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: Int64(index), timescale: CMTimeScale(fps)))
            pumpAudio(upTo: t)
            progress(Double(index + 1) / Double(times.count))
        }

        // Drain remaining audio within the trim range (bounded safety loop).
        var drainGuard = 0
        while !audioDone, drainGuard < 100_000 {
            pumpAudio(upTo: trimEnd + 1)
            drainGuard += 1
            if pendingAudio != nil, audioInput?.isReadyForMoreMediaData == false {
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        await writer.finishWriting()
        if writer.status == .failed {
            throw writer.error ?? ExportError.writerFailed
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: config.outputURL.path)
        return ExportResult(outputURL: config.outputURL,
                            duration: Double(times.count) / Double(fps),
                            frameCount: times.count,
                            fileSize: attributes[.size] as? Int64 ?? 0)
    }

    /// GIF path (§3.5): pass 1 renders sampled frames to build a median-cut
    /// palette, pass 2 renders every frame and appends it palette-mapped.
    private static func runGIF(config: ExportConfiguration,
                               times: [Double],
                               fps: Int,
                               outputSize: CGSize,
                               progress: @escaping @Sendable (Double) -> Void,
                               cancel: CancelToken?,
                               renderFrame: (CVPixelBuffer, Double) async -> Void) async throws -> ExportResult {
        let width = Int(outputSize.width)
        let height = Int(outputSize.height)
        guard let pixelBuffer = createPixelBuffer(width: width, height: height) else {
            throw ExportError.writerFailed
        }

        func readBytes<T>(_ body: (UnsafePointer<UInt8>, Int) -> T) -> T {
            CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
            let base = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
            return body(base, CVPixelBufferGetBytesPerRow(pixelBuffer))
        }

        // Pass 1: sample up to 12 frames for the palette.
        let sampleStride = max(times.count / 12, 1)
        var sampleFrames: [(data: Data, width: Int, height: Int, bytesPerRow: Int)] = []
        for index in Swift.stride(from: 0, to: times.count, by: sampleStride) {
            await renderFrame(pixelBuffer, times[index])
            let bytes = readBytes { base, bytesPerRow in
                Data(bytes: base, count: bytesPerRow * height)
            }
            sampleFrames.append((bytes, width, height, CVPixelBufferGetBytesPerRow(pixelBuffer)))
        }
        let palette = MedianCut.palette(from: GIFWriter.samplePixels(frames: sampleFrames), maxColors: 256)
        guard let writer = GIFWriter(url: config.outputURL, palette: palette, frameCount: times.count) else {
            throw ExportError.writerFailed
        }

        // Pass 2: full render + palette-mapped append.
        for (index, t) in times.enumerated() {
            if cancel?.isCancelled == true {
                try? FileManager.default.removeItem(at: config.outputURL)
                throw ExportError.cancelled
            }
            await renderFrame(pixelBuffer, t)
            readBytes { base, bytesPerRow in
                writer.addFrame(bgra: base, width: width, height: height,
                                bytesPerRow: bytesPerRow, delay: 1.0 / Double(fps))
            }
            progress(Double(index + 1) / Double(times.count))
        }
        guard writer.finalize() else { throw ExportError.writerFailed }
        let attributes = try FileManager.default.attributesOfItem(atPath: config.outputURL.path)
        return ExportResult(outputURL: config.outputURL,
                            duration: Double(times.count) / Double(fps),
                            frameCount: times.count,
                            fileSize: attributes[.size] as? Int64 ?? 0)
    }

    private static func createPixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferCGImageCompatibilityKey: true,
        ] as CFDictionary, &pixelBuffer)
        guard status == kCVReturnSuccess else { return nil }
        return pixelBuffer
    }

    private static func createPixelBuffer(pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess else { return nil }
        return pixelBuffer
    }

    private static func retime(_ sampleBuffer: CMSampleBuffer, to pts: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(sampleBuffer),
                                        presentationTimeStamp: pts,
                                        decodeTimeStamp: .invalid)
        var output: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: nil,
                                                    sampleBuffer: sampleBuffer,
                                                    sampleTimingEntryCount: 1,
                                                    sampleTimingArray: &timing,
                                                    sampleBufferOut: &output) == noErr else { return nil }
        return output
    }
}

/// Reads a video track sequentially, vending the latest frame at or before a
/// requested media time (nearest-behind sampling for frame-rate conversion).
final class SequentialFrameReader {
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private var current: CMSampleBuffer?
    private var lookahead: CMSampleBuffer?

    init(asset: AVAsset, track: AVAssetTrack) throws {
        reader = try AVAssetReader(asset: asset)
        output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        reader.add(output)
        reader.startReading()
    }

    func frame(at seconds: Double) -> CVPixelBuffer? {
        if current == nil { current = output.copyNextSampleBuffer() }
        while true {
            if lookahead == nil { lookahead = output.copyNextSampleBuffer() }
            guard let next = lookahead else { break }
            let nextPTS = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(next))
            if nextPTS <= seconds + 0.0005 {
                current = next
                lookahead = nil
            } else {
                break
            }
        }
        guard let current, CMSampleBufferDataIsReady(current) else { return nil }
        return CMSampleBufferGetImageBuffer(current)
    }
}
