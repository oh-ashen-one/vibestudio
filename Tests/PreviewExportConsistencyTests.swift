import AVFoundation
import CoreVideo
import XCTest
@testable import VibeStudio

/// Renders fixed timestamps through the REAL preview path (FrameStateBuilder
/// + FrameComposer into an offscreen texture) and independently through the
/// REAL export pipeline (ExportRenderer → H.264 → AVAssetReader decode),
/// then compares. Only encoder-level (H.264 quantization) differences are
/// tolerated: mean absolute luma difference and PSNR thresholds documented in
/// DECISIONS.md. Fails if preview and export diverge structurally.
final class PreviewExportConsistencyTests: XCTestCase {
    private static let meanAbsDiffTolerance: Double = 3.0   // of 255, luma
    private static let psnrTolerance: Double = 40.0         // dB

    private var fixtureURL: URL {
        URL(fileURLWithPath: (#filePath as NSString).deletingLastPathComponent)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/sample-recording.vibestudio", isDirectory: true)
    }

    func testPreviewMatchesExport() async throws {
        guard FileManager.default.fileExists(atPath: fixtureURL.appendingPathComponent("project.json").path) else {
            throw XCTSkip("fixture not generated — run ./scripts/make_fixture.sh")
        }
        guard let composer = FrameComposer() else {
            throw XCTSkip("Metal unavailable in this environment")
        }
        let analysis = try await ProjectAnalysis.load(bundleURL: fixtureURL)
        let settings = analysis.resolvedSettings
        let cameraModel = CameraModel(keyframes: analysis.resolvedKeyframes,
                                      style: settings.zoomStyle)
        let smoothed = analysis.smoothedPath(preset: settings.smoothnessPreset)
        let videoSize = analysis.videoSize
        let fps = Int(analysis.frameRate.rounded())
        let frameDT = 1.0 / Double(fps)
        let keyBadges: [(t: Double, text: String)] = analysis.project.events.compactMap { event in
            guard event.kind == .key else { return nil }
            return KeystrokeBadges.badgeText(modifiers: event.modifiers, key: event.key)
                .map { (event.t, $0) }
        }

        let screenAsset = AVAsset(url: analysis.project.recordingURL)
        let screenTracks = try await screenAsset.loadTracks(withMediaType: .video)
        let screenTrack = try XCTUnwrap(screenTracks.first)
        let webcamAsset = analysis.webcamURL.map { AVAsset(url: $0) }
        let webcamTrack = try await webcamAsset?.loadTracks(withMediaType: .video).first

        for t in [2.1, 10.5, 25.0] {
            // 1. PREVIEW side: state + render, exactly as the live preview does.
            let state = FrameStateBuilder.make(t: t,
                                               cameraModel: cameraModel,
                                               smoothedPath: smoothed,
                                               videoSize: videoSize,
                                               settings: settings,
                                               frameDT: frameDT,
                                               clicks: analysis.clicks,
                                               keyBadges: keyBadges,
                                               duration: analysis.duration)
            let screenReader = try SequentialFrameReader(asset: screenAsset, track: screenTrack)
            var webcamReader: SequentialFrameReader?
            if let webcamAsset, let webcamTrack {
                webcamReader = try SequentialFrameReader(asset: webcamAsset, track: webcamTrack)
            }
            var screenTexture: MTLTexture?
            var screenSource: CVMetalTexture?
            if let frame = screenReader.frame(at: t),
               let wrapped = composer.texture(from: frame) {
                screenSource = wrapped.source
                screenTexture = wrapped.texture
            }
            var webcamTexture: MTLTexture?
            var webcamSource: CVMetalTexture?
            if let frame = webcamReader?.frame(at: ExportRenderer.webcamMediaTime(
                forScreenTime: t,
                screenFirstHostSeconds: analysis.project.meta.screenFirstHostSeconds,
                webcamFirstHostSeconds: analysis.project.meta.webcamFirstHostSeconds)),
               let wrapped = composer.texture(from: frame) {
                webcamSource = wrapped.source
                webcamTexture = wrapped.texture
            }
            let previewPixels = try renderOffscreen(composer: composer,
                                                    screen: screenTexture,
                                                    webcam: webcamTexture,
                                                    state: state,
                                                    size: videoSize)
            _ = screenSource
            _ = webcamSource

            // 2. EXPORT side: real pipeline over a small trim window, then
            // decode the H.264 output back to pixels.
            let trimStart = max(t - 0.4, 0)
            let outURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("consistency-\(UUID().uuidString).mp4")
            defer { try? FileManager.default.removeItem(at: outURL) }
            let config = ExportConfiguration(bundleURL: fixtureURL,
                                             outputURL: outURL,
                                             preset: .sourceNative,
                                             aspect: .a16x9,
                                             format: .mp4,
                                             trimRange: trimStart...(t + 0.4))
            let result = try await ExportRenderer.run(configuration: config,
                                                      progress: { _ in },
                                                      cancel: nil)
            XCTAssertEqual(result.frameCount, Int(((t + 0.4 - trimStart) * Double(fps)).rounded(.toNearestOrAwayFromZero)))
            let exportAsset = AVAsset(url: outURL)
            let exportTracks = try await exportAsset.loadTracks(withMediaType: .video)
            let exportTrack = try XCTUnwrap(exportTracks.first)
            let exportFrameReader = try SequentialFrameReader(asset: exportAsset, track: exportTrack)
            let exportedBuffer = try XCTUnwrap(exportFrameReader.frame(at: 0.4))
            let exportedPixels = try XCTUnwrap(copyBytes(from: exportedBuffer))

            // 3. Compare (luma only: chroma quantization is encoder-owned).
            let metrics = lumaMetrics(previewPixels, exportedPixels)
            print("[consistency] t=\(t): meanAbsDiff=\(String(format: "%.3f", metrics.meanAbsDiff)) psnr=\(String(format: "%.1f", metrics.psnr))dB")
            XCTAssertEqual(previewPixels.width, exportedPixels.width)
            XCTAssertEqual(previewPixels.height, exportedPixels.height)
            XCTAssertLessThan(metrics.meanAbsDiff, Self.meanAbsDiffTolerance,
                              "t=\(t): mean abs luma diff \(metrics.meanAbsDiff) exceeds tolerance — preview/export diverged")
            XCTAssertGreaterThan(metrics.psnr, Self.psnrTolerance,
                                 "t=\(t): PSNR \(metrics.psnr)dB below tolerance — preview/export diverged")
        }
    }

    // MARK: - Helpers

    private struct Bitmap {
        var bytes: [UInt8]
        var width: Int
        var height: Int
        var bytesPerRow: Int
    }

    private func renderOffscreen(composer: FrameComposer,
                                 screen: MTLTexture?,
                                 webcam: MTLTexture?,
                                 state: CompositorFrameState,
                                 size: CGSize) throws -> Bitmap {
        let width = Int(size.width)
        let height = Int(size.height)
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, [
            kCVPixelBufferMetalCompatibilityKey: true,
        ] as CFDictionary, &pixelBuffer) == kCVReturnSuccess, let pixelBuffer else {
            throw XCTSkip("pixel buffer creation failed")
        }
        guard let target = composer.texture(from: pixelBuffer) else {
            throw XCTSkip("target texture creation failed")
        }
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = target.texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let buffer = composer.commandQueue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw XCTSkip("command encoding failed")
        }
        composer.encodeFrame(encoder: encoder,
                             screen: screen,
                             webcam: webcam,
                             state: state,
                             outputSize: size)
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        _ = target
        return try XCTUnwrap(copyBytes(from: pixelBuffer))
    }

