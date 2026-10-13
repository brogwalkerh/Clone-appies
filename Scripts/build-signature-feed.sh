#!/usr/bin/env bash
# build-signature-feed.sh — turn the official ClamAV databases into the small,
# Mac-focused plain-text signature feed the app consumes (see ADR 0006 and
# ProtectionModule.SignatureUpdater).
#
# Usage:
#   Scripts/build-signature-feed.sh --cvd-dir DIR --out DIR [--version YYYY-MM-DD] [--keep-unpacked]
#   Scripts/build-signature-feed.sh --from-unpacked DIR --out DIR [--version YYYY-MM-DD]
#
# The normal path needs ClamAV's `sigtool` (brew install clamav) and a directory
# holding `.cvd`/`.cld` files downloaded with `freshclam` (main.cvd, daily.cvd,
# bytecode.cvd is ignored). `sigtool --unpack` expands them into a temporary
# directory; `--from-unpacked` skips that step and reads an already unpacked
# directory instead (what the Linux tests use).
#
# Output (<out>/):
#   mac.hdb, mac.hsb, mac.ndb   hash and body-pattern signatures whose names look
#                               Mac-relevant (see MAC_NAME_REGEX)
#   allow.ign2                  every ignore-list entry, unchanged
#   README.md                   ClamAV attribution (the data is GPL-2.0)
#   manifest.json               {"version": "YYYY-MM-DD", "files": [{name, sha256, bytes}]}
set -euo pipefail

MAC_NAME_REGEX='OSX|MacOS|Osx|Mac|Shlayer|Adload|Bundlore|Pirrit|XLoader|Atomic|Silver|Eicar'

