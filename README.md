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

## Roadmap

- [x] Phase 0 — project scaffold, headless build + tests
- [ ] Phase 1 — recorder: floating pill (display/window/area source, camera,
      mic, settings), ScreenCaptureKit capture, cursor/click/keystroke events
- [ ] Phase 2 — project model + player
- [ ] Phase 3 — auto-zoom, smooth cursor, styled frame, camera layouts
- [ ] Phase 4 — export (MP4, aspect-ratio re-targeting)
- [ ] Phase 5 — polish (click ripples, keystroke badges, GIF, presets)

## License

MIT — see [LICENSE](LICENSE). No accounts, no telemetry, no network calls.
