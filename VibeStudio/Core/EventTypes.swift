import CoreGraphics
import Foundation

/// Event schema per master spec §3.1. Coordinates are global CG display
/// coordinates (points, top-left origin of the primary display). Optional
/// fields are omitted from the JSON when nil.
struct RecordedEvent: Codable, Equatable {
    enum Kind: String, Codable {
        case cursorMove
        case click
        case scroll
        case key
        case cursorType
        case frontmostWindow
    }

    var t: Double
    var kind: Kind
    var x: Double?
    var y: Double?
    var button: String?
    var dx: Double?
    var dy: Double?
    var modifiers: [String]?
    var key: String?
    var keyCode: Int?
    var name: String?
    var frame: CGRect?
    var appBundleID: String?

    static func cursorMove(t: Double, x: Double, y: Double) -> RecordedEvent {
        RecordedEvent(t: t, kind: .cursorMove, x: x, y: y)
    }

    static func click(t: Double, x: Double, y: Double, button: String) -> RecordedEvent {
        RecordedEvent(t: t, kind: .click, x: x, y: y, button: button)
    }

    static func scroll(t: Double, dx: Double, dy: Double) -> RecordedEvent {
        RecordedEvent(t: t, kind: .scroll, dx: dx, dy: dy)
    }

    static func key(t: Double, modifiers: [String], key: String, keyCode: Int) -> RecordedEvent {
        RecordedEvent(t: t, kind: .key, modifiers: modifiers, key: key, keyCode: keyCode)
    }

    static func cursorType(t: Double, name: String) -> RecordedEvent {
        RecordedEvent(t: t, kind: .cursorType, name: name)
    }

    static func frontmostWindow(t: Double, frame: CGRect?, appBundleID: String?) -> RecordedEvent {
        RecordedEvent(t: t, kind: .frontmostWindow, frame: frame, appBundleID: appBundleID)
    }
}

struct EventLog: Codable, Equatable {
    var version: Int = 1
    var events: [RecordedEvent]
}

/// Capture mapping recorded alongside events so Phase 2+ can project events
/// into video pixel space, plus the sync offsets between the writers.
struct RecordingMeta: Codable, Equatable {
    var version: Int = 1
    var createdAt: Date
    var sourceMode: String
    var displayID: UInt32
    var displayFrameCGPoints: CGRect
    var scaleFactor: Double
    var outputPixelSize: CGSize
    var sourceRectPixels: CGRect?
    var windowID: UInt32?
    var windowFrameCGPoints: CGRect?
    var frameRate: Int
    var systemAudioCaptured: Bool
    var screenFirstHostSeconds: Double?
    var webcamFirstHostSeconds: Double?
    var micFirstHostSeconds: Double?
    var files: [String]
}
