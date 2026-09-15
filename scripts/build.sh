#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild -project VibeStudio.xcodeproj -scheme VibeStudio -configuration Debug -derivedDataPath .build build | grep -E "(error|warning: .*never|BUILD)" || true
echo "Built: $(pwd)/.build/Build/Products/Debug/VibeStudio.app"