    private func copyBytes(from pixelBuffer: CVPixelBuffer) -> Bitmap? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let data = [UInt8](UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self),
                                               count: bytesPerRow * height))
        return Bitmap(bytes: data,
                      width: CVPixelBufferGetWidth(pixelBuffer),
                      height: height,
                      bytesPerRow: bytesPerRow)
    }

    private func lumaMetrics(_ a: Bitmap, _ b: Bitmap) -> (meanAbsDiff: Double, psnr: Double) {
        var sum = 0.0
        var sumSq = 0.0
        var count = 0.0
        for y in 0..<a.height {
            let rowA = y * a.bytesPerRow
            let rowB = y * b.bytesPerRow
            for x in 0..<a.width {
                let pa = rowA + x * 4
                let pb = rowB + x * 4
                let lumaA = 0.114 * Double(a.bytes[pa]) + 0.587 * Double(a.bytes[pa + 1]) + 0.299 * Double(a.bytes[pa + 2])
                let lumaB = 0.114 * Double(b.bytes[pb]) + 0.587 * Double(b.bytes[pb + 1]) + 0.299 * Double(b.bytes[pb + 2])
                let diff = abs(lumaA - lumaB)
                sum += diff
                sumSq += diff * diff
                count += 1
            }
        }
        let mean = sum / count
        let mse = sumSq / count
        let psnr = mse > 0 ? 10 * log10(255 * 255 / mse) : 99
        return (mean, psnr)
    }
}
