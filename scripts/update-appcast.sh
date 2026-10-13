#!/usr/bin/env bash
set -euo pipefail

# Generate the signed Sparkle appcast for a directory of release archives.
# Sparkle's EdDSA private key stays in the release operator's login keychain;
# this script never accepts or writes a private key to the repository.
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
UPDATES_DIR="${1:-}"
VERSION="${2:-}"
SPARKLE_ROOT="${SPARKLE_ROOT:-$REPO_DIR/desktop/.build/artifacts/sparkle/Sparkle}"
GENERATE_APPCAST="$SPARKLE_ROOT/bin/generate_appcast"

if [[ $# != 2 || ! -d "$UPDATES_DIR" || ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Usage: $0 /path/to/notarized-dmg-archives VERSION" >&2
  exit 2
fi

if [[ ! -x "$GENERATE_APPCAST" ]]; then
  echo "Sparkle tools not found at $GENERATE_APPCAST" >&2
  echo "Run: swift package resolve --package-path desktop" >&2
  exit 1
fi

shopt -s nullglob
archives=("$UPDATES_DIR"/*.dmg)
[[ ${#archives[@]} -gt 0 ]] || { echo "No notarized DMG archives found." >&2; exit 1; }
for archive in "${archives[@]}"; do
  codesign -dv "$archive" 2>&1 | grep -q 'Authority=Developer ID Application:' || {
    echo "Update archives require Developer ID signatures: $archive" >&2; exit 1;
  }
  xcrun stapler validate "$archive"
  spctl --assess --type open --context context:primary-signature "$archive"
done
exec "$GENERATE_APPCAST" --account dev.tege.needle.updates \
  --download-url-prefix "https://github.com/icebli/needle/releases/download/v$VERSION/" "$UPDATES_DIR"
