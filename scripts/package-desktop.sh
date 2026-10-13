#!/usr/bin/env bash
set -euo pipefail

# Build a shareable macOS artifact without mutating the user's global CLI or
# Spotify setup. Default output is a drag-to-Applications DMG in dist/.

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE_VERSION="$(awk -F'"' '/^version = "/ { print $2; exit }' "$REPO_DIR/Cargo.toml")"
VERSION="${NEEDLE_APP_VERSION:-$WORKSPACE_VERSION}"
OUTPUT_DIR="$REPO_DIR/dist"
FORMAT="dmg"
SIGN_IDENTITY="-"
YTDLP_PATH="${NEEDLE_YTDLP_PATH:-}"
FFMPEG_PATH="${NEEDLE_FFMPEG_PATH:-}"
FFPROBE_PATH="${NEEDLE_FFPROBE_PATH:-}"
NODE_PATH="${NEEDLE_NODE_PATH:-}"
ARCH="arm64"

usage() {
  cat >&2 <<'EOF'
Usage: scripts/package-desktop.sh [options]

  --version VERSION       Bundle version (default: workspace Cargo version)
  --output DIR            Artifact directory (default: dist)
  --format dmg|pkg|both   Artifact type (default: dmg)
  --sign IDENTITY         codesign identity, or - for ad-hoc (default: -)
  --arch arm64            Required architecture (default: arm64)
  --yt-dlp PATH           Official standalone yt-dlp_macos asset
  --ffmpeg PATH           FFmpeg executable to bundle
  --ffprobe PATH           Matching FFprobe executable to bundle
  --node PATH              Node.js runtime for yt-dlp EJS support
  --help

The script never installs tools globally, changes Spotify/Spicetify, uploads
releases, or claims that an ad-hoc package is notarized.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="$2"; shift 2 ;;
    --output) OUTPUT_DIR="$2"; shift 2 ;;
    --format) FORMAT="$2"; shift 2 ;;
    --sign) SIGN_IDENTITY="$2"; shift 2 ;;
    --arch) ARCH="$2"; shift 2 ;;
    --yt-dlp) YTDLP_PATH="$2"; shift 2 ;;
    --ffmpeg) FFMPEG_PATH="$2"; shift 2 ;;
    --ffprobe) FFPROBE_PATH="$2"; shift 2 ;;
    --node) NODE_PATH="$2"; shift 2 ;;
    --help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

[[ "$FORMAT" == dmg || "$FORMAT" == pkg || "$FORMAT" == both ]] || { echo "--format must be dmg, pkg, or both" >&2; exit 2; }
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.+][A-Za-z0-9.-]+)?$ ]] || { echo "version must look like 1.2.3" >&2; exit 2; }
[[ "$ARCH" == arm64 ]] || { echo "this first distribution workflow supports arm64 only" >&2; exit 2; }
command -v hdiutil >/dev/null || { echo "hdiutil is required on macOS" >&2; exit 1; }
command -v pkgbuild >/dev/null || { echo "pkgbuild is required on macOS" >&2; exit 1; }

APP_DIR="$REPO_DIR/target/desktop/Needle.app"
SPARKLE_SOURCE="${NEEDLE_SPARKLE_PATH:-$REPO_DIR/desktop/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework}"
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/needle-package.XXXXXX")"
ENTITLEMENTS="$STAGING/Needle.entitlements"
cat > "$ENTITLEMENTS" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.cs.allow-jit</key><true/>
</dict></plist>
EOF
cleanup() { rm -rf "$STAGING"; }
trap cleanup EXIT

mkdir -p "$OUTPUT_DIR"
NEEDLE_APP_VERSION="$VERSION" NEEDLE_BUILD_NUMBER="${VERSION//[^0-9]/}" \
  "$REPO_DIR/scripts/build-desktop.sh"

"$REPO_DIR/scripts/bundle-media-tools.sh" "$APP_DIR" "$YTDLP_PATH" "$FFMPEG_PATH" "$FFPROBE_PATH" "$NODE_PATH"

