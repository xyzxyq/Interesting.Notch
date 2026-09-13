#!/usr/bin/env bash
set -euo pipefail

# Build and verify the standard Finder drag-to-Applications installer volume.
# Usage: ./scripts/package-release-dmg.sh <signed.app> <output.dmg> <volume-name>

APP_PATH="${1:?Signed app path required}"
DMG_OUTPUT="${2:?DMG output path required}"
VOLUME_NAME="${3:?Volume name required}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DMG_BUILDER="$ROOT_DIR/Configuration/dmg/create_dmg.sh"
APP_NAME="$(basename "$APP_PATH")"
MOUNT_POINT=""

die() {
  echo "Error: $*" >&2
  exit 1
}

detach_volume() {
  if [ -n "$MOUNT_POINT" ] && [ -d "$MOUNT_POINT" ]; then
    hdiutil detach "$MOUNT_POINT" -quiet || true
  fi
}

require_standard_installer_layout() {
  local item name app_found=0 applications_found=0

  while IFS= read -r -d '' item; do
    name="$(basename "$item")"
    case "$name" in
      "$APP_NAME")
        [ -d "$item" ] || die "Installer app is not a bundle: $item"
        app_found=1
        ;;
      Applications)
        [ -L "$item" ] || die "Applications is not a symbolic link"
        [ "$(readlink "$item")" = "/Applications" ] || die "Applications link must target /Applications"
        applications_found=1
        ;;
      *)
        die "Unexpected visible installer item: $name"
        ;;
    esac
  done < <(find "$MOUNT_POINT" -mindepth 1 -maxdepth 1 ! -name '.*' -print0)

  [ "$app_found" -eq 1 ] || die "Installer app is missing: $APP_NAME"
  [ "$applications_found" -eq 1 ] || die "Applications link is missing"
}

[ -x "$DMG_BUILDER" ] || die "DMG builder is not executable: $DMG_BUILDER"
[ -d "$APP_PATH" ] || die "App bundle not found: $APP_PATH"
[ -f "$APP_PATH/Contents/Info.plist" ] || die "App Info.plist is missing: $APP_PATH"
[ ! -e "$DMG_OUTPUT" ] || die "Refusing to overwrite existing DMG: $DMG_OUTPUT"

codesign --verify --deep --strict "$APP_PATH"
"$DMG_BUILDER" "$APP_PATH" "$DMG_OUTPUT" "$VOLUME_NAME"
hdiutil verify "$DMG_OUTPUT"

trap detach_volume EXIT
MOUNT_POINT="$(hdiutil attach -readonly -nobrowse "$DMG_OUTPUT" | awk -F '\t' '$NF ~ /^\/Volumes\// { print $NF; exit }')"
[ -n "$MOUNT_POINT" ] && [ -d "$MOUNT_POINT" ] || die "Unable to mount generated DMG"

require_standard_installer_layout
codesign --verify --deep --strict "$MOUNT_POINT/$APP_NAME"
echo "Validated drag-to-Applications DMG: $DMG_OUTPUT"
