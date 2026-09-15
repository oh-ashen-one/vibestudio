# AGENTS.md — VibeStudio

Guidance for coding agents working in this repo.

## Build / test / run (headless, always)

```bash
./scripts/build.sh    # xcodebuild Debug build into .build/
./scripts/run.sh      # build + open the app
./scripts/test.sh     # xcodebuild test (scheme VibeStudio, Debug)
```

- Never edit `VibeStudio.xcodeproj/project.pbxproj` to add files: the project
  uses file-system-synchronized groups — any `.swift` file you create inside
  `VibeStudio/` or `Tests/` is automatically part of that target.
- The build must stay green. Before finishing any task: run `./scripts/build.sh`;
  if you touched logic, run `./scripts/test.sh`.
- Ad-hoc signed (`CODE_SIGN_IDENTITY = "-"`), sandbox OFF, no entitlements
  file. Do not add signing requirements, entitlements, or paid tooling.

## Architecture map (grows per phase)

- `VibeStudio/VibeStudioApp.swift` — app entry; accessory app, creates the pill + global hotkey.
- `VibeStudio/Core/` — pure, unit-tested logic:
  - `CoordinateMapper.swift` — CG global ↔ AppKit ↔ ScreenCaptureKit pixel conversions, `CaptureMapping` event→video projection, resolution capping.
  - `PauseCompensator.swift` — pause-gap timestamp math + thread-safe `SharedPauseClock` (host-clock domain).
  - `CursorSmoothing.swift` — §3.2: uniform resample (anchor-based 2 px jitter suppression) + critically-damped spring presets.
  - `EventProjector.swift` — recording-meta.json → event→video-pixel projection (incl. resolution-cap ratio).
  - `EventTypes.swift` — `events.json` / `recording-meta.json` Codable schema (spec §3.1).
  - `RecordingSettings.swift` — settings persisted as JSON in UserDefaults.
  - `OutputLocation.swift` — `~/Movies/VibeStudio/<timestamp>/` session folders.
- `VibeStudio/Project/ProjectBundle.swift` — `.vibestudio` package: `ProjectState`
  (project.json), `ProjectStore.importLooseFolder` / `load`. CGRect/CGSize
  encode as arrays (`[[x,y],[w,h]]` / `[w,h]`) — keep fixtures byte-compatible.
- `VibeStudio/Editor/` — editor window (`EditorWindowManager` NSWindow +
  `EditorView` AVPlayer + scrubber + `CursorOverlayView` Canvas debug overlay),
  `EditorViewModel` (loads bundle, precomputes raw/smoothed paths, 1/30 s time
  observer), `DevSmokeTest` (headless load check).
- `VibeStudio/main.swift` — custom entry: `-open <path> -smokeTest` verifies a
  bundle synchronously and exits before AppKit boots (headless/SSH safe);
  `-open <path>` alone opens the editor. Window restoration is disabled.
- `VibeStudio/Capture/` — capture engine:
  - `ScreenRecorder.swift` — SCStream → AVAssetWriter (H.264 + AAC system audio), retina scale, per-input serial queues, drop-on-not-ready.
  - `WebcamRecorder.swift` — AVCaptureSession (camera and/or mic) → webcam.mov; mic-mute / camera-off compensators.
  - `EventLogger.swift` — CGEvent tap on a dedicated run-loop thread → in-memory events → events.json; NSWorkspace + AX frontmost-window events.
  - `MicLevelMeter.swift` — AVAudioEngine input tap, 10 Hz level for the setup pill.
  - `DeviceCatalog.swift`, `DesktopIconHider.swift`.
- `VibeStudio/Session/RecordingSession.swift` — orchestrator: source selection (display/window/area), countdown, hide-desktop-icons, pause/resume/stop/discard, meta writing.
- `VibeStudio/UI/` — pill panel (`PillWindowController` + `PillView`), window/area picker overlays, countdown overlay, camera preview, Carbon global hotkey (⌘⇧2).
- Capture: ScreenCaptureKit (`SCStream`), retina scale, 60 fps; the pill excludes
  itself via `SCContentFilter(display:excludingWindows:)` with our own SCWindows.
- Events: `CGEvent.tapCreate` global tap (cursor/click/key/scroll) logged with
  timestamps → `events.json` next to the recording.
- Render: Metal compositor (preview + export share the same code path).
- Export: AVAssetWriter + VideoToolbox.
- Project bundle: `*.vibestudio` package (video + webcam + events.json +
  project.json).

## Working rules

- Verify by running, not by compiling: after user-visible changes, launch the
  app and exercise the feature.
- Tuneable constants and visual decisions → log them in `DECISIONS.md` with
  the reason.
- Commit per feature (conventional commits). Push in the same session —
  the GitHub remote is the source of truth; never leave local-only commits.
- Zero network calls, zero accounts, zero telemetry in the app. Ever.
- Spec of record: `~/Desktop/screen-studio-clone-master-prompt.md` (phases and
  acceptance criteria). README roadmap mirrors it.

## Permissions during development

TCC keys permissions to the ad-hoc-signed binary; a rebuild may invalidate a
grant. If capture/events silently stop working, reset and re-grant:

```bash
tccutil reset ScreenCapture dev.vibestudio.app
tccutil reset ListenEvent dev.vibestudio.app
tccutil reset Accessibility dev.vibestudio.app
```
