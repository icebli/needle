#!/bin/bash
set -eu

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOST_APP=""
for candidate in "/Applications/Needle.app" "$HOME/Applications/Needle.app"; do
  if [[ -x "$candidate/Contents/Resources/bin/needle-browser-host" ]]; then
    HOST_APP="$candidate"
    break
  fi
done

if [[ -z "$HOST_APP" ]]; then
  echo "Needle.app was not found in /Applications or ~/Applications. Install Needle first, then run this installer again."
  read -r -p "Press Return to close…" _ || true
  exit 1
fi

APP_BIN="$HOST_APP/Contents/Resources/bin"
HOST="$APP_BIN/needle-browser-host"
INSTALL_DIR="$HOME/Library/Application Support/Needle/bin"
FIREFOX_DIR="$HOME/Library/Application Support/Mozilla/NativeMessagingHosts"
ZEN_DIR="$HOME/Library/Application Support/zen/NativeMessagingHosts"
CHROME_DIR="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
WRAPPER="$INSTALL_DIR/needle-browser-host"

mkdir -p "$INSTALL_DIR" "$FIREFOX_DIR" "$ZEN_DIR" "$CHROME_DIR"
printf '#!/bin/sh\nset -eu\nexport PATH=%q:"\${PATH:-}"\nexec %q "$@"\n' "$APP_BIN" "$HOST" > "$WRAPPER"
chmod 0755 "$WRAPPER"

"$APP_BIN/node" - "$WRAPPER" \
  "$FIREFOX_DIR/dev.tege.needle.browser.json" \
  "$ZEN_DIR/dev.tege.needle.browser.json" \
  "$CHROME_DIR/dev.tege.needle.browser.json" <<'NODE'
const fs = require("node:fs");
const [wrapper, firefox, zen, chrome] = process.argv.slice(2);
const base = { name: "dev.tege.needle.browser", description: "Needle browser extension native messaging host", path: wrapper, type: "stdio" };
fs.writeFileSync(firefox, JSON.stringify({ ...base, allowed_extensions: ["needle@tege.dev"] }, null, 2) + "\n");
fs.writeFileSync(zen, JSON.stringify({ ...base, allowed_extensions: ["needle@tege.dev"] }, null, 2) + "\n");
fs.writeFileSync(chrome, JSON.stringify({ ...base, allowed_origins: ["chrome-extension://oljnldpeaookagcidchhjmlkocoglhia/"] }, null, 2) + "\n");
NODE

if [[ "${1:-}" == "--setup-spicetify" || "${1:-}" == "--setup-spotify" ]]; then
  SPICETIFY_BIN="$(command -v spicetify || true)"
  if [[ -z "$SPICETIFY_BIN" && -x "$HOME/.spicetify/spicetify" ]]; then SPICETIFY_BIN="$HOME/.spicetify/spicetify"; fi
  if [[ -z "$SPICETIFY_BIN" ]]; then
    echo "Spicetify was not found; browser integration was installed, but Spotify playlist sync was skipped." >&2
  else
    SPICETIFY_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/spicetify/Extensions"
    mkdir -p "$SPICETIFY_DIR"
    install -m 0644 "$ROOT_DIR/spicetify/needle-local-playlist.js" "$SPICETIFY_DIR/needle-local-playlist.js"
    install -m 0644 "$ROOT_DIR/spicetify/needle-discovery.js" "$SPICETIFY_DIR/needle-discovery.js"
    CURRENT_EXTENSIONS="$($SPICETIFY_BIN config extensions 2>/dev/null | tr '\n' '|')"
    CURRENT_EXTENSIONS="${CURRENT_EXTENSIONS%|}"
    for extension in needle-local-playlist.js needle-discovery.js; do
      case "|$CURRENT_EXTENSIONS|" in
        *"|$extension|"*) ;;
        *) CURRENT_EXTENSIONS="${CURRENT_EXTENSIONS:+$CURRENT_EXTENSIONS|}$extension" ;;
      esac
    done
    "$SPICETIFY_BIN" config extensions "$CURRENT_EXTENSIONS"
    "$SPICETIFY_BIN" apply
    echo "Spicetify playlist sync and discovery installed. Restart Spotify if it was open."
  fi
else
  echo "Spotify was not changed. To enable playlist sync later, rerun this installer with --setup-spicetify."
fi

echo "Needle browser native messaging is installed for Chrome, Firefox, and Zen."
echo "Chrome: open chrome://extensions, enable Developer mode, choose Load unpacked, and select:"
echo "  $ROOT_DIR/chrome-extension"
echo "Firefox/Zen: open about:debugging, choose This Firefox, Load Temporary Add-on, and select:"
echo "  $ROOT_DIR/needle-firefox.xpi"
if [[ "${NEEDLE_COMPANION_NO_OPEN:-0}" != 1 ]]; then
  open -a "Google Chrome" "chrome://extensions" 2>/dev/null || true
  open "$ROOT_DIR/chrome-extension" 2>/dev/null || true
fi
read -r -p "Press Return to close…" _ || true
