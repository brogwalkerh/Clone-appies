#!/usr/bin/env bash
# make-dmg.sh — build a compressed, read-only DMG containing an .app and an
# /Applications symlink. macOS only (uses hdiutil).
#
# Usage:
#   Scripts/make-dmg.sh <path/to/App.app> <output.dmg> [--volume-name NAME]
#
# The DMG is created from a staging folder so the source .app is never modified.
# Sign and notarize the resulting DMG separately (see notarize.sh).
set -euo pipefail

usage() {
  cat <<USAGE
Usage: $(basename "$0") <path/to/App.app> <output.dmg> [--volume-name NAME]

Creates a compressed (UDZO) read-only DMG containing the app bundle and a
symlink to /Applications. Requires macOS (hdiutil).

Options:
  --volume-name NAME   Mounted volume name (default: app name without .app)
  -h, --help           Show this help
USAGE
}

if [[ $# -lt 2 ]]; then
  usage >&2
  exit 2
fi

APP_PATH=""
OUT_PATH=""
VOLUME_NAME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --volume-name) VOLUME_NAME="${2:?--volume-name needs a value}"; shift 2 ;;
    --volume-name=*) VOLUME_NAME="${1#*=}"; shift ;;
    -*) echo "error: unknown option $1" >&2; usage >&2; exit 2 ;;
    *)
      if [[ -z "$APP_PATH" ]]; then APP_PATH="$1"
      elif [[ -z "$OUT_PATH" ]]; then OUT_PATH="$1"
      else echo "error: unexpected argument $1" >&2; usage >&2; exit 2
      fi
      shift ;;
  esac
done

if [[ -z "$APP_PATH" || -z "$OUT_PATH" ]]; then
  usage >&2
  exit 2
fi

if ! command -v hdiutil >/dev/null 2>&1; then
  echo "error: hdiutil not found; this script must run on macOS" >&2
  exit 1
fi

if [[ ! -d "$APP_PATH" || "${APP_PATH##*.}" != "app" ]]; then
  echo "error: '$APP_PATH' is not an .app bundle directory" >&2
  exit 1
fi

APP_NAME="$(basename "$APP_PATH" .app)"
VOLUME_NAME="${VOLUME_NAME:-$APP_NAME}"
OUT_DIR="$(cd "$(dirname "$OUT_PATH")" 2>/dev/null && pwd || true)"
if [[ -z "$OUT_DIR" ]]; then
  mkdir -p "$(dirname "$OUT_PATH")"
  OUT_DIR="$(cd "$(dirname "$OUT_PATH")" && pwd)"
fi
OUT_PATH="$OUT_DIR/$(basename "$OUT_PATH")"

STAGING="$(mktemp -d -t "${APP_NAME}-dmg")"
cleanup() { rm -rf "$STAGING"; }
trap cleanup EXIT

echo "==> Staging $APP_NAME.app"
# ditto preserves resource forks, extended attributes and code signatures.
ditto "$APP_PATH" "$STAGING/$APP_NAME.app"
ln -s /Applications "$STAGING/Applications"

# Remove any stale output so hdiutil does not refuse to overwrite.
rm -f "$OUT_PATH"

echo "==> Creating DMG at $OUT_PATH (volume '$VOLUME_NAME')"
hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING" \
  -fs APFS \
  -format UDZO \
  -imagekey zlib-level=9 \
  -ov \
  "$OUT_PATH" >/dev/null

echo "==> Verifying"
hdiutil verify "$OUT_PATH" >/dev/null

SIZE="$(du -h "$OUT_PATH" | cut -f1 | tr -d ' ')"
echo "==> Done: $OUT_PATH ($SIZE)"
echo "Next: codesign --sign 'Developer ID Application' --timestamp '$OUT_PATH'"
echo "      Scripts/notarize.sh '$OUT_PATH' <keychain-profile>"
