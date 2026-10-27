#!/usr/bin/env bash
# notarize.sh — submit a .zip/.dmg/.pkg to Apple notary service, wait for the
# verdict, and staple the ticket. macOS only (uses xcrun notarytool / stapler).
#
# Usage:
#   Scripts/notarize.sh <file.zip|file.dmg|file.pkg> <keychain-profile> \
#       [--staple PATH] [--keychain PATH] [--timeout DURATION]
#
# The keychain profile is created once with:
#   xcrun notarytool store-credentials <profile> --key AuthKey.p8 \
#       --key-id <KEY_ID> --issuer <ISSUER_ID>
#
# A .zip cannot be stapled, so when submitting a zipped .app pass
# `--staple path/to/App.app` to staple the bundle the zip was made from.
set -euo pipefail

usage() {
  cat <<USAGE
Usage: $(basename "$0") <file.zip|file.dmg|file.pkg> <keychain-profile> [options]

Submits the file with 'xcrun notarytool submit --wait', prints the log on
failure, then staples the notarization ticket.

Options:
  --staple PATH       What to staple (default: the submitted file). Required
                      when submitting a .zip, which cannot be stapled itself.
  --keychain PATH     Keychain holding the notarytool profile (CI keychains).
  --timeout DURATION  notarytool wait timeout, e.g. 30m (default: 45m).
  -h, --help          Show this help
USAGE
}

if [[ $# -lt 2 ]]; then
  usage >&2
  exit 2
fi

SUBMIT_PATH=""
PROFILE=""
STAPLE_PATH=""
KEYCHAIN=""
TIMEOUT="45m"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --staple) STAPLE_PATH="${2:?--staple needs a path}"; shift 2 ;;
    --staple=*) STAPLE_PATH="${1#*=}"; shift ;;
    --keychain) KEYCHAIN="${2:?--keychain needs a path}"; shift 2 ;;
    --keychain=*) KEYCHAIN="${1#*=}"; shift ;;
    --timeout) TIMEOUT="${2:?--timeout needs a value}"; shift 2 ;;
    --timeout=*) TIMEOUT="${1#*=}"; shift ;;
    -*) echo "error: unknown option $1" >&2; usage >&2; exit 2 ;;
    *)
      if [[ -z "$SUBMIT_PATH" ]]; then SUBMIT_PATH="$1"
      elif [[ -z "$PROFILE" ]]; then PROFILE="$1"
      else echo "error: unexpected argument $1" >&2; usage >&2; exit 2
      fi
      shift ;;
  esac
done

if [[ -z "$SUBMIT_PATH" || -z "$PROFILE" ]]; then
  usage >&2
  exit 2
fi

if ! command -v xcrun >/dev/null 2>&1; then
  echo "error: xcrun not found; this script must run on macOS with Xcode" >&2
  exit 1
fi

if [[ ! -e "$SUBMIT_PATH" ]]; then
  echo "error: '$SUBMIT_PATH' does not exist" >&2
  exit 1
fi

case "${SUBMIT_PATH##*.}" in
  zip|dmg|pkg) ;;
  *) echo "error: notarytool accepts .zip, .dmg or .pkg (got '$SUBMIT_PATH')" >&2; exit 1 ;;
esac

if [[ -z "$STAPLE_PATH" ]]; then
  if [[ "${SUBMIT_PATH##*.}" == "zip" ]]; then
    echo "error: a .zip cannot be stapled; pass --staple path/to/App.app" >&2
    exit 1
  fi
  STAPLE_PATH="$SUBMIT_PATH"
fi

KEYCHAIN_ARGS=()
if [[ -n "$KEYCHAIN" ]]; then
  KEYCHAIN_ARGS=(--keychain "$KEYCHAIN")
fi

echo "==> Submitting $(basename "$SUBMIT_PATH") for notarization (profile: $PROFILE)"
SUBMIT_JSON="$(mktemp -t notarize-submit)"
trap 'rm -f "$SUBMIT_JSON"' EXIT

# --wait blocks until Apple returns Accepted / Invalid / Rejected.
set +e
xcrun notarytool submit "$SUBMIT_PATH" \
  --keychain-profile "$PROFILE" "${KEYCHAIN_ARGS[@]}" \
  --wait --timeout "$TIMEOUT" \
  --output-format json > "$SUBMIT_JSON"
SUBMIT_RC=$?
set -e

cat "$SUBMIT_JSON"
SUBMISSION_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id",""))' "$SUBMIT_JSON" 2>/dev/null || true)"
STATUS="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status",""))' "$SUBMIT_JSON" 2>/dev/null || true)"

if [[ -n "$SUBMISSION_ID" ]]; then
  echo "==> Notarization log for $SUBMISSION_ID"
  xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$PROFILE" "${KEYCHAIN_ARGS[@]}" || true
fi

if [[ $SUBMIT_RC -ne 0 || "$STATUS" != "Accepted" ]]; then
  echo "error: notarization failed (status: ${STATUS:-unknown}, exit: $SUBMIT_RC)" >&2
  exit 1
fi

echo "==> Stapling $STAPLE_PATH"
xcrun stapler staple "$STAPLE_PATH"
xcrun stapler validate "$STAPLE_PATH"

echo "==> Notarized and stapled: $STAPLE_PATH"
