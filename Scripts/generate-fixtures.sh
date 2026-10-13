#!/usr/bin/env bash
# generate-fixtures.sh — build a fake home directory full of realistic junk for
# scanner tests and manual QA. Works on Linux and macOS.
#
# Usage:
#   Scripts/generate-fixtures.sh <target-dir> [--seed N] [--force]
#
# Creates <target-dir> (must be empty or absent unless --force) with:
#   Library/Caches/com.example.*/          app caches of various sizes
#   Library/Logs/*.log                     logs, some old
#   Library/Developer/Xcode/DerivedData/   fake Xcode build products
#   Library/Caches/Homebrew/               brew download cache
#   .Trash/                                trashed files
#   Downloads/                             a .download bundle, an old .dmg, misc
#   .ollama/models/                        fake LLM model blobs
#   .cache/huggingface/                    fake HF hub cache
#   Documents/, Desktop/                   a few real-looking user files (must NOT be flagged)
# File contents are random bytes (so hashing/dedupe code sees distinct data);
# sizes are deterministic. Old files get mtimes in the past via `touch -t`.
set -euo pipefail

usage() {
  cat <<USAGE
Usage: $(basename "$0") <target-dir> [--force]

Creates a fake home directory tree with realistic junk for scanner tests.

Options:
  --force      Allow writing into a non-empty target directory
  -h, --help   Show this help
USAGE
}

TARGET=""
FORCE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --force) FORCE=1; shift ;;
    -*) echo "error: unknown option $1" >&2; usage >&2; exit 2 ;;
    *)
      if [[ -n "$TARGET" ]]; then echo "error: unexpected argument $1" >&2; usage >&2; exit 2; fi
      TARGET="$1"; shift ;;
  esac
done

if [[ -z "$TARGET" ]]; then
  usage >&2
  exit 2
fi

case "$TARGET" in
  /|/home|/Users|"$HOME"|/System|/usr|/bin|/sbin|/etc|/var)
    echo "error: refusing to write fixtures into '$TARGET'" >&2; exit 1 ;;
esac

if [[ -d "$TARGET" && -n "$(ls -A "$TARGET" 2>/dev/null)" && $FORCE -ne 1 ]]; then
  echo "error: '$TARGET' is not empty (use --force to write anyway)" >&2
  exit 1
fi

mkdir -p "$TARGET"
TARGET="$(cd "$TARGET" && pwd)"

# --- helpers -----------------------------------------------------------------
FILE_COUNT=0
TOTAL_BYTES=0

# mkfile <path> <size> [age-days]
#   size accepts bytes or a K/M suffix (e.g. 512K, 20M).
mkfile() {
  local path="$1" size="$2" age="${3:-0}"
  local bytes
  case "$size" in
    *K) bytes=$(( ${size%K} * 1024 )) ;;
    *M) bytes=$(( ${size%M} * 1024 * 1024 )) ;;
    *)  bytes="$size" ;;
  esac
  mkdir -p "$(dirname "$path")"
  if (( bytes >= 1048576 )); then
    # Large files: dd in 1 MiB blocks (fast, works on both Linux and macOS).
    dd if=/dev/urandom of="$path" bs=1048576 count=$(( bytes / 1048576 )) status=none 2>/dev/null \
      || dd if=/dev/urandom of="$path" bs=1048576 count=$(( bytes / 1048576 )) 2>/dev/null
    local rem=$(( bytes % 1048576 ))
    if (( rem > 0 )); then head -c "$rem" /dev/urandom >> "$path"; fi
  elif (( bytes > 0 )); then
    head -c "$bytes" /dev/urandom > "$path"
  else
    : > "$path"
  fi
  if (( age > 0 )); then age_file "$path" "$age"; fi
  FILE_COUNT=$(( FILE_COUNT + 1 ))
  TOTAL_BYTES=$(( TOTAL_BYTES + bytes ))
}

