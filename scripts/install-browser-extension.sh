#!/usr/bin/env bash
set -euo pipefail

SKIP_SPOTIFY=false
CLI_ONLY=false
for argument in "$@"; do
  case "$argument" in
    --skip-spotify) SKIP_SPOTIFY=true ;;
    --cli-only) CLI_ONLY=true ;;
    *) echo "Usage: $0 [--skip-spotify] [--cli-only]" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_DIR="$HOME/Library/Application Support/Needle/bin"
CARGO_BIN_DIR="$HOME/.cargo/bin"
FIREFOX_NATIVE_DIR="$HOME/Library/Application Support/Mozilla/NativeMessagingHosts"
ZEN_NATIVE_DIR="$HOME/Library/Application Support/zen/NativeMessagingHosts"
CHROME_NATIVE_DIR="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
NATIVE_MANIFEST="$FIREFOX_NATIVE_DIR/dev.tege.needle.browser.json"
ZEN_NATIVE_MANIFEST="$ZEN_NATIVE_DIR/dev.tege.needle.browser.json"
CHROME_NATIVE_MANIFEST="$CHROME_NATIVE_DIR/dev.tege.needle.browser.json"
SPICETIFY_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/spicetify/Extensions"
TARGET_DIR="$REPO_DIR/target/browser-extension"

cd "$REPO_DIR"
cargo build --release -p needle-cli -p needle-browser-host

mkdir -p "$INSTALL_DIR" "$CARGO_BIN_DIR" "$FIREFOX_NATIVE_DIR" "$ZEN_NATIVE_DIR" "$CHROME_NATIVE_DIR" "$TARGET_DIR"
install -m 0755 "$REPO_DIR/target/release/needle" "$INSTALL_DIR/needle"
install -m 0755 "$REPO_DIR/target/release/needle" "$CARGO_BIN_DIR/needle"
install -m 0755 "$REPO_DIR/target/release/needle-browser-host" "$INSTALL_DIR/needle-browser-host"

python3 - "$REPO_DIR/native-host/dev.tege.needle.browser.json.in" "$NATIVE_MANIFEST" "$INSTALL_DIR/needle-browser-host" <<'PY'
import json
import pathlib
import sys

template, destination, host = map(pathlib.Path, sys.argv[1:])
data = json.loads(template.read_text())
data["path"] = str(host.resolve())
destination.write_text(json.dumps(data, indent=2) + "\n")
PY
install -m 0644 "$NATIVE_MANIFEST" "$ZEN_NATIVE_MANIFEST"

python3 - "$REPO_DIR/native-host/dev.tege.needle.browser.chrome.json.in" "$CHROME_NATIVE_MANIFEST" "$INSTALL_DIR/needle-browser-host" <<'PY'
import json
import pathlib
import sys

template, destination, host = map(pathlib.Path, sys.argv[1:])
data = json.loads(template.read_text())
data["path"] = str(host.resolve())
destination.write_text(json.dumps(data, indent=2) + "\n")
PY

if [[ "$SKIP_SPOTIFY" == false ]]; then
  mkdir -p "$SPICETIFY_DIR"
  install -m 0644 "$REPO_DIR/spicetify/needle-local-playlist.js" "$SPICETIFY_DIR/needle-local-playlist.js"
fi

SPICETIFY_BIN="$(command -v spicetify || true)"
if [[ -z "$SPICETIFY_BIN" && -x "$HOME/.spicetify/spicetify" ]]; then
  SPICETIFY_BIN="$HOME/.spicetify/spicetify"
fi
if [[ "$SKIP_SPOTIFY" == true ]]; then
  echo "Spotify configuration left unchanged (--skip-spotify)"
elif [[ -n "$SPICETIFY_BIN" ]]; then
  "$SPICETIFY_BIN" config extensions needle-local-playlist.js
  if ! "$SPICETIFY_BIN" apply; then
    echo "Spotify changed since the last Spicetify backup; refreshing the backup before applying extensions" >&2
    "$SPICETIFY_BIN" backup apply
  fi
else
  echo "warning: Spicetify was not found; the Firefox extension works, but Spotify playlist sync is not installed" >&2
fi

rm -f "$TARGET_DIR/needle-firefox.xpi"
(
  cd "$REPO_DIR/browser-extension"
  zip -q -r "$TARGET_DIR/needle-firefox.xpi" . -x 'tests/*' '*.DS_Store'
)

rm -f "$TARGET_DIR/needle-chrome.zip"
CHROME_STAGE="$TARGET_DIR/needle-chrome"
rm -rf "$CHROME_STAGE"
mkdir -p "$CHROME_STAGE/icons"
cp "$REPO_DIR/browser-extension/chrome/manifest.json" "$CHROME_STAGE/manifest.json"
cp "$REPO_DIR/browser-extension/chrome/background.js" "$CHROME_STAGE/background.js"
for shared_file in browser-compat.js context-capture.js page-probe.js popup.css popup.html popup.js track-detection.js; do
  cp "$REPO_DIR/browser-extension/$shared_file" "$CHROME_STAGE/$shared_file"
done
cp "$REPO_DIR/browser-extension/icons/needle-48.png" "$CHROME_STAGE/icons/needle-48.png"
cp "$REPO_DIR/browser-extension/icons/needle-96.png" "$CHROME_STAGE/icons/needle-96.png"
(
  cd "$CHROME_STAGE"
  zip -q -r "$TARGET_DIR/needle-chrome.zip" . -x '*.DS_Store'
)

if [[ "$CLI_ONLY" == false && "$(uname -s)" == "Darwin" && -f "$REPO_DIR/desktop/Package.swift" ]]; then
  "$SCRIPT_DIR/build-desktop.sh"
  mkdir -p "$HOME/Applications"
  # Stage and verify a complete bundle so obsolete resources cannot invalidate
  # the signature when upgrading an existing installation.
  APP_STAGE="$(mktemp -d "$HOME/Applications/.needle-install.XXXXXX")"
  ditto "$REPO_DIR/target/desktop/Needle.app" "$APP_STAGE/Needle.app"
  codesign --verify --deep --strict "$APP_STAGE/Needle.app"
  if [[ -e "$HOME/Applications/Needle.app" ]]; then
    mv "$HOME/Applications/Needle.app" "$APP_STAGE/Previous-Needle.app"
  fi
  mv "$APP_STAGE/Needle.app" "$HOME/Applications/Needle.app"
  echo "Previous app backup: $APP_STAGE/Previous-Needle.app"
  echo "Desktop app: $HOME/Applications/Needle.app"
fi

echo "Firefox native host: $NATIVE_MANIFEST"
echo "Zen native host: $ZEN_NATIVE_MANIFEST"
echo "Chrome native host: $CHROME_NATIVE_MANIFEST"
echo "Firefox package: $TARGET_DIR/needle-firefox.xpi"
echo "Chrome package: $TARGET_DIR/needle-chrome.zip"
"$SCRIPT_DIR/package-browser-companion.sh" "$TARGET_DIR"
echo "Self-contained companion package: $TARGET_DIR/needle-companion.zip"
if [[ "$SKIP_SPOTIFY" == false ]]; then
  echo "Spicetify companion: $SPICETIFY_DIR/needle-local-playlist.js"
fi
echo "Load browser-extension/manifest.json temporarily from about:debugging, or install a signed build of the XPI."
echo "Load target/browser-extension/needle-chrome/ as an unpacked extension at chrome://extensions."
