#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
DEMO_DIR="$(mktemp -d /tmp/interestingnotch-demos.XXXXXX)"
# Export only the artwork; never initialize or mutate the system cursor registry.
sed '/^struct PointerImage/,$d' boringNotch/managers/PaperPlanePointer.swift > "$DEMO_DIR/PointerArtwork.swift"
xcrun swiftc -swift-version 5 -D EDGE_CHECKS \
  boringNotch/components/Notch/NotchShape.swift \
  boringNotch/components/Notch/MusicEdgeEffect.swift \
  boringNotch/components/Notch/CodexNotchEffect.swift \
  boringNotch/managers/CodexActivity.swift \
  "$DEMO_DIR/PointerArtwork.swift" \
  scripts/RenderReadmeDemos.swift -o "$DEMO_DIR/render"
"$DEMO_DIR/render"
