#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild -project VibeStudio.xcodeproj -scheme VibeStudio -configuration Debug -derivedDataPath .build test
