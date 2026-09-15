# Decisions log

Every tuneable constant and visual-quality decision lands here with its reason.

| Date | Decision | Value | Why |
|---|---|---|---|
| 2026-09-14 | Stack | Native Swift + SwiftUI, no SPM deps | Master prompt §2: ScreenCaptureKit + Metal + VideoToolbox quality, headless xcodebuild |
| 2026-09-14 | Deployment target | macOS 14.0 | Master prompt §0/§2 |
| 2026-09-14 | Signing | Ad-hoc (`CODE_SIGN_IDENTITY = "-"`), no sandbox | Local-only distribution, zero cost, zero accounts; TCC re-prompt per rebuild is documented in README |
| 2026-09-14 | Project format | objectVersion 77, file-system-synchronized groups | Agents add Swift files without touching project.pbxproj |
| 2026-09-15 | Global hotkey | ⌘⇧2 via Carbon `RegisterEventHotKey` (fixed default, shown read-only in settings) | Works without Input Monitoring, frontmost-app independent; configurable hotkey deferred |
| 2026-09-15 | Default capture settings | 60 fps, source-native resolution, system audio ON, countdown OFF, hide-desktop-icons OFF | Screen Studio parity: 60 fps is the quality baseline; caps (1080p/4K by height) only shrink output |
| 2026-09-15 | Resolution cap semantics | Cap by HEIGHT (1080 / 2160), aspect preserved, rounded to even pixels | H.264 needs even dims; height-cap matches "1080p"/"4K" naming |
| 2026-09-15 | Writer threading | One serial DispatchQueue per writer input (screen video / screen audio / webcam); frames dropped when `isReadyForMoreMediaData` is false | Never block the capture pipeline; AVAssetWriterInput is not thread-safe for concurrent appends |
| 2026-09-15 | Pause math | Shared `PauseCompensator` (host-clock seconds domain, one instance per recording) subtracts accumulated paused time from buffer PTS; buffers dropped while paused | Single clock keeps screen video, system audio, webcam, mic and events.json aligned across pauses; mic-mute and camera-off use per-track compensators in WebcamRecorder |
| 2026-09-15 | Event tap | `CGEvent.tapCreate` .cghidEventTap listen-only on a dedicated Thread's CFRunLoop; timestamps from CGEvent.timestamp (mach) converted via mach_timebase_info | Tap callbacks must live on a run loop; mach-domain matches buffer PTS so event `t` aligns with video |
| 2026-09-15 | cursorType events | Schema supports `cursorType(name)`; runtime logs a single `arrow` at t=0 | Reliable cross-app cursor-type detection needs polling/AX tricks — deferred, flagged in roadmap risk list |
| 2026-09-15 | Area-mode sourceRect | `SCStreamConfiguration.sourceRect` set in PIXELS (points × backingScaleFactor, top-left origin) per Phase 1 brief | **Live-verify item**: Apple docs describe sourceRect as points in some contexts; if the recorded region is wrong, divide by scale in `buildCapturePlan()` (.area case) — single-line fix |
| 2026-09-15 | Pill panel | NSPanel .borderless + .nonactivatingPanel, level .statusBar, canJoinAllSpaces + fullScreenAuxiliary; pickers/countdown use .screenSaver level | Non-activating keeps focus on the user's apps; picker overlays need key status (Esc) so they activate the app transiently |
| 2026-09-15 | UI tick rates | Elapsed timer 0.1 s; mic level meter 10 Hz (−50…0 dB → 0…1); countdown 1 s steps | Cheap, smooth enough for a pill |
| 2026-09-15 | Output layout | `~/Movies/VibeStudio/<yyyy-MM-dd_HH-mm-ss>/{recording.mov, webcam.mov?, events.json, recording-meta.json}` | Per-session folder; meta carries capture mapping + first-buffer host times (sync offsets) for Phase 2/3 alignment |
| 2026-09-15 | Self-exclusion from capture | SCContentFilter(display:excludingWindows:) with all SCWindows owned by our bundle ID (pill, overlays, countdown) | Window-mode filter is desktopIndependentWindow so the pill is excluded by construction |
| 2026-09-15 | Sync offset | recording-meta.json stores screen/webcam/mic first-buffer host-clock seconds | Both SCKit and AVCaptureSession PTS are host-clock based, so simple subtraction aligns files in Phase 2 |
