import AppKit
@preconcurrency import AVFoundation
import Combine
import Foundation
import QuartzCore
import ScreenCaptureKit

enum SourceMode: String, CaseIterable {
    case display
    case window
    case area
    case device
}

struct AreaSelection {
    var displayID: CGDirectDisplayID
    var displayFrameCG: CGRect
    var sourceRectPixels: CGRect
    var scale: CGFloat
}

/// Owns the full recording lifecycle: source/device selection, countdown,
/// hide-desktop-icons, the capture engine, event logging, and output files.
@MainActor
final class RecordingSession: ObservableObject {
    enum Phase {
        case setup
        case countingDown
        case recording
        case paused
    }

    @Published var phase: Phase = .setup
    @Published var settings: RecordingSettings {
        didSet {
            SettingsStore.save(settings)
            if oldValue.selectedCameraID != settings.selectedCameraID { updateCameraPreview() }
            if oldValue.selectedMicID != settings.selectedMicID { updateMicMeter() }
        }
    }
    @Published var cameras: [AVCaptureDevice] = []
    @Published var microphones: [AVCaptureDevice] = []
    @Published var elapsed: TimeInterval = 0
    @Published var micLevel: Float = 0
    @Published var isMicMuted = false
    @Published var isCameraOff = false
    @Published var previewSession: AVCaptureSession?
    @Published var selectedWindowTitle: String?
    @Published var selectedAreaSummary: String?
    @Published var lastError: String?
    @Published var lastOutputFolder: URL?

    private let clock = SharedPauseClock()
    private let meter = MicLevelMeter()
    private var screenRecorder: ScreenRecorder?
    private var webcamRecorder: WebcamRecorder?
    private var eventLogger: EventLogger?
    private var outputFolder: URL?
    private var selectedWindowID: CGWindowID?
    private var selectedArea: AreaSelection?
    private var pendingPlan: CapturePlan?
    private var elapsedTimer: Timer?
    private var countdown: CountdownOverlayController?
    private var iconsHidden = false
    private var recordingStartHost: Double = 0

    var sourceMode: SourceMode {
        SourceMode(rawValue: settings.sourceMode) ?? .display
    }

    var hasCameraSelected: Bool { selectedCamera != nil }
    var hasMicSelected: Bool { selectedMicrophone != nil }

    /// Called with the .vibestudio bundle URL (or the loose folder if import
    /// failed) after a recording is stopped and saved.
    var onRecordingFinished: ((URL) -> Void)?

    var selectedCamera: AVCaptureDevice? {
        guard let id = settings.selectedCameraID else { return nil }
        return cameras.first { $0.uniqueID == id }
    }

    var selectedMicrophone: AVCaptureDevice? {
        guard let id = settings.selectedMicID else { return nil }
        return microphones.first { $0.uniqueID == id }
    }

    init() {
        settings = SettingsStore.load()
        refreshDevices()
        meter.onLevel = { [weak self] level in
            self?.micLevel = level
        }
        updateCameraPreview()
        updateMicMeter()
    }

    func refreshDevices() {
        cameras = DeviceCatalog.videoDevices()
        microphones = DeviceCatalog.audioDevices()
    }

    // MARK: - Source selection

    func selectDisplayMode() {
        settings.sourceMode = SourceMode.display.rawValue
    }

    func selectWindowInteractively() {
        WindowPickerController().pickWindow { [weak self] window in
            guard let self, let window else { return }
            self.selectedWindowID = window.windowID
            let app = window.owningApplication?.applicationName ?? ""
            self.selectedWindowTitle = window.title?.isEmpty == false ? window.title! : app
            self.settings.sourceMode = SourceMode.window.rawValue
        }
    }

    func selectAreaInteractively() {
        AreaSelectionController().pickArea { [weak self] screen, rectAppKitGlobal in
            guard let self, let screen, let rect = rectAppKitGlobal else { return }
            guard let displayID = screen.displayID else {
                self.lastError = "Could not identify the selected display."
                return
            }
            let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
            let displayFrameCG = CoordinateMapper.appKitRectToCG(screen.frame, primaryHeight: primaryHeight)
            let scale = screen.backingScaleFactor
            let sourceRect = CoordinateMapper.areaSourceRectPixels(dragRectAppKitGlobal: rect,
                                                                   displayFrameCG: displayFrameCG,
                                                                   scale: scale,
                                                                   primaryHeight: primaryHeight)
            self.selectedArea = AreaSelection(displayID: displayID,
                                              displayFrameCG: displayFrameCG,
                                              sourceRectPixels: sourceRect,
                                              scale: scale)
            self.selectedAreaSummary = "\(Int(rect.width))×\(Int(rect.height))"
            self.settings.sourceMode = SourceMode.area.rawValue
        }
    }

