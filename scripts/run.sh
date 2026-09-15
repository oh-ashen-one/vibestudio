#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
"$(dirname "$0")/build.sh"
open "$(pwd)/.build/Build/Products/Debug/VibeStudio.app"
