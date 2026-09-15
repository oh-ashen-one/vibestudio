import AVFoundation
import Foundation

enum DeviceCatalog {
    static func videoDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external],
                                         mediaType: .video,
                                         position: .unspecified).devices
    }

    static func audioDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external],
                                         mediaType: .audio,
                                         position: .unspecified).devices
    }
}
