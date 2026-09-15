#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Stable identity when available: with the "VibeStudio Dev" self-signed cert
# (scripts/create_dev_cert.sh) permission grants survive rebuilds; otherwise
# fall back to ad-hoc ("-"), which requires re-granting after each build.
SIGN_ARGS=(CODE_SIGN_IDENTITY=-)
if security find-identity -p codesigning | grep -q "VibeStudio Dev"; then
  # Manual style + empty team: self-signed cert needs no development team
  # or provisioning profile; ad-hoc "-" stays the repo default otherwise.
  SIGN_ARGS=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="VibeStudio Dev" DEVELOPMENT_TEAM="" PROVISIONING_PROFILE_SPECIFIER="")
fi

xcodebuild -project VibeStudio.xcodeproj -scheme VibeStudio -configuration Debug -derivedDataPath .build "${SIGN_ARGS[@]}" build | grep -E "(error|warning: .*never|BUILD)" || true
echo "Built: $(pwd)/.build/Build/Products/Debug/VibeStudio.app"