[[ -d "$SPARKLE_SOURCE" ]] || { echo "Sparkle.framework not found: $SPARKLE_SOURCE" >&2; exit 1; }
mkdir -p "$APP_DIR/Contents/Frameworks"
rm -rf "$APP_DIR/Contents/Frameworks/Sparkle.framework"
ditto --rsrc --extattr "$SPARKLE_SOURCE" "$APP_DIR/Contents/Frameworks/Sparkle.framework"
if [[ -f "$REPO_DIR/desktop/.build/artifacts/sparkle/Sparkle/LICENSE" ]]; then
  install -m 0644 "$REPO_DIR/desktop/.build/artifacts/sparkle/Sparkle/LICENSE" "$APP_DIR/Contents/Resources/SPARKLE_LICENSE"
fi

# Compute the real deployment floor from every bundled Mach-O.
REQUIRED_MACOS="$(python3 - "$APP_DIR" <<'PY'
import pathlib, subprocess, sys
app = pathlib.Path(sys.argv[1])
roots = [app / "Contents/MacOS", app / "Contents/Resources/bin", app / "Contents/Resources/lib", app / "Contents/Frameworks"]
paths = [p for root in roots for p in root.rglob("*") if p.is_file() and (p.suffix == ".dylib" or p.parent.name in {"MacOS", "bin"})]
versions = []
for path in paths:
    info = subprocess.run(["file", str(path)], capture_output=True, text=True, check=True).stdout
    if "Mach-O" not in info:
        continue
    if "arm64" not in info:
        raise SystemExit(f"non-arm64 bundled executable: {path}: {info.strip()}")
    output = subprocess.run(["otool", "-l", str(path)], capture_output=True, text=True, check=True).stdout
    for line in output.splitlines():
        fields = line.split()
        if fields and fields[0] == "minos":
            versions.append(tuple(int(part) for part in fields[1].split(".")[:2]))
            break
major, minor = max(versions or [(14, 0)])
print(f"{major}.{minor}")
PY
)"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $REQUIRED_MACOS" "$APP_DIR/Contents/Info.plist"
python3 - "$APP_DIR/Contents/Resources/NeedleToolchain.json" "$REQUIRED_MACOS" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text())
data["required_macos"] = sys.argv[2]
path.write_text(json.dumps(data, indent=2) + "\n")
PY
echo "Bundled Mach-O deployment floor: macOS $REQUIRED_MACOS"

