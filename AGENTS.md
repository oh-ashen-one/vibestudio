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

- `VibeStudio/VibeStudioApp.swift` — app entry point.
- Capture: ScreenCaptureKit (`SCStream`), retina scale, 60 fps.
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
