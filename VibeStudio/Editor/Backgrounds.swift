import AppKit

/// Built-in background gallery: gradient presets + procedurally generated
/// wallpapers. No assets, no network — everything is drawn in code.
enum Backgrounds {
    struct Preset: Identifiable {
        let id: String
        let name: String
        let startHex: String
        let endHex: String
        let wallpaper: WallpaperKind?

        var isWallpaper: Bool { wallpaper != nil }
    }

    enum WallpaperKind {
        case aurora
        case dunes
    }

    static let presets: [Preset] = [
        Preset(id: "midnight", name: "Midnight", startHex: "#1B2838", endHex: "#0A0F18", wallpaper: nil),
        Preset(id: "dusk", name: "Dusk", startHex: "#3A1C4D", endHex: "#12081F", wallpaper: nil),
        Preset(id: "ember", name: "Ember", startHex: "#4A1F1A", endHex: "#160A08", wallpaper: nil),
        Preset(id: "forest", name: "Forest", startHex: "#14342B", endHex: "#071510", wallpaper: nil),
        Preset(id: "slate", name: "Slate", startHex: "#3A3F4A", endHex: "#17181C", wallpaper: nil),
        Preset(id: "ocean", name: "Ocean", startHex: "#0F3B57", endHex: "#071A29", wallpaper: nil),
        Preset(id: "aurora", name: "Aurora", startHex: "#123B33", endHex: "#0B1026", wallpaper: .aurora),
        Preset(id: "dunes", name: "Dunes", startHex: "#4A3319", endHex: "#1B0F06", wallpaper: .dunes),
    ]

    static func preset(id: String) -> Preset? {
        presets.first { $0.id == id }
    }

    static func gradientColors(startHex: String, endHex: String) -> (NSColor, NSColor) {
        (color(hex: startHex), color(hex: endHex))
    }

    static func color(hex: String) -> NSColor {
        var value: UInt64 = 0
        Scanner(string: hex.replacingOccurrences(of: "#", with: "")).scanHexInt64(&value)
        return NSColor(red: CGFloat((value >> 16) & 0xFF) / 255,
                       green: CGFloat((value >> 8) & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255,
                       alpha: 1)
    }

    static func hex(_ color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return "#000000" }
        return String(format: "#%02X%02X%02X",
                      Int(rgb.redComponent * 255),
                      Int(rgb.greenComponent * 255),
                      Int(rgb.blueComponent * 255))
    }

    /// Deterministic procedural wallpaper: gradient base plus soft translucent
    /// blobs (aurora) or layered dune bands (dunes).
    private static var wallpaperCache: [String: NSImage] = [:]

    static func cachedWallpaper(_ kind: WallpaperKind, size: NSSize, startHex: String, endHex: String) -> NSImage {
        let key = "\(kind)-\(Int(size.width))x\(Int(size.height))-\(startHex)-\(endHex)"
        if let cached = wallpaperCache[key] { return cached }
        let image = wallpaperImage(kind, size: size, startHex: startHex, endHex: endHex)
        wallpaperCache[key] = image
        return image
    }

    static func wallpaperImage(_ kind: WallpaperKind, size: NSSize, startHex: String, endHex: String) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        let bounds = NSRect(origin: .zero, size: size)
        let (start, end) = gradientColors(startHex: startHex, endHex: endHex)
        NSGradient(starting: start, ending: end)?.draw(in: bounds, angle: 90)

        var seed: UInt64 = kind == .aurora ? 42 : 7
        func random() -> CGFloat {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat((seed >> 33) & 0xFFFF) / 65535
        }

        switch kind {
        case .aurora:
            for i in 0..<9 {
                let hue = (0.35 + 0.25 * random()).truncatingRemainder(dividingBy: 1)
                let color = NSColor(hue: hue, saturation: 0.7, brightness: 0.9,
                                    alpha: 0.10 + 0.10 * random())
                let diameter = size.width * (0.25 + 0.45 * random())
                let rect = NSRect(x: random() * size.width - diameter / 2,
                                  y: size.height * 0.2 + random() * size.height - diameter / 2,
                                  width: diameter, height: diameter)
                color.setFill()
                NSBezierPath(ovalIn: rect).fill()
                _ = i
            }
        case .dunes:
            for band in 0..<5 {
                let path = NSBezierPath()
                let baseY = size.height * (0.1 + 0.18 * CGFloat(band))
                path.move(to: CGPoint(x: 0, y: baseY))
                var x: CGFloat = 0
                while x <= size.width {
                    let y = baseY + size.height * 0.12 * (random() - 0.5)
                    path.line(to: CGPoint(x: x, y: y))
                    x += size.width / 6
                }
                path.line(to: CGPoint(x: size.width, y: 0))
                path.line(to: CGPoint(x: 0, y: 0))
                path.close()
                NSColor.black.withAlphaComponent(0.10 + 0.06 * CGFloat(band)).setFill()
                path.fill()
            }
        }
        image.unlockFocus()
        return image
    }
}