usage() {
  cat <<USAGE
Usage: $(basename "$0") (--cvd-dir DIR | --from-unpacked DIR) --out DIR [options]

Builds the Mac-focused ClamAV text signature feed.

Required (one of):
  --cvd-dir DIR         Directory with freshclam-downloaded .cvd/.cld files;
                        unpacked with \`sigtool --unpack\` (brew install clamav)
  --from-unpacked DIR   Directory that already holds unpacked .hdb/.hsb/.ndb/.ign2
                        files; skips sigtool entirely

Required:
  --out DIR             Where to write the feed (created if missing)

Options:
  --version YYYY-MM-DD  Feed version written to manifest.json (default: today, UTC)
  --keep-unpacked       Do not delete the temporary unpack directory
  -h, --help            Show this help
USAGE
}

CVD_DIR=""
UNPACKED_DIR=""
OUT_DIR=""
VERSION=""
KEEP_UNPACKED=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --cvd-dir) [[ $# -ge 2 ]] || { echo "error: --cvd-dir needs a value" >&2; exit 2; }; CVD_DIR="$2"; shift 2 ;;
    --from-unpacked) [[ $# -ge 2 ]] || { echo "error: --from-unpacked needs a value" >&2; exit 2; }; UNPACKED_DIR="$2"; shift 2 ;;
    --out) [[ $# -ge 2 ]] || { echo "error: --out needs a value" >&2; exit 2; }; OUT_DIR="$2"; shift 2 ;;
    --version) [[ $# -ge 2 ]] || { echo "error: --version needs a value" >&2; exit 2; }; VERSION="$2"; shift 2 ;;
    --keep-unpacked) KEEP_UNPACKED=1; shift ;;
    *) echo "error: unknown argument $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$OUT_DIR" ]]; then
  echo "error: --out is required" >&2; usage >&2; exit 2
fi
if [[ -n "$CVD_DIR" && -n "$UNPACKED_DIR" ]]; then
  echo "error: pass either --cvd-dir or --from-unpacked, not both" >&2; exit 2
fi
if [[ -z "$CVD_DIR" && -z "$UNPACKED_DIR" ]]; then
  echo "error: one of --cvd-dir or --from-unpacked is required" >&2; usage >&2; exit 2
fi
if [[ -z "$VERSION" ]]; then
  VERSION="$(date -u +%Y-%m-%d)"
fi
if ! [[ "$VERSION" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  echo "error: --version must look like YYYY-MM-DD (got '$VERSION')" >&2; exit 2
fi

# --- helpers -----------------------------------------------------------------
sha256_of() {
  # Portable SHA-256 hex digest of a file.
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    echo "error: neither shasum nor sha256sum is available" >&2; exit 1
  fi
}

size_of() {
  # Portable file size in bytes.
  if stat -f %z "$1" >/dev/null 2>&1; then stat -f %z "$1"; else stat -c %s "$1"; fi
}

TMP_UNPACK=""
cleanup() {
  if [[ -n "$TMP_UNPACK" && $KEEP_UNPACKED -eq 0 ]]; then rm -rf "$TMP_UNPACK"; fi
}
trap cleanup EXIT

# --- 1. unpack ------------------------------------------------------------------
if [[ -n "$CVD_DIR" ]]; then
  if ! command -v sigtool >/dev/null 2>&1; then
    echo "error: sigtool not found. Install ClamAV (brew install clamav) and run freshclam first." >&2
    exit 1
  fi
  if [[ ! -d "$CVD_DIR" ]]; then
    echo "error: '$CVD_DIR' is not a directory" >&2; exit 1
  fi
  shopt -s nullglob
  CVD_FILES=("$CVD_DIR"/main.cvd "$CVD_DIR"/main.cld "$CVD_DIR"/daily.cvd "$CVD_DIR"/daily.cld)
  shopt -u nullglob
  if [[ ${#CVD_FILES[@]} -eq 0 ]]; then
    echo "error: no main/daily .cvd or .cld files in '$CVD_DIR' (run freshclam)" >&2; exit 1
  fi
  TMP_UNPACK="$(mktemp -d "${TMPDIR:-/tmp}/clamav-unpack.XXXXXX")"
  echo "==> Unpacking ${#CVD_FILES[@]} database(s) into $TMP_UNPACK"
  for cvd in "${CVD_FILES[@]}"; do
    abs="$(cd "$(dirname "$cvd")" && pwd)/$(basename "$cvd")"
    echo "    sigtool --unpack $(basename "$cvd")"
    (cd "$TMP_UNPACK" && sigtool --unpack "$abs" >/dev/null)
  done
  UNPACKED_DIR="$TMP_UNPACK"
fi

if [[ ! -d "$UNPACKED_DIR" ]]; then
  echo "error: unpacked directory '$UNPACKED_DIR' does not exist" >&2; exit 1
fi

mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

# --- 2. filter ------------------------------------------------------------------
# collect <ext> <out-name> <name-field>
#   Concatenates every *.<ext> file in the unpacked dir and keeps the lines whose
#   signature name (field <name-field>, ':'-separated) matches MAC_NAME_REGEX.
#   Comments and blank lines are dropped; output is sorted and de-duplicated.
collect() {
  local ext="$1" out="$2" field="$3"
  local target="$OUT_DIR/$out"
  : > "$target"
  shopt -s nullglob
  local files=("$UNPACKED_DIR"/*."$ext")
  shopt -u nullglob
  if [[ ${#files[@]} -gt 0 ]]; then
    cat "${files[@]}" \
      | grep -v -E '^\s*(#|$)' \
      | awk -F: -v field="$field" -v re="$MAC_NAME_REGEX" '$field ~ re' \
      | LC_ALL=C sort -u > "$target" || true
  fi
  printf '    %-12s %7d lines from %d file(s)\n' "$out" "$(wc -l < "$target" | tr -d ' ')" "${#files[@]}"
}

echo "==> Filtering signatures for Mac-relevant names"
collect hdb mac.hdb 3     # md5:size:name
collect hsb mac.hsb 3     # sha256:size:name
collect ndb mac.ndb 1     # name:target:offset:hexpattern

# Allow-list: every entry, unchanged (they are names to ignore, not Mac-specific).
: > "$OUT_DIR/allow.ign2"
shopt -s nullglob
IGN_FILES=("$UNPACKED_DIR"/*.ign2)
shopt -u nullglob
if [[ ${#IGN_FILES[@]} -gt 0 ]]; then
  cat "${IGN_FILES[@]}" | grep -v -E '^\s*(#|$)' | LC_ALL=C sort -u > "$OUT_DIR/allow.ign2" || true
fi
printf '    %-12s %7d lines from %d file(s)\n' allow.ign2 "$(wc -l < "$OUT_DIR/allow.ign2" | tr -d ' ')" "${#IGN_FILES[@]}"

# --- 3. README --------------------------------------------------------------------
cat > "$OUT_DIR/README.md" <<README
# Mac Cleaner signature feed — $VERSION

This directory is a filtered, plain-text subset of the ClamAV virus databases
(\`main\` and \`daily\`), produced by \`Scripts/build-signature-feed.sh\`.

## Files

| File         | Format | Contents |
|--------------|--------|----------|
| \`mac.hdb\`    | ClamAV \`.hdb\` (\`md5:size:name\`) | MD5 hash signatures whose names look Mac-relevant |
| \`mac.hsb\`    | ClamAV \`.hsb\` (\`sha256:size:name\`) | SHA-256 hash signatures whose names look Mac-relevant |
| \`mac.ndb\`    | ClamAV \`.ndb\` (\`name:target:offset:hexpattern\`) | Body patterns whose names look Mac-relevant |
| \`allow.ign2\` | ClamAV \`.ign2\` | Signature names to ignore (false-positive allow-list) |
| \`manifest.json\` | JSON | Feed version plus SHA-256 and size of every file above |

"Mac-relevant" means the signature name matches \`$MAC_NAME_REGEX\`.

## Attribution and license

The signature data in this directory is derived from the ClamAV virus
databases, Copyright (C) Cisco Systems, Inc. and/or its affiliates, and the
ClamAV community (https://www.clamav.net/). The ClamAV databases are
distributed under the GNU General Public License, version 2 (GPL-2.0); this
redistributed subset remains under that license. The full license text is
available at https://www.gnu.org/licenses/old-licenses/gpl-2.0.html.

The Mac Cleaner application code that reads these files is separate from and
not derived from ClamAV; it is licensed under the terms in the repository's
LICENSE file. The EICAR test signature (\`Eicar-Test-Signature\`) is the
industry-standard harmless test file published by EICAR (https://www.eicar.org/).
README

# --- 4. manifest ------------------------------------------------------------------
echo "==> Writing manifest.json (version $VERSION)"
{
  printf '{\n  "version": "%s",\n  "files": [\n' "$VERSION"
  first=1
  for name in mac.hdb mac.hsb mac.ndb allow.ign2 README.md; do
    path="$OUT_DIR/$name"
    sum="$(sha256_of "$path")"
    bytes="$(size_of "$path")"
    if [[ $first -eq 1 ]]; then first=0; else printf ',\n'; fi
    printf '    { "name": "%s", "sha256": "%s", "bytes": %s }' "$name" "$sum" "$bytes"
  done
  printf '\n  ]\n}\n'
} > "$OUT_DIR/manifest.json"

echo
echo "==> Feed written to $OUT_DIR"
for name in mac.hdb mac.hsb mac.ndb allow.ign2 README.md manifest.json; do
  printf '  %-14s %9s bytes\n' "$name" "$(size_of "$OUT_DIR/$name")"
done
