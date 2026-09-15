import SwiftUI

struct PillView: View {
    @EnvironmentObject var session: RecordingSession

    var body: some View {
        Group {
            switch session.phase {
            case .setup, .countingDown:
                setupPill
            case .recording, .paused:
                recordingPill
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
    }

    // MARK: - Setup state

    private var setupPill: some View {
        HStack(spacing: 10) {
            sourceMenu
            divider
            cameraMenu
            if let preview = session.previewSession {
                CameraPreviewView(session: preview)
                    .frame(width: 56, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            divider
            micMenu
            LevelMeterView(level: session.micLevel)
                .frame(width: 36, height: 8)
                .opacity(session.hasMicSelected ? 1 : 0.3)
            systemAudioToggle
            divider
            settingsButton
            recordButton
        }
        .foregroundStyle(.white)
    }

    private var divider: some View {
        Divider().frame(height: 24)
    }

    private var sourceMenu: some View {
        Menu {
            Button {
                session.selectDisplayMode()
            } label: {
                Label("Entire Display", systemImage: "display")
            }
            Button {
                session.selectWindowInteractively()
            } label: {
                Label("Window…", systemImage: "macwindow")
            }
            Button {
                session.selectAreaInteractively()
            } label: {
                Label("Screen Area…", systemImage: "crop")
            }
            Divider()
            Button {
            } label: {
                Label("Device (coming in v2)", systemImage: "iphone")
            }
            .disabled(true)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: sourceIcon)
                Text(sourceLabel)
                    .lineLimit(1)
                    .frame(maxWidth: 120)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var sourceIcon: String {
        switch session.sourceMode {
        case .display: return "display"
        case .window: return "macwindow"
        case .area: return "crop"
        case .device: return "iphone"
        }
    }

    private var sourceLabel: String {
        switch session.sourceMode {
        case .display: return "Display"
        case .window: return session.selectedWindowTitle ?? "Window"
        case .area: return session.selectedAreaSummary ?? "Area"
        case .device: return "Device"
        }
    }

    private var cameraMenu: some View {
        Menu {
            Button("None") { session.settings.selectedCameraID = nil }
            if !session.cameras.isEmpty {
                Divider()
                ForEach(session.cameras, id: \.uniqueID) { device in
                    Button(device.localizedName) { session.settings.selectedCameraID = device.uniqueID }
                }
            }
        } label: {
            Image(systemName: session.hasCameraSelected ? "video.fill" : "video.slash")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var micMenu: some View {
        Menu {
            Section("What sound do you want to record?") {
                Button("No microphone") { session.settings.selectedMicID = nil }
                ForEach(session.microphones, id: \.uniqueID) { device in
                    Button(device.localizedName) { session.settings.selectedMicID = device.uniqueID }
                }
            }
        } label: {
            Image(systemName: session.hasMicSelected ? "mic.fill" : "mic.slash")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var systemAudioToggle: some View {
        Button {
            session.settings.captureSystemAudio.toggle()
        } label: {
            Image(systemName: session.settings.captureSystemAudio ? "speaker.wave.2.fill" : "speaker.slash.fill")
                .foregroundStyle(session.settings.captureSystemAudio ? .white : .secondary)
        }
        .buttonStyle(.plain)
        .help("Capture system audio")
    }

    private var settingsButton: some View {
        SettingsGearButton()
            .environmentObject(session)
    }

    private var recordButton: some View {
        Button {
            session.toggleRecording()
        } label: {
            Circle()
                .fill(Color.red)
                .frame(width: 22, height: 22)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.6), lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .help("Start recording (\(session.settings.hotkeyDisplay))")
    }

    // MARK: - Recording state

    private var recordingPill: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(session.phase == .paused ? Color.orange : Color.red)
                .frame(width: 8, height: 8)
            Text(Self.timeString(session.elapsed))
                .font(.system(.body, design: .monospaced).monospacedDigit())
                .frame(minWidth: 52, alignment: .leading)

            Button {
                session.phase == .paused ? session.resumeRecording() : session.pauseRecording()
            } label: {
                Image(systemName: session.phase == .paused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(.plain)
            .help(session.phase == .paused ? "Resume" : "Pause")

            Button {
                session.stopAndSave()
            } label: {
                Image(systemName: "stop.fill")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help("Stop and save (\(session.settings.hotkeyDisplay))")

            Button {
                session.toggleMicMute()
            } label: {
                Image(systemName: session.isMicMuted ? "mic.slash.fill" : "mic.fill")
                    .foregroundStyle(session.hasMicSelected ? .white : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(!session.hasMicSelected)
            .help("Toggle microphone")

            Button {
                session.toggleCamera()
            } label: {
                Image(systemName: session.isCameraOff ? "video.slash.fill" : "video.fill")
                    .foregroundStyle(session.hasCameraSelected ? .white : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(!session.hasCameraSelected)
            .help("Toggle camera")

            Button {
                session.discardRecording()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .help("Discard recording")
        }
        .foregroundStyle(.white)
    }

    static func timeString(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct LevelMeterView: View {
    var level: Float

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.15))
                Capsule()
                    .fill(level > 0.8 ? Color.red : Color.green)
                    .frame(width: geometry.size.width * CGFloat(min(max(level, 0), 1)))
            }
        }
    }
}

private struct SettingsGearButton: View {
    @EnvironmentObject var session: RecordingSession
    @State private var showPopover = false

    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            Image(systemName: "gearshape")
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPopover, arrowEdge: .top) {
            SettingsPopoverView()
                .environmentObject(session)
        }
        .help("Recording settings")
    }
}

struct SettingsPopoverView: View {
    @EnvironmentObject var session: RecordingSession

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Resolution", selection: $session.settings.resolutionCap) {
                Text("Source native").tag(RecordingSettings.ResolutionCap.native)
                Text("1080p cap").tag(RecordingSettings.ResolutionCap.p1080)
                Text("4K cap").tag(RecordingSettings.ResolutionCap.p4k)
            }
            Picker("Frame rate", selection: $session.settings.frameRate) {
                Text("30 fps").tag(30)
                Text("60 fps").tag(60)
            }
            Toggle("3-2-1 countdown", isOn: $session.settings.countdownEnabled)
            Toggle("Hide desktop icons while recording", isOn: $session.settings.hideDesktopIcons)
            HStack {
                Text("Record shortcut")
                Spacer()
                Text(session.settings.hotkeyDisplay)
                    .foregroundStyle(.secondary)
            }
            if let error = session.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Button("Quit VibeStudio") {
                NSApp.terminate(nil)
            }
        }
        .padding()
        .frame(width: 280)
    }
}
