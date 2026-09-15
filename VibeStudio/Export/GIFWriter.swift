import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Median-cut palette builder (§3.5 two-pass GIF): recursively splits the
/// color space box with the largest channel range at its median, then
/// averages each box. Pure and unit-testable.
enum MedianCut {
    struct Pixel: Equatable {
        var r: UInt8
        var g: UInt8
        var b: UInt8
    }

    static func palette(from pixels: [Pixel], maxColors: Int = 256) -> [Pixel] {
        guard !pixels.isEmpty else { return [Pixel(r: 0, g: 0, b: 0)] }
        var boxes = [pixels]
        while boxes.count < maxColors {
            guard let index = boxes.indices.max(by: { channelRange(boxes[$0]).1 < channelRange(boxes[$1]).1 }),
                  boxes[index].count > 1 else { break }
            let box = boxes.remove(at: index)
            let (channel, _) = channelRange(box)
            let sorted = box.sorted { lhs, rhs in
                switch channel {
                case 0: return lhs.r < rhs.r
                case 1: return lhs.g < rhs.g
                default: return lhs.b < rhs.b
                }
            }
            let median = sorted.count / 2
            boxes.append(Array(sorted[..<median]))
            boxes.append(Array(sorted[median...]))
        }
        return boxes.map { box in
            var r = 0, g = 0, b = 0
            for pixel in box {
                r += Int(pixel.r)
                g += Int(pixel.g)
                b += Int(pixel.b)
            }
            return Pixel(r: UInt8(r / box.count), g: UInt8(g / box.count), b: UInt8(b / box.count))
        }
    }

    private static func channelRange(_ box: [Pixel]) -> (Int, Int) {
        var minR = 255, maxR = 0, minG = 255, maxG = 0, minB = 255, maxB = 0
        for pixel in box {
            minR = min(minR, Int(pixel.r)); maxR = max(maxR, Int(pixel.r))
            minG = min(minG, Int(pixel.g)); maxG = max(maxG, Int(pixel.g))
            minB = min(minB, Int(pixel.b)); maxB = max(maxB, Int(pixel.b))
        }
        let ranges = [maxR - minR, maxG - minG, maxB - minB]
        let channel = ranges.firstIndex(of: ranges.max() ?? 0) ?? 0
        return (channel, ranges[channel])
    }
}

/// GIF writer: maps 32BGRA frames onto a global 256-color palette (built from
/// sampled frames in pass one) via a 3-3-2 RGB lookup grid, then encodes
/// indexed images through ImageIO with a global color table.
final class GIFWriter {
    private let destination: CGImageDestination
    private let colorSpace: CGColorSpace
    private let palette: [MedianCut.Pixel]
    private var lookup: [UInt8]   // 256-entry grid: r3g3b2 -> palette index

    init?(url: URL, palette: [MedianCut.Pixel], frameCount: Int) {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL,
                                                                UTType.gif.identifier as CFString,
                                                                frameCount, nil) else { return nil }
        self.destination = destination
        self.palette = palette
        var table = [UInt8](repeating: 0, count: 256 * 3)
        for (index, pixel) in palette.prefix(256).enumerated() {
            table[index * 3] = pixel.r
            table[index * 3 + 1] = pixel.g
            table[index * 3 + 2] = pixel.b
        }
        guard let space = CGColorSpace(indexedBaseSpace: CGColorSpaceCreateDeviceRGB(),
                                       last: min(palette.count, 256) - 1,
                                       colorTable: &table) else { return nil }
        colorSpace = space
        // 3-3-2 bit grid lookup for nearest palette color.
        lookup = [UInt8](repeating: 0, count: 256)
        for code in 0..<256 {
            let r = UInt8(Int((code >> 5) & 0x7) * 255 / 7)
            let g = UInt8(Int((code >> 2) & 0x7) * 255 / 7)
            let b = UInt8(Int(code & 0x3) * 255 / 3)
            lookup[code] = UInt8(Self.nearest(palette: palette, r: r, g: g, b: b))
        }
        let properties: [String: Any] = [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFLoopCount as String: 0,
            ],
        ]
        CGImageDestinationSetProperties(destination, properties as CFDictionary)
    }

    private static func nearest(palette: [MedianCut.Pixel], r: UInt8, g: UInt8, b: UInt8) -> Int {
        var best = 0
        var bestDistance = Int.max
        for (index, pixel) in palette.enumerated() {
            let dr = Int(pixel.r) - Int(r)
            let dg = Int(pixel.g) - Int(g)
            let db = Int(pixel.b) - Int(b)
            let distance = dr * dr + dg * dg + db * db
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return best
    }

    /// Appends one 32BGRA frame, mapped onto the palette.
    func addFrame(bgra bytes: UnsafePointer<UInt8>, width: Int, height: Int,
                  bytesPerRow: Int, delay: Double) {
        var indices = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = bytes + y * bytesPerRow
            for x in 0..<width {
                let px = row + x * 4
                let code = (Int(px[2] & 0xE0)) | (Int(px[1] & 0xE0) >> 3) | (Int(px[0]) >> 6)
                indices[y * width + x] = lookup[code]
            }
        }
        guard let provider = CGDataProvider(data: Data(indices) as CFData),
              let image = CGImage(width: width, height: height,
                                  bitsPerComponent: 8, bitsPerPixel: 8,
                                  bytesPerRow: width,
                                  space: colorSpace,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                  provider: provider,
                                  decode: nil,
                                  shouldInterpolate: false,
                                  intent: .defaultIntent) else { return }
        let properties: [String: Any] = [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFDelayTime as String: delay,
            ],
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    }

    func finalize() -> Bool {
        CGImageDestinationFinalize(destination)
    }

    /// Samples palette pixels from BGRA frame byte buffers with a stride.
    static func samplePixels(frames: [(data: Data, width: Int, height: Int, bytesPerRow: Int)],
                             stride: Int = 6) -> [MedianCut.Pixel] {
        var pixels: [MedianCut.Pixel] = []
        for frame in frames {
            frame.data.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                for y in Swift.stride(from: 0, to: frame.height, by: stride) {
                    let row = base + y * frame.bytesPerRow
                    for x in Swift.stride(from: 0, to: frame.width, by: stride) {
                        let px = row + x * 4
                        pixels.append(MedianCut.Pixel(r: px[2], g: px[1], b: px[0]))
                    }
                }
            }
        }
        return pixels
    }
}