    // MARK: - Preview / meter

    private func updateCameraPreview() {
        previewSession?.stopRunning()
        previewSession = nil
        guard phase == .setup, let device = selectedCamera else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startPreview(with: device)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    if granted { self?.startPreview(with: device) }
                }
            }
        default:
            lastError = "Camera access denied — enable it in System Settings > Privacy & Security > Camera."
        }
    }

    private func startPreview(with device: AVCaptureDevice) {
        guard phase == .setup else { return }
        let session = AVCaptureSession()
        session.sessionPreset = .medium
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return }
        session.addInput(input)
        previewSession = session
        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
        }
    }

    private func updateMicMeter() {
        if phase == .setup, let mic = selectedMicrophone {
            ensureAudioPermission { [weak self] granted in
                guard granted else { return }
                self?.meter.start(deviceUniqueID: mic.uniqueID)
            }
        } else {
            meter.stop()
        }
    }

    private func ensureAudioPermission(completion: @escaping @MainActor (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in completion(granted) }
            }
        default:
            lastError = "Microphone access denied — enable it in System Settings > Privacy & Security > Microphone."
            completion(false)
        }
    }

    // MARK: - Recording control

    /// Bound to the record button and the global hotkey.
    func toggleRecording() {
        switch phase {
        case .setup:
            startRecording()
        case .recording, .paused:
            stopAndSave()
        case .countingDown:
            cancelCountdown()
        }
    }

    func startRecording() {
        guard phase == .setup else { return }
        lastError = nil
        Task {
            do {
                let plan = try await buildCapturePlan()
                pendingPlan = plan
                if settings.countdownEnabled {
                    phase = .countingDown
                    let finished = await runCountdown()
                    guard finished, phase == .countingDown else { return }
                }
                try await beginCapture(plan: plan)
            } catch {
                lastError = error.localizedDescription
                phase = .setup
                pendingPlan = nil
            }
        }
    }

    private func cancelCountdown() {
        countdown?.cancel()
        countdown = nil
        phase = .setup
        pendingPlan = nil
    }

    private func runCountdown() async -> Bool {
        await withCheckedContinuation { continuation in
            let controller = CountdownOverlayController()
            countdown = controller
            controller.run { [weak self] finished in
                self?.countdown = nil
                continuation.resume(returning: finished)
            }
        }
    }

    private func beginCapture(plan: CapturePlan) async throws {
        if !CGPreflightListenEventAccess() {
            _ = CGRequestListenEventAccess()
        }
        requestAccessibilityPermission()

        if settings.hideDesktopIcons {
            DesktopIconHider.setHidden(true)
            iconsHidden = true
        }

        meter.stop()
        previewSession?.stopRunning()
        previewSession = nil

        let folder = try OutputLocation.newRecordingFolder()
        outputFolder = folder

        recordingStartHost = CACurrentMediaTime()
        clock.start(at: recordingStartHost)

        let recorder = ScreenRecorder(clock: clock)
        try await recorder.start(filter: plan.filter,
                                 configuration: plan.configuration,
                                 outputURL: folder.appendingPathComponent("recording.mov"))
        screenRecorder = recorder

        if selectedCamera != nil || selectedMicrophone != nil {
            let webcam = WebcamRecorder(clock: clock)
            try webcam.start(camera: selectedCamera,
                             microphone: selectedMicrophone,
                             outputURL: folder.appendingPathComponent("webcam.mov"))
            webcamRecorder = webcam
        }

        let logger = EventLogger(clock: clock)
        logger.start()
        eventLogger = logger
        if !logger.tapIsActive {
            lastError = "Event capture inactive — grant Input Monitoring to record cursor/click events."
        }

        isMicMuted = false
        isCameraOff = false
        phase = .recording
        startElapsedTimer()
    }

    private func requestAccessibilityPermission() {
        guard !AXIsProcessTrusted() else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func pauseRecording() {
        guard phase == .recording else { return }
        clock.pause(at: CACurrentMediaTime())
        phase = .paused
    }

    func resumeRecording() {
        guard phase == .paused else { return }
        clock.resume(at: CACurrentMediaTime())
        phase = .recording
    }

    func toggleMicMute() {
        guard hasMicSelected else { return }
        isMicMuted.toggle()
        webcamRecorder?.setMicMuted(isMicMuted)
    }

    func toggleCamera() {
        guard hasCameraSelected else { return }
        isCameraOff.toggle()
        webcamRecorder?.setCameraOff(isCameraOff)
    }

    func stopAndSave() {
        guard phase == .recording || phase == .paused else { return }
        phase = .setup
        stopElapsedTimer()
        Task { await teardown(save: true) }
    }

    func discardRecording() {
        guard phase == .recording || phase == .paused else { return }
        phase = .setup
        stopElapsedTimer()
        Task { await teardown(save: false) }
    }

    private func teardown(save: Bool) async {
        let folder = outputFolder
        let plan = pendingPlan
        var screenFirstVideo: Double?
        var screenFirstAudio: Double?
        var webcamFirstVideo: Double?
        var webcamFirstAudio: Double?

        if save, let folder {
            do {
                try eventLogger?.stopAndFlush(to: folder.appendingPathComponent("events.json"))
            } catch {
                lastError = "Failed to write events.json: \(error.localizedDescription)"
            }
        } else {
            eventLogger?.stopCapture()
        }
        eventLogger = nil

        if let recorder = screenRecorder {
            if save {
                try? await recorder.finish()
                screenFirstVideo = recorder.firstVideoHostSeconds
                screenFirstAudio = recorder.firstAudioHostSeconds
            } else {
                await recorder.abort()
            }
            screenRecorder = nil
        }
        if let webcam = webcamRecorder {
            if save {
                await webcam.finish()
                webcamFirstVideo = webcam.firstVideoHostSeconds
                webcamFirstAudio = webcam.firstAudioHostSeconds
            } else {
                await webcam.abort()
            }
            webcamRecorder = nil
        }

        if save, let folder, let plan {
            writeMeta(to: folder, plan: plan,
                      screenFirstVideo: screenFirstVideo,
                      screenFirstAudio: screenFirstAudio,
                      webcamFirstVideo: webcamFirstVideo,
                      webcamFirstAudio: webcamFirstAudio)
            lastOutputFolder = folder
            do {
                let bundle = try ProjectStore.importLooseFolder(folder, to: nil)
                onRecordingFinished?(bundle)
            } catch {
                lastError = "Saved, but bundle import failed: \(error.localizedDescription)"
                onRecordingFinished?(folder)
            }
        } else if let folder {
            try? FileManager.default.removeItem(at: folder)
        }

        if iconsHidden {
            DesktopIconHider.setHidden(false)
            iconsHidden = false
        }
        outputFolder = nil
        pendingPlan = nil
        elapsed = 0
        updateCameraPreview()
        updateMicMeter()
    }

    private func writeMeta(to folder: URL, plan: CapturePlan,
                           screenFirstVideo: Double?, screenFirstAudio: Double?,
                           webcamFirstVideo: Double?, webcamFirstAudio: Double?) {
        var files = ["recording.mov", "events.json", "recording-meta.json"]
        if selectedCamera != nil || selectedMicrophone != nil { files.append("webcam.mov") }
        let meta = RecordingMeta(
            createdAt: Date(),
            sourceMode: sourceMode.rawValue,
            displayID: plan.displayID,
            displayFrameCGPoints: plan.displayFrameCG,
            scaleFactor: Double(plan.scale),
            outputPixelSize: CGSize(width: plan.configuration.pixelWidth, height: plan.configuration.pixelHeight),
            sourceRectPixels: plan.configuration.sourceRectPixels,
            windowID: plan.windowID,
            windowFrameCGPoints: plan.windowFrameCG,
            frameRate: plan.configuration.frameRate,
            systemAudioCaptured: plan.configuration.captureSystemAudio,
            screenFirstHostSeconds: screenFirstVideo,
            webcamFirstHostSeconds: webcamFirstVideo,
            micFirstHostSeconds: webcamFirstAudio ?? screenFirstAudio,
            files: files)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(meta).write(to: folder.appendingPathComponent("recording-meta.json"), options: .atomic)
        } catch {
            lastError = "Failed to write recording-meta.json: \(error.localizedDescription)"
        }
    }

    // MARK: - Elapsed timer

    private func startElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.elapsed = max(0, self.clock.mediaTime(CACurrentMediaTime()))
            }
        }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    // MARK: - Capture plan

    struct CapturePlan {
        var filter: SCContentFilter
        var configuration: ScreenRecorder.Configuration
        var displayID: CGDirectDisplayID
        var displayFrameCG: CGRect
        var scale: CGFloat
        var windowID: CGWindowID?
        var windowFrameCG: CGRect?
    }

    private func buildCapturePlan() async throws -> CapturePlan {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let ownBundleID = Bundle.main.bundleIdentifier
        let ownWindows = content.windows.filter { $0.owningApplication?.bundleIdentifier == ownBundleID }
        let fps = settings.frameRate
        let cap = settings.resolutionCap

        switch sourceMode {
        case .display:
            guard let display = content.displays.first else { throw RecorderError.missingSelection }
            let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
            let native = CGSize(width: display.width, height: display.height)
            let scale = display.frame.width > 0 ? native.width / display.frame.width : 1
            let size = CoordinateMapper.cappedPixelSize(native: native, cap: cap)
            return CapturePlan(filter: filter,
                               configuration: ScreenRecorder.Configuration(
                                   pixelWidth: Int(size.width), pixelHeight: Int(size.height),
                                   frameRate: fps, sourceRectPixels: nil,
                                   captureSystemAudio: settings.captureSystemAudio),
                               displayID: display.displayID,
                               displayFrameCG: display.frame,
                               scale: scale, windowID: nil, windowFrameCG: nil)

        case .window:
            guard let id = selectedWindowID,
                  let window = content.windows.first(where: { $0.windowID == id }) else {
                throw RecorderError.missingSelection
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let scale = Self.scaleFactor(for: window.frame, displays: content.displays)
            let native = CoordinateMapper.nativePixelSize(pointSize: window.frame.size, scale: scale)
            let size = CoordinateMapper.cappedPixelSize(native: native, cap: cap)
            return CapturePlan(filter: filter,
                               configuration: ScreenRecorder.Configuration(
                                   pixelWidth: Int(size.width), pixelHeight: Int(size.height),
                                   frameRate: fps, sourceRectPixels: nil,
                                   captureSystemAudio: settings.captureSystemAudio),
                               displayID: Self.display(for: window.frame, displays: content.displays)?.displayID ?? CGMainDisplayID(),
                               displayFrameCG: Self.display(for: window.frame, displays: content.displays)?.frame ?? window.frame,
                               scale: scale, windowID: window.windowID, windowFrameCG: window.frame)

        case .area:
            guard let area = selectedArea,
                  let display = content.displays.first(where: { $0.displayID == area.displayID }) else {
                throw RecorderError.missingSelection
            }
            let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
            let native = area.sourceRectPixels.size
            let size = CoordinateMapper.cappedPixelSize(native: native, cap: cap)
            return CapturePlan(filter: filter,
                               configuration: ScreenRecorder.Configuration(
                                   pixelWidth: Int(size.width), pixelHeight: Int(size.height),
                                   frameRate: fps, sourceRectPixels: area.sourceRectPixels,
                                   captureSystemAudio: settings.captureSystemAudio),
                               displayID: area.displayID,
                               displayFrameCG: area.displayFrameCG,
                               scale: area.scale, windowID: nil, windowFrameCG: nil)

        case .device:
            throw RecorderError.unsupportedMode
        }
    }

    private static func display(for frameCG: CGRect, displays: [SCDisplay]) -> SCDisplay? {
        displays.first { $0.frame.intersects(frameCG) } ?? displays.first
    }

    private static func scaleFactor(for frameCG: CGRect, displays: [SCDisplay]) -> CGFloat {
        guard let display = display(for: frameCG, displays: displays), display.frame.width > 0 else { return 1 }
        return CGFloat(display.width) / display.frame.width
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
