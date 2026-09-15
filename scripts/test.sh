#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Same identity as build.sh so the tested app keeps the stable signature.
SIGN_ARGS=(CODE_SIGN_IDENTITY=-)
if security find-identity -p codesigning | grep -q "VibeStudio Dev"; then
  # Manual style + empty team: self-signed cert needs no development team
  # or provisioning profile; ad-hoc "-" stays the repo default otherwise.
  SIGN_ARGS=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="VibeStudio Dev" DEVELOPMENT_TEAM="" PROVISIONING_PROFILE_SPECIFIER="")
fi

xcodebuild -project VibeStudio.xcodeproj -scheme VibeStudio -configuration Debug -derivedDataPath .build "${SIGN_ARGS[@]}" test