if [[ "$SIGN_IDENTITY" != "-" && -n "${NEEDLE_UPDATE_PUBLIC_KEY:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Add :SUFeedURL string https://raw.githubusercontent.com/icebli/needle/main/appcast.xml" "$APP_DIR/Contents/Info.plist" 2>/dev/null || /usr/libexec/PlistBuddy -c "Set :SUFeedURL https://raw.githubusercontent.com/icebli/needle/main/appcast.xml" "$APP_DIR/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $NEEDLE_UPDATE_PUBLIC_KEY" "$APP_DIR/Contents/Info.plist" 2>/dev/null || /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $NEEDLE_UPDATE_PUBLIC_KEY" "$APP_DIR/Contents/Info.plist"
else
  /usr/libexec/PlistBuddy -c "Delete :SUFeedURL" "$APP_DIR/Contents/Info.plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Delete :SUPublicEDKey" "$APP_DIR/Contents/Info.plist" 2>/dev/null || true
fi

sign_sparkle() {
  local identity="$1"; local options=(--force --sign "$identity")
  [[ "$identity" == "-" ]] || options+=(--timestamp --options runtime)
  while IFS= read -r code; do
    if file "$code" | grep -q 'Mach-O'; then /usr/bin/codesign "${options[@]}" "$code"; fi
  done < <(find "$APP_DIR/Contents/Frameworks/Sparkle.framework" -type f -print | awk '{ print length, $0 }' | sort -rn | cut -d' ' -f2-)
  /usr/bin/codesign "${options[@]}" "$APP_DIR/Contents/Frameworks/Sparkle.framework"
}

refresh_manifest_hashes() {
  python3 - "$APP_DIR/Contents/Resources/NeedleToolchain.json" "$APP_DIR/Contents/Resources" <<'PY'
import hashlib, json, pathlib, sys
manifest = pathlib.Path(sys.argv[1])
root = pathlib.Path(sys.argv[2])
data = json.loads(manifest.read_text())
for entry in data.values():
    if not isinstance(entry, dict):
        continue
    for key in ("path", "real_path"):
        relative = entry.get(key)
        if relative:
            path = root.parent.parent / relative
            entry_key = "real_sha256" if key == "real_path" else "sha256"
            entry[entry_key] = hashlib.sha256(path.read_bytes()).hexdigest()
manifest.write_text(json.dumps(data, indent=2) + "\n")
PY
}

if [[ "$SIGN_IDENTITY" == "-" ]]; then
  echo "Signing locally with ad-hoc identity; this is not a notarized public release."
  sign_sparkle -
  /usr/bin/codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP_DIR/Contents/Resources/bin/node"
  refresh_manifest_hashes
  /usr/bin/codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP_DIR"
else
  echo "Signing nested tools and app with: $SIGN_IDENTITY"
  sign_sparkle "$SIGN_IDENTITY"
  while IFS= read -r code; do
    if [[ "$(basename "$code")" != ".yt-dlp-real" ]] && file "$code" | grep -q 'Mach-O'; then
      /usr/bin/codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$code"
    fi
  done < <(find "$APP_DIR/Contents/Resources" -type f \( -perm -111 -o -name '*.dylib' \) -print)
  /usr/bin/codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" --entitlements "$ENTITLEMENTS" "$APP_DIR/Contents/Resources/bin/node"
  refresh_manifest_hashes
  /usr/bin/codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" --entitlements "$ENTITLEMENTS" "$APP_DIR"
fi
/usr/bin/codesign --verify --deep --strict "$APP_DIR"

ARCHES="$(lipo -archs "$APP_DIR/Contents/MacOS/NeedleDesktop")"
[[ "$ARCHES" == *"$ARCH"* ]] || { echo "app architecture $ARCHES does not include $ARCH" >&2; exit 1; }
[[ -s "$APP_DIR/Contents/Resources/THIRD_PARTY_NOTICES.md" ]] || { echo "third-party notice missing" >&2; exit 1; }
[[ -s "$APP_DIR/Contents/Resources/NeedleToolchain.json" ]] || { echo "toolchain manifest missing" >&2; exit 1; }

while IFS= read -r binary; do
  while IFS= read -r dependency; do
    case "$dependency" in
      *'/opt/homebrew/'*|*'/usr/local/'*)
        echo "unresolved external dependency in $binary: $dependency" >&2
        exit 1
        ;;
      *'@rpath/'*)
        if [[ "$binary" != "$APP_DIR/Contents/Frameworks/"* ]] || ! find "$APP_DIR/Contents/Frameworks" -name "$(basename "$dependency")" -print -quit | grep -q .; then
          echo "unresolved @rpath dependency in $binary: $dependency" >&2
          exit 1
        fi
        ;;
    esac
  done < <(otool -L "$binary" | tail -n +2 | sed -E 's/^[[:space:]]+([^[:space:]]+).*/\1/')
done < <(find "$APP_DIR/Contents/Resources/bin" "$APP_DIR/Contents/Resources/lib" "$APP_DIR/Contents/Frameworks" -type f \( -perm -111 -o -name '*.dylib' \) -print)

APP_NAME="Needle-$VERSION"
if [[ "$FORMAT" == dmg || "$FORMAT" == both ]]; then
  DMG_STAGING="$STAGING/dmg"
  mkdir -p "$DMG_STAGING"
  ditto "$APP_DIR" "$DMG_STAGING/Needle.app"
  ln -s /Applications "$DMG_STAGING/Applications"
  hdiutil create -volname "Needle $VERSION" -srcfolder "$DMG_STAGING" -ov -format UDZO "$OUTPUT_DIR/$APP_NAME.dmg" >/dev/null
  if [[ "$SIGN_IDENTITY" != "-" ]]; then
    /usr/bin/codesign --force --timestamp --sign "$SIGN_IDENTITY" "$OUTPUT_DIR/$APP_NAME.dmg"
  fi
  echo "DMG: $OUTPUT_DIR/$APP_NAME.dmg"
fi

if [[ "$FORMAT" == pkg || "$FORMAT" == both ]]; then
  pkgbuild --component "$APP_DIR" --install-location /Applications "$OUTPUT_DIR/$APP_NAME.pkg" >/dev/null
  echo "PKG: $OUTPUT_DIR/$APP_NAME.pkg"
fi

echo "Validated arm64 Needle $VERSION package with bundled yt-dlp, ffmpeg, ffprobe, and node."
