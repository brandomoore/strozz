#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "upload-sentry-symbols.sh: $*" >&2
  exit 1
}

[[ $# -eq 1 ]] || fail "Pass a Strozz .xcarchive or app .dSYM directory."
[[ -d "$1" ]] || fail "Symbol input does not exist."
command -v sentry-cli >/dev/null 2>&1 || fail "Install sentry-cli and authenticate outside Git before releasing."

source "$ROOT/tools/lib/apple-build-lease.sh"
acquire_apple_build_shared_lease "strozz/sentry-symbols"
install_apple_build_lease_traps

case "$1" in
  *.xcarchive)
    [[ -f "$1/Info.plist" ]] || fail "Archive Info.plist is missing."
    APP_REL=$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:ApplicationPath' "$1/Info.plist")
    [[ "$APP_REL" == Applications/*.app && "$APP_REL" != *".."* ]] || fail "Unexpected app path in archive."
    BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Products/$APP_REL/Info.plist")
    [[ "$BUNDLE_ID" == "com.thatcube.Strozz" ]] || fail "Refusing symbols from another app."
    SYMBOLS="$1/dSYMs"
    [[ -d "$SYMBOLS" ]] || fail "Archive has no dSYMs."
    shopt -s nullglob
    APP_SYMBOLS=("$SYMBOLS"/Strozz.app.dSYM "$SYMBOLS"/StrozzMobile.app.dSYM)
    FOUND=0
    for FILE in "${APP_SYMBOLS[@]}"; do
      if [[ -d "$FILE" ]]; then
        UUIDS=$(xcrun dwarfdump --uuid "$FILE")
        [[ "$UUIDS" == UUID:* ]] || fail "App dSYM contains no readable debug identifiers."
        FOUND=1
      fi
    done
    [[ "$FOUND" -eq 1 ]] || fail "Archive is missing its Strozz app dSYM."
    ;;
  *.dSYM)
    case "$(basename "$1")" in
      Strozz.app.dSYM|StrozzMobile.app.dSYM)
        SYMBOLS="$1"
        UUIDS=$(xcrun dwarfdump --uuid "$SYMBOLS")
        [[ "$UUIDS" == UUID:* ]] || fail "App dSYM contains no readable debug identifiers."
        ;;
      *) fail "Refusing a non-Strozz app dSYM." ;;
    esac
    ;;
  *) fail "Expected a .xcarchive or an app .dSYM, not a general build directory." ;;
esac

# Explicit destination and no source bundles: never inherit another app's project.
sentry-cli debug-files upload \
  --org plozz --project strozz --type dsym --no-sources --wait-for 120 "$SYMBOLS"
