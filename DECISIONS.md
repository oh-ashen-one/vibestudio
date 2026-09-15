# Decisions log

Every tuneable constant and visual-quality decision lands here with its reason.

| Date | Decision | Value | Why |
|---|---|---|---|
| 2026-09-14 | Stack | Native Swift + SwiftUI, no SPM deps | Master prompt §2: ScreenCaptureKit + Metal + VideoToolbox quality, headless xcodebuild |
| 2026-09-14 | Deployment target | macOS 14.0 | Master prompt §0/§2 |
| 2026-09-14 | Signing | Ad-hoc (`CODE_SIGN_IDENTITY = "-"`), no sandbox | Local-only distribution, zero cost, zero accounts; TCC re-prompt per rebuild is documented in README |
| 2026-09-14 | Project format | objectVersion 77, file-system-synchronized groups | Agents add Swift files without touching project.pbxproj |
