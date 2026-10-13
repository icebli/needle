#!/usr/bin/env bash
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${NEEDLE_BUILD_CONFIGURATION:-release}"
APP_DIR="$REPO_DIR/target/desktop/Needle.app"
ICON_SOURCE="$REPO_DIR/desktop/Resources/Needle.icns"
ICON_PATH="$APP_DIR/Contents/Resources/Needle.icns"
WORKSPACE_VERSION="$(awk -F'\"' '/^version = \"/ { print $2; exit }' "$REPO_DIR/Cargo.toml")"
APP_VERSION="${NEEDLE_APP_VERSION:-$WORKSPACE_VERSION}"
BUILD_NUMBER="${NEEDLE_BUILD_NUMBER:-${APP_VERSION//[^0-9.]/}}"
BUILD_NUMBER="${BUILD_NUMBER//./}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"

if [[ "$CONFIGURATION" != "debug" && "$CONFIGURATION" != "release" ]]; then
  echo "NEEDLE_BUILD_CONFIGURATION must be debug or release" >&2
  exit 2
fi

cargo build --manifest-path "$REPO_DIR/Cargo.toml" --release -p needle-cli -p needle-browser-host
swift build --package-path "$REPO_DIR/desktop" -c "$CONFIGURATION" --product NeedleDesktop
BIN_DIR="$(swift build --package-path "$REPO_DIR/desktop" -c "$CONFIGURATION" --show-bin-path)"
SPARKLE_SOURCE="$REPO_DIR/desktop/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
[[ -d "$SPARKLE_SOURCE" ]] || { echo "SwiftPM did not resolve Sparkle.framework." >&2; exit 1; }
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources/bin" "$APP_DIR/Contents/Frameworks"
ditto "$SPARKLE_SOURCE" "$APP_DIR/Contents/Frameworks/Sparkle.framework"
install -m 0644 "$REPO_DIR/desktop/.build/artifacts/sparkle/Sparkle/LICENSE" "$APP_DIR/Contents/Resources/SPARKLE_LICENSE"
if [[ ! -f "$ICON_SOURCE" ]]; then
  echo "Missing tracked app icon: $ICON_SOURCE" >&2
  exit 1
fi
install -m 0644 "$ICON_SOURCE" "$ICON_PATH"
install -m 0755 "$BIN_DIR/NeedleDesktop" "$APP_DIR/Contents/MacOS/NeedleDesktop"
if ! otool -l "$APP_DIR/Contents/MacOS/NeedleDesktop" | grep -Fq '@executable_path/../Frameworks'; then
  install_name_tool -add_rpath '@executable_path/../Frameworks' "$APP_DIR/Contents/MacOS/NeedleDesktop"
fi
install -m 0755 "$REPO_DIR/target/release/needle" "$APP_DIR/Contents/Resources/bin/needle"
install -m 0755 "$REPO_DIR/target/release/needle-browser-host" "$APP_DIR/Contents/Resources/bin/needle-browser-host"
cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>NeedleDesktop</string>
<key>CFBundleIdentifier</key><string>dev.tege.needle.desktop</string>
<key>CFBundleName</key><string>Needle</string>
<key>CFBundleDisplayName</key><string>Needle</string>
<key>CFBundleIconFile</key><string>Needle.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
<key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
/usr/bin/codesign --force --deep --preserve-metadata=entitlements --sign - "$APP_DIR"
echo "$APP_DIR"
