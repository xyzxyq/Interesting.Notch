#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$ROOT_DIR/build/DerivedData"
BUILT_APP="$DERIVED_DATA/Build/Products/Debug/Interesting Notch.app"
APP_BUNDLE="$HOME/Applications/InterestingNotch Debug.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/Interesting Notch"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

for APP_PID in $(pgrep -f "$APP_BINARY" || true); do
  if [ "$(ps -p "$APP_PID" -o command=)" = "$APP_BINARY" ]; then
    kill -KILL "$APP_PID" || true
  fi
done

cd "$ROOT_DIR"
xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration Debug \
  -derivedDataPath "$DERIVED_DATA" CODE_SIGNING_ALLOWED=NO build
# Sign on the local volume: external disks recreate AppleDouble files during signing.
mkdir -p "$(dirname "$APP_BUNDLE")"
if [ -d "$APP_BUNDLE" ]; then
  mv "$APP_BUNDLE" "${APP_BUNDLE%.app}.backup-$(date +%Y%m%d-%H%M%S).app"
fi
rsync -a --exclude='._*' "$BUILT_APP/" "$APP_BUNDLE/"
python3 scripts/sign-development.py "$APP_BUNDLE"

case "$MODE" in
  run)
    /usr/bin/open -n "$APP_BUNDLE"
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs|--telemetry|telemetry)
    /usr/bin/open -n "$APP_BUNDLE"
    /usr/bin/log stream --info --style compact --predicate 'process == "Interesting Notch"'
    ;;
  --verify|verify)
    /usr/bin/open -n "$APP_BUNDLE"
    sleep 1
    pgrep -f "$APP_BINARY" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