# mktext <path> <text> [age-days]
mktext() {
  local path="$1" text="$2" age="${3:-0}"
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$text" > "$path"
  if (( age > 0 )); then age_file "$path" "$age"; fi
  FILE_COUNT=$(( FILE_COUNT + 1 ))
  TOTAL_BYTES=$(( TOTAL_BYTES + ${#text} + 1 ))
}

# age_file <path> <days>  — set mtime N days in the past (portable touch -t).
age_file() {
  local path="$1" days="$2" stamp
  if stamp="$(date -d "-${days} days" +%Y%m%d%H%M 2>/dev/null)"; then :; else
    stamp="$(date -v "-${days}d" +%Y%m%d%H%M)"   # BSD/macOS date
  fi
  touch -t "$stamp" "$path"
}

human() {
  local b="$1"
  if (( b >= 1073741824 )); then printf '%.1f GB' "$(echo "$b / 1073741824" | bc -l 2>/dev/null || awk "BEGIN{print $b/1073741824}")"
  elif (( b >= 1048576 )); then awk "BEGIN{printf \"%.1f MB\", $b/1048576}"
  elif (( b >= 1024 )); then awk "BEGIN{printf \"%.1f KB\", $b/1024}"
  else printf '%d B' "$b"; fi
}

echo "==> Generating fixtures in $TARGET"
cd "$TARGET"

# --- Library/Caches: app caches ------------------------------------------------
for app in com.example.photoeditor com.example.chat com.example.browser com.example.musicplayer; do
  mkfile "Library/Caches/$app/Cache.db" 2M
  mkfile "Library/Caches/$app/Cache.db-wal" 256K
  mkfile "Library/Caches/$app/fsCachedData/$(printf '%08X' $RANDOM)" 1M 3
  mkfile "Library/Caches/$app/fsCachedData/$(printf '%08X' $RANDOM)" 768K 40
done
mkfile "Library/Caches/com.example.browser/WebKitCache/blob-$(printf '%04X' $RANDOM)" 12M 2
mkfile "Library/Caches/com.apple.dt.Xcode/Downloads/stub.bin" 4M 90
mkfile "Library/Caches/pip/http/v/1/9/blob" 3M 120
mkfile "Library/Caches/Homebrew/downloads/abc123--wget-1.24.5.arm64_sequoia.bottle.tar.gz" 5M 60
mkfile "Library/Caches/Homebrew/downloads/def456--node-22.9.0.arm64_sequoia.bottle.tar.gz" 20M 10
mkfile "Library/Caches/Homebrew/Cask/visual-studio-code--1.93.1.zip" 30M 200
mkdir -p "Library/Caches/com.example.empty"   # empty cache dir, should not count as junk bytes

# --- Library/Logs ---------------------------------------------------------------
mktext "Library/Logs/com.example.chat/chat.log" "$(date) INFO app started" 1
mkfile "Library/Logs/com.example.chat/chat.log.1" 900K 15
mkfile "Library/Logs/com.example.chat/chat.log.2.gz" 300K 45
mkfile "Library/Logs/DiagnosticReports/PhotoEditor-2026-09-01-101522.ips" 48K 42
mkfile "Library/Logs/DiagnosticReports/Chat-2026-10-10-230001.ips" 52K 3
mkfile "Library/Logs/Homebrew/wget/01.configure" 8K 60
mkfile "Library/Logs/CoreSimulator/CoreSimulator.log" 2M 20
mkfile "Library/Logs/install.log" 1M 5

# --- Xcode ---------------------------------------------------------------------
dd_root="Library/Developer/Xcode/DerivedData"
mkfile "$dd_root/MacCleaner-abcdefghijklmnopqrstuvwxyz01/Build/Products/Debug/MacCleaner.app/Contents/MacOS/MacCleaner" 15M 1
mkfile "$dd_root/MacCleaner-abcdefghijklmnopqrstuvwxyz01/Index.noindex/DataStore/units/unit1" 40M 1
mkfile "$dd_root/MacCleaner-abcdefghijklmnopqrstuvwxyz01/Build/Intermediates.noindex/MacCleaner.build/Debug/App.build/Objects-normal/arm64/main.o" 2M 1
mktext "$dd_root/MacCleaner-abcdefghijklmnopqrstuvwxyz01/info.plist" '<?xml version="1.0"?><plist version="1.0"><dict><key>WorkspacePath</key><string>/Users/me/Clone-appies/App.xcodeproj</string></dict></plist>'
mkfile "$dd_root/OldProject-zyxwvutsrqponmlkjihgfedcba99/Build/Products/Debug/Old" 60M 180
mkfile "$dd_root/ModuleCache.noindex/ABCDEF/Foundation.pcm" 25M 30
mkfile "Library/Developer/Xcode/Archives/2026-08-01/MacCleaner 1-8-26, 10.00.xcarchive/Products/Applications/MacCleaner.app/Contents/MacOS/MacCleaner" 18M 70
mkfile "Library/Developer/Xcode/iOS DeviceSupport/17.5 (21F79) arm64e/Symbols/usr/lib/dyld" 50M 300
mkfile "Library/Developer/CoreSimulator/Caches/dyld/23A344/com.apple.dyld/dyld_sim_shared_cache_arm64" 80M 100
mkfile "Library/Developer/Xcode/UserData/IDEEditorInteractivityHistoryEnabled" 1K

# --- Trash ---------------------------------------------------------------------
mkfile ".Trash/old-screenshot.png" 3M 10
mkfile ".Trash/report-draft-v2.docx" 400K 25
mkfile ".Trash/Project Backup/archive.tar" 25M 60
mktext ".Trash/notes.txt" "to delete" 2

# --- Downloads -----------------------------------------------------------------
# Partial Safari download bundle.
mkfile "Downloads/BigInstaller.pkg.download/BigInstaller.pkg" 35M 20
mktext "Downloads/BigInstaller.pkg.download/Info.plist" '<?xml version="1.0"?><plist version="1.0"><dict><key>DownloadEntryURL</key><string>https://example.com/BigInstaller.pkg</string></dict></plist>' 20
mkfile "Downloads/Example-App-3.2.1.dmg" 90M 95
mkfile "Downloads/node-v22.9.0.pkg" 45M 50
mkfile "Downloads/Screenshot 2026-09-14 at 10.03.11.png" 2M 29
mkfile "Downloads/Screenshot 2026-10-12 at 09.11.45.png" 2M 1
mkfile "Downloads/photos-export.zip" 60M 150
mkfile "Downloads/invoice-2024-03.pdf" 150K 560
mkfile "Downloads/duplicate-a.jpg" 4M 10
cp "Downloads/duplicate-a.jpg" "Downloads/duplicate-b.jpg"      # exact duplicate for dedupe tests
cp "Downloads/duplicate-a.jpg" "Documents/Pictures/duplicate-c.jpg" 2>/dev/null || { mkdir -p Documents/Pictures; cp "Downloads/duplicate-a.jpg" "Documents/Pictures/duplicate-c.jpg"; }
FILE_COUNT=$(( FILE_COUNT + 2 )); TOTAL_BYTES=$(( TOTAL_BYTES + 2 * 4 * 1048576 ))

# --- AI tool leftovers ---------------------------------------------------------
mkfile ".ollama/models/blobs/sha256-$(printf '%064d' 1)" 120M 30
mkfile ".ollama/models/blobs/sha256-$(printf '%064d' 2)" 60M 5
mktext ".ollama/models/manifests/registry.ollama.ai/library/llama3/latest" '{"schemaVersion":2,"layers":[]}' 30
mkfile ".cache/huggingface/hub/models--bert-base-uncased/blobs/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" 100M 120
mktext ".cache/huggingface/hub/models--bert-base-uncased/refs/main" "abcdef1234567890" 120
mkfile ".cache/huggingface/hub/models--bert-base-uncased/snapshots/abcdef1234567890/config.json" 1K 120
mkfile ".cache/lm-studio/models/TheBloke/some-model-GGUF/some-model.Q4_K_M.gguf" 80M 45
mkfile "Library/Caches/com.apple.dt.Xcode/predictive-completion/model.bin" 30M 10

# --- Other junk ------------------------------------------------------------------
mkfile "Library/Application Support/MobileSync/Backup/00008030-000A1B2C3D4E5F6G/Manifest.db" 10M 400
mkfile "Library/Application Support/MobileSync/Backup/00008030-000A1B2C3D4E5F6G/ab/abcdef0123456789" 50M 400
mkfile "Library/Mail/V10/MailData/Attachments/abc/1/report.pdf" 6M 200
mkfile "Library/Containers/com.example.oldapp/Data/Library/Caches/blob" 7M 300
mkfile "Library/Preferences/com.example.removedapp.plist" 2K 400
mkfile "Library/Application Support/com.example.removedapp/state.db" 3M 400
mkfile ".docker/buildx/cache/blob" 15M 60

# --- Legit user data (control group; scanners must NOT return these) --------------
mkfile "Documents/Thesis/thesis.pdf" 3M 200
mktext "Documents/Thesis/notes.md" "# Notes" 10
mkfile "Desktop/family.jpg" 5M 30
mkfile "Documents/Taxes/2025.pdf" 700K 250
mkfile "Movies/holiday.mov" 150M 400
mkfile "Music/track01.m4a" 8M 500

# --- Symlink loop + unreadable dir (walker robustness) ---------------------------
mkdir -p "Library/Caches/com.example.loop/a/b"
ln -s ../../ "Library/Caches/com.example.loop/a/b/up" 2>/dev/null || true
mkdir -p "Library/Caches/com.example.denied"
mkfile "Library/Caches/com.example.denied/secret.bin" 64K
chmod 000 "Library/Caches/com.example.denied" || true

# --- Summary --------------------------------------------------------------------
echo
echo "==> Fixture summary"
printf '  %-48s %s\n' "root" "$TARGET"
printf '  %-48s %d\n' "files created" "$FILE_COUNT"
printf '  %-48s %s\n' "approx total" "$(human "$TOTAL_BYTES")"
echo
echo "  Per-area sizes:"
for d in Library/Caches Library/Logs Library/Developer .Trash Downloads .ollama .cache \
         "Library/Application Support/MobileSync" Library/Mail Library/Containers .docker Documents Desktop Movies Music; do
  if [[ -e "$d" ]]; then
    printf '  %-48s %s\n' "$d" "$(du -sh "$d" 2>/dev/null | cut -f1 | tr -d ' ')"
  fi
done
echo
echo "Note: Library/Caches/com.example.denied is chmod 000 (permission-denied test)."
echo "      Remove fixtures with: chmod -R u+rwx '$TARGET' && rm -rf '$TARGET'"
