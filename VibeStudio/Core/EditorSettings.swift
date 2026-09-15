import CoreGraphics
import Foundation

enum CameraLayout: String, Codable, CaseIterable {
    case screenOnly
    case screenPlusWebcamBubble
    case webcamFull
}

/// Background description stored in project.json. Presets render gradients;
/// wallpapers are procedurally generated images (see Backgrounds.swift);
/// custom stores two gradient colors as hex.
enum BackgroundSpec: Codable, Equatable {
    case preset(String)
    case custom(startHex: String, endHex: String)

    private enum CodingKeys: String, CodingKey {
        case kind, id, startHex, endHex
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "custom":
            self = .custom(startHex: try container.decode(String.self, forKey: .startHex),
                           endHex: try container.decode(String.self, forKey: .endHex))
        default:
            self = .preset(try container.decode(String.self, forKey: .id))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .preset(let id):
            try container.encode("preset", forKey: .kind)
            try container.encode(id, forKey: .id)
        case .custom(let startHex, let endHex):
            try container.encode("custom", forKey: .kind)
            try container.encode(startHex, forKey: .startHex)
            try container.encode(endHex, forKey: .endHex)
        }
    }
}

/// Everything the inspector edits; persisted in project.json.
struct EditorSettings: Codable, Equatable {
    var cursorSize: Double = 1.0
    var smoothnessPreset: SmoothnessPreset = .standard
    var zoomStyle: ZoomStyle = .focused
    /// 0...1, maps to shutter angle / blur tap count.
    var motionBlurStrength: Double = 0.5
    var background: BackgroundSpec = .preset("midnight")
    /// Fraction of the canvas width used as padding around the video.
    var padding: Double = 0.08
    /// Corner radius as a fraction of the video view height.
    var cornerRadius: Double = 0.04
    var shadowEnabled: Bool = true
    var cameraLayout: CameraLayout = .screenOnly
}
