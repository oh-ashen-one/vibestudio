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

> Note: local builds are ad-hoc signed by default. macOS ties permissions to
> the signed binary, so after rebuilding you may need to re-grant a permission
> once.

### Stable permissions for developers

Ad-hoc signing changes the binary's cdhash on every rebuild, which voids the
TCC grants above. To make grants survive rebuilds on your machine, create the
free self-signed identity once:

```bash
./scripts/create_dev_cert.sh   # creates "VibeStudio Dev" in your login keychain
```

From then on `scripts/build.sh` / `scripts/test.sh` auto-detect the identity
and sign with it (`CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="VibeStudio Dev"`),
so macOS binds permissions to the stable certificate instead of the per-build
hash. Re-grant **once** after the first stable-signed build; every later build
keeps working. The repo default stays ad-hoc (`CODE_SIGN_IDENTITY = "-"` in the
project), so a fresh clone needs no setup; keys live in the gitignored
`.signing/` directory and are never committed.

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
      (verified live on-machine: pill-driven 30s+ recording with pause/resume,
      events.json within [0, duration], pill self-excluded from capture)
- [x] Phase 2 — project model + player. Verified on a live display: editor
      opens the fixture bundle, video plays, raw+smoothed cursor paths render
      over the correct pixels, scrubber seeks
- [x] Phase 3 — auto-zoom, smooth cursor, styled frame, camera layouts.
      Verified on a live display: 7 auto keyframes on the fixture with 300ms
      click anticipation, Metal preview (zoomed camera, synthetic cursor,
      motion blur, rounded frame + shadow), webcam bubble/full layouts,
      background gallery
- [x] Phase 4 — export (MP4, aspect-ratio re-targeting, In/Out trim).
      Verified: CLI exports of the fixture (16:9 full, 16:9 trimmed 5–10s,
      9:16) probe-checked with ffprobe and frame-extracted; 9:16 follows the
      action (not a center crop); preview and export share one Metal
      compositor so framing matches
- [x] Phase 5 — polish: click ripples, keystroke badges, GIF export, manual
      zoom focus-rect editing, hide-static-cursor, loop cursor end, presets
      save/share. Verified: export frames show ripple at the click pixel,
      ⌘ badges, cursor trail; fixture.gif (852x480, 900 frames)
      frame-inspected. Speed-up segments deferred (see DECISIONS.md)

## Verification status (acceptance criteria)

- [x] Fresh clone → `./scripts/build.sh` builds in seconds; `./scripts/test.sh`
      green (111 tests, including an automated preview-vs-export consistency
      test: real FrameStateBuilder+FrameComposer renders vs real ExportRenderer
      output at three timestamps — mean abs luma diff ≤0.41/255, PSNR ≥49.6dB)
- [x] Zero network calls / accounts / telemetry in app sources; MIT licensed
- [x] Auto-zoom + smooth cursor + motion blur + styled frame visible in
      exports; every auto-zoom editable on the timeline with live preview
- [x] 9:16 re-targeting keeps the action framed
- [x] End-to-end recording on this machine (pill-driven 30s+ recording with
      pause/resume; moov intact; events within [0, duration]; pill excluded
      from its own capture)
- [ ] Side-by-side comparison GIFs against a real Screen Studio export
      (planned when the machine is free for interactive work)

## Known limitations vs Screen Studio

Implemented and verified: pill-driven recording (display/window/area sources,
camera + mic + system audio, pause/resume, self-exclusion), event capture
(cursor/click/scroll/key/frontmost-window), project bundles, auto-zoom with
editable timeline, smoothed synthetic cursor, motion blur, styled frames with
background gallery, webcam bubble/full layouts, aspect-ratio re-targeted MP4
export, In/Out trim, GIF export, click ripples, keystroke badges,
hide-static-cursor, loop cursor end, settings presets.

Missing or weaker than Screen Studio:

- **Speed-up segments** — deferred (logged in DECISIONS.md). Timeline has
  In/Out trim only.
- **Audio cleanup** — no voice normalization or background-noise removal.
- **Transcription / captions** — not implemented.
- **iPhone/iPad recording** — device mode is shown disabled in the pill (v2).
- **Shareable links / cloud** — out of scope by design (zero network).
- **Webcam bubble dodge-the-cursor** — bubble is fixed bottom-right.
- **Cursor variants** — only the arrow is re-rendered synthetically; other
  system cursors (I-beam, pointer, crosshair) are not swapped for high-res
  versions (cursorType is captured in events.json but not acted on).
- **GIF quality** — median-cut global palette is fine for UI content;
  photographic content will band.
- **4K export performance** — the serialized per-frame render loop is
  unmeasured at 4K; 1080p60 exports of 30s fixtures complete in seconds.

Honest caveats already on record (see DECISIONS.md):

- The one observed writer stall (video stopped growing ~6s into a 4.5min
  recording) is **instrumented but not proven fixed** — it did not recur in
  later live recordings; permanent stderr counters now report pipeline health.
- Webcam/screen sync in the **preview** uses two unsynchronized AVPlayers;
  sample-accurate sync (meta host-time offsets) is applied at export only.
- Loop-cursor-end is previewable only by dragging the playhead past the end
  (AVPlayer cannot play past the media end); it renders fully in exports.
- Window-mode and area-mode capture are code-complete but exercised less
  than display mode in live testing.
- No Windows/Linux support; macOS 14+ only.

## License

MIT — see [LICENSE](LICENSE). No accounts, no telemetry, no network calls.
