#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TARGET_DIR="${1:-$REPO_DIR/target/browser-extension}"
mkdir -p "$TARGET_DIR"
TARGET_DIR="$(cd "$TARGET_DIR" && pwd)"
PACKAGE_DIR="$TARGET_DIR/needle-companion"
rm -rf "$PACKAGE_DIR"
mkdir -p "$PACKAGE_DIR/chrome-extension" "$PACKAGE_DIR/spicetify"

cp -R "$REPO_DIR/browser-extension/chrome/." "$PACKAGE_DIR/chrome-extension/"
cp "$REPO_DIR/browser-extension/browser-compat.js" "$PACKAGE_DIR/chrome-extension/browser-compat.js"
cp "$REPO_DIR/browser-extension/context-capture.js" "$PACKAGE_DIR/chrome-extension/context-capture.js"
cp "$REPO_DIR/browser-extension/page-probe.js" "$PACKAGE_DIR/chrome-extension/page-probe.js"
cp "$REPO_DIR/browser-extension/popup.css" "$PACKAGE_DIR/chrome-extension/popup.css"
cp "$REPO_DIR/browser-extension/popup.html" "$PACKAGE_DIR/chrome-extension/popup.html"
cp "$REPO_DIR/browser-extension/popup.js" "$PACKAGE_DIR/chrome-extension/popup.js"
cp "$REPO_DIR/browser-extension/track-detection.js" "$PACKAGE_DIR/chrome-extension/track-detection.js"
mkdir -p "$PACKAGE_DIR/chrome-extension/icons"
cp "$REPO_DIR/browser-extension/icons/needle-48.png" "$PACKAGE_DIR/chrome-extension/icons/needle-48.png"
cp "$REPO_DIR/browser-extension/icons/needle-96.png" "$PACKAGE_DIR/chrome-extension/icons/needle-96.png"

FIREFOX_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/needle-firefox.XXXXXX")"
trap 'rm -rf "$FIREFOX_STAGE"' EXIT
rm -f "$TARGET_DIR/needle-firefox.xpi" "$PACKAGE_DIR/needle-firefox.xpi"
for shared_file in browser-compat.js context-capture.js page-probe.js popup.css popup.html popup.js track-detection.js manifest.json; do
  cp "$REPO_DIR/browser-extension/$shared_file" "$FIREFOX_STAGE/$shared_file"
done
cp -R "$REPO_DIR/browser-extension/icons" "$FIREFOX_STAGE/icons"
(
  cd "$FIREFOX_STAGE"
  zip -q -r "$PACKAGE_DIR/../needle-firefox.xpi" . -x '*.DS_Store'
)
cp "$PACKAGE_DIR/../needle-firefox.xpi" "$PACKAGE_DIR/needle-firefox.xpi"
cp "$REPO_DIR/spicetify/needle-local-playlist.js" "$PACKAGE_DIR/spicetify/needle-local-playlist.js"
cp "$REPO_DIR/browser-extension/Install Needle Companion.command" "$PACKAGE_DIR/Install Needle Companion.command"
chmod 0755 "$PACKAGE_DIR/Install Needle Companion.command"

rm -f "$TARGET_DIR/needle-companion.zip"
(
  cd "$PACKAGE_DIR"
  zip -q -r "$TARGET_DIR/needle-companion.zip" . -x '*.DS_Store'
)
echo "$TARGET_DIR/needle-companion.zip"
