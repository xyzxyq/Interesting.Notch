#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
CONFIGURATION=Debug
if [ "$MODE" = "--release" ]; then CONFIGURATION=Release; fi
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$ROOT_DIR/build/DerivedData"
BUILT_APP="$DERIVED_DATA/Build/Products/$CONFIGURATION/Interesting Notch.app"
APP_BUNDLE="$HOME/Applications/InterestingNotch $CONFIGURATION.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/Interesting Notch"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# Stop every copy of the main app, including /Applications and other debug paths.
# Remember only media children owned by these instances before forced termination.
MEDIA_CHILDREN=""
for parent in $(pgrep -x 'Interesting Notch' || true); do
  for child in $(pgrep -P "$parent" || true); do
    case "$(ps -p "$child" -o command=)" in
      *'/Contents/Resources/mediaremote-adapter.pl '*'/MediaRemoteAdapter.framework stream')
        MEDIA_CHILDREN+=" $child" ;;
    esac
  done
done
pkill -TERM -x 'Interesting Notch' || true
for _ in {1..50}; do
  pgrep -x 'Interesting Notch' >/dev/null || break
  sleep 0.1
done
pkill -KILL -x 'Interesting Notch' || true
for _ in {1..20}; do
  pgrep -x 'Interesting Notch' >/dev/null || break
  sleep 0.05
done
if pgrep -x 'Interesting Notch' >/dev/null; then
  echo 'Existing application did not exit; refusing to launch a second copy.' >&2
  exit 1
fi

# SIGKILL skips app teardown; do not leave its event-stream children behind.
for child in $MEDIA_CHILDREN; do
  case "$(ps -p "$child" -o command=)" in
    *'/Contents/Resources/mediaremote-adapter.pl '*'/MediaRemoteAdapter.framework stream')
      kill -TERM "$child" 2>/dev/null || true ;;
  esac
done

cd "$ROOT_DIR"
xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA" CODE_SIGNING_ALLOWED=NO build
# Sign on the local volume: external disks recreate AppleDouble files during signing.
mkdir -p "$(dirname "$APP_BUNDLE")"
if [ -d "$APP_BUNDLE" ]; then
  mv "$APP_BUNDLE" "${APP_BUNDLE%.app}.backup-$(date +%Y%m%d-%H%M%S).app"
fi
rsync -a --exclude='._*' "$BUILT_APP/" "$APP_BUNDLE/"
mkdir -p "$APP_BUNDLE/Contents/Resources/Licenses/LICENSES"
cp LICENSE THIRD_PARTY_LICENSES THIRD_PARTY_NOTICES.md "$APP_BUNDLE/Contents/Resources/Licenses/"
cp LICENSES/MPL-2.0.txt "$APP_BUNDLE/Contents/Resources/Licenses/LICENSES/"
python3 scripts/sign-development.py "$APP_BUNDLE"

case "$MODE" in
  run|--release)
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
    [ "$(pgrep -x 'Interesting Notch' | wc -l | tr -d ' ')" = 1 ]
    ;;
  *)
    echo "usage: $0 [run|--release|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
