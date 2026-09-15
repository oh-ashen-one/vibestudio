import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// Live input level meter for the setup pill: AVAudioEngine input tap, RMS ->
/// dB -> normalized 0...1, published at ~10 Hz on the main thread.
final class MicLevelMeter: @unchecked Sendable {
    var onLevel: ((Float) -> Void)?

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var rawLevel: Float = 0
    private var displayTimer: Timer?
    private(set) var isRunning = false

    func start(deviceUniqueID: String?) {
        guard !isRunning else { return }
        if let uid = deviceUniqueID,
           let deviceID = Self.audioDeviceID(forUID: uid),
           let unit = engine.inputNode.audioUnit {
            var id = deviceID
            AudioUnitSetProperty(unit,
                                 AudioUnitPropertyID(kAudioOutputUnitProperty_CurrentDevice),
                                 kAudioUnitScope_Global,
                                 0,
                                 &id,
                                 UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self, let channelData = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            guard frames > 0 else { return }
            let channel = channelData[0]
            var sum: Float = 0
            for i in 0..<frames { sum += channel[i] * channel[i] }
            let rms = sqrt(sum / Float(frames))
            self.lock.lock()
            self.rawLevel = rms
            self.lock.unlock()
        }
        do {
            try engine.start()
            isRunning = true
        } catch {
            input.removeTap(onBus: 0)
            return
        }
        DispatchQueue.main.async {
            self.displayTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                let rms = self.rawLevel
                self.lock.unlock()
                let db = 20 * log10(max(rms, 1e-6))
                let normalized = min(max((db + 50) / 50, 0), 1)
                self.onLevel?(normalized)
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        displayTimer?.invalidate()
        displayTimer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        DispatchQueue.main.async { [onLevel] in
            onLevel?(0)
        }
    }

    /// Maps an AVCaptureDevice uniqueID to a CoreAudio device for the engine.
    static func audioDeviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size) == noErr else { return nil }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &ids) == noErr else { return nil }
        for id in ids {
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var value: CFString = "" as CFString
            var valueSize = UInt32(MemoryLayout<CFString>.size)
            let status = withUnsafeMutablePointer(to: &value) { pointer in
                AudioObjectGetPropertyData(id, &uidAddress, 0, nil, &valueSize, pointer)
            }
            if status == noErr, (value as String) == uid { return id }
        }
        return nil
    }
}
