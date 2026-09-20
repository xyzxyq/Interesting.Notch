#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="${1:-$ROOT/build/CodexBridge/codex-notch-bridge}"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
mkdir -p "$(dirname "$OUTPUT")"
xcrun swiftc -swift-version 5 -O -whole-module-optimization \
  -target "$(uname -m)-apple-macosx14.0" \
  "$ROOT/CodexBridge/Projection.swift" "$ROOT/CodexBridge/Transport.swift" \
  "$ROOT/CodexBridge/Bridge.swift" "$ROOT/CodexBridge/main.swift" -o "$OUTPUT"
codesign --force --sign - "$OUTPUT"
codesign --verify --strict "$OUTPUT"
echo "Built native Codex bridge: $OUTPUT"
