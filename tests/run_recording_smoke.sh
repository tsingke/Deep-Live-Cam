#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="/tmp/LiveFaceRecordingSmokeBin"
xcrun swiftc \
  -swift-version 5 -O \
  -target arm64-apple-macosx14.0 \
  -sdk "$(xcrun --show-sdk-path)" \
  -framework AppKit -framework AVFoundation -framework AudioToolbox \
  -framework CoreVideo -framework CoreMedia -framework ImageIO \
  -framework UniformTypeIdentifiers -framework QuartzCore \
  "$ROOT/native/Models.swift" \
  "$ROOT/native/MediaCapture.swift" \
  "$ROOT/native/AudioCapture.swift" \
  "$ROOT/tests/recording_smoke/main.swift" \
  -o "$BIN"
"$BIN"
