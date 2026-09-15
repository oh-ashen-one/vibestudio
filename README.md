# VibeStudio

**Free, open-source Screen Studio alternative for macOS.**
Record your screen — auto-zoom, smooth cursor, motion blur and styled frames
are added automatically. 100% local, 100% free, MIT licensed.

> Status: early development. Feature set is being built in phases; see
> [DECISIONS.md](DECISIONS.md) and the roadmap below.

## Quick start (zero to a recording in <5 minutes)

Requirements: macOS 14+, Xcode 15+ (free from the App Store / Apple Developer).

```bash
git clone https://github.com/oh-ashen-one/vibestudio.git
cd vibestudio
./scripts/run.sh        # builds headlessly and launches the app
```

On first run macOS will ask for permissions — grant all four (they are what
makes the automatic editing possible):

| Permission | Why |
|---|---|
| Screen Recording | Capture your screen |
| Microphone | Record voiceover |
| Camera | Record webcam bubble |
| Input Monitoring / Accessibility | Track cursor, clicks and keystrokes for auto-zoom |

If a permission breaks or you denied one by accident, reset and re-grant:

```bash
tccutil reset ScreenCapture dev.vibestudio.app
tccutil reset Microphone dev.vibestudio.app
tccutil reset Camera dev.vibestudio.app
tccutil reset ListenEvent dev.vibestudio.app
tccutil reset Accessibility dev.vibestudio.app
```

> Note: local builds are ad-hoc signed. macOS ties permissions to the signed
> binary, so after rebuilding you may need to re-grant a permission once.

## Repo layout

- `VibeStudio/` — app sources (SwiftUI + ScreenCaptureKit + Metal)
- `Tests/` — unit tests (run: `./scripts/test.sh`)
- `scripts/build.sh` — headless build → `.build/Build/Products/Debug/VibeStudio.app`
- `scripts/run.sh` — build + launch
- `scripts/test.sh` — build + run unit tests
- `scripts/make_fixture.sh` — generate a deterministic fake recording
  (`Fixtures/sample-recording/`, gitignored) for development without
  screen-recording permission

### Inspecting a recording without permissions

```bash
./scripts/make_fixture.sh            # once, regenerable any time
.build/Build/Products/Debug/VibeStudio.app/Contents/MacOS/VibeStudio \
  -open "$PWD/Fixtures/sample-recording" -smokeTest   # headless load check
.build/Build/Products/Debug/VibeStudio.app/Contents/MacOS/VibeStudio \
  -open "$PWD/Fixtures/sample-recording.vibestudio"   # open editor window
```

## Roadmap

- [x] Phase 0 — project scaffold, headless build + tests
- [x] Phase 1 — recorder: floating pill (display/window/area source, camera,
      mic, settings), ScreenCaptureKit capture, cursor/click/keystroke events
      (code complete, live recording verification pending)
- [x] Phase 2 — project model + player (code complete; editor window
      appearance/playback verified headlessly via fixture + smoke test,
      interactive visual verification pending)
- [x] Phase 3 — auto-zoom, smooth cursor, styled frame, camera layouts
      (code complete; auto-zoom + camera evaluation verified headlessly on the
      fixture, on-screen visual verification pending)
- [x] Phase 4 — export (MP4, aspect-ratio re-targeting, In/Out trim).
      Verified: CLI smoke exports of the fixture (16:9 full, 16:9 trimmed
      5–10s, 9:16) probe-checked with ffprobe and frame-extracted with ffmpeg;
      preview visually re-verified on a live display after the compositor
      refactor
- [x] Phase 5 — polish: click ripples, keystroke badges, GIF export, manual
      zoom focus-rect editing, hide-static-cursor, loop cursor end, presets
      save/share. Verified: live preview screenshots (ripple ring, upright
      ⌘ badges, focus-rect editor), CLI export frames (ripple + badge in
      video), fixture.gif (852x480, 900 frames, frame-inspected), hide-static
      and loop-end exports frame-checked. Speed-up segments deferred
      (see DECISIONS.md)

## License

MIT — see [LICENSE](LICENSE). No accounts, no telemetry, no network calls.
