#!/usr/bin/env bash
set -euo pipefail

# Bundle the external media tools used by the desktop app. This deliberately
# accepts explicit paths so a release can be reproduced and audited without
# silently downloading or upgrading a user's toolchain.

if [[ $# -lt 1 ]]; then
  echo "usage: $0 APP_PATH [YTDLP_PATH] [FFMPEG_PATH] [FFPROBE_PATH] [NODE_PATH]" >&2
  exit 2
fi

APP_PATH="$1"
YTDLP_PATH="${2:-${NEEDLE_YTDLP_PATH:-}}"
FFMPEG_PATH="${3:-${NEEDLE_FFMPEG_PATH:-}}"
FFPROBE_PATH="${4:-${NEEDLE_FFPROBE_PATH:-}}"
NODE_PATH="${5:-${NEEDLE_NODE_PATH:-}}"
RESOURCES="$APP_PATH/Contents/Resources"
BIN_DIR="$RESOURCES/bin"
LIB_DIR="$RESOURCES/lib"
NOTICE="$RESOURCES/THIRD_PARTY_NOTICES.md"
MANIFEST="$RESOURCES/NeedleToolchain.json"

[[ -d "$APP_PATH/Contents" ]] || { echo "app bundle not found: $APP_PATH" >&2; exit 1; }

resolve_tool() {
  local requested="$1" fallback="$2"
  if [[ -n "$requested" ]]; then
    printf '%s\n' "$requested"
  elif [[ -x "$fallback" ]]; then
    printf '%s\n' "$fallback"
  else
    command -v "$(basename "$fallback")" 2>/dev/null || true
  fi
}

YTDLP_PATH="$(resolve_tool "$YTDLP_PATH" "yt-dlp_macos")"
FFMPEG_PATH="$(resolve_tool "$FFMPEG_PATH" "ffmpeg")"
FFPROBE_PATH="$(resolve_tool "$FFPROBE_PATH" "ffprobe")"
NODE_PATH="$(resolve_tool "$NODE_PATH" "node")"

for pair in "yt-dlp:$YTDLP_PATH" "ffmpeg:$FFMPEG_PATH" "ffprobe:$FFPROBE_PATH" "node:$NODE_PATH"; do
  name="${pair%%:*}"; path="${pair#*:}"
  [[ -n "$path" && -x "$path" ]] || { echo "$name executable not found; pass the matching NEEDLE_*_PATH variable" >&2; exit 1; }
done

mkdir -p "$BIN_DIR"
rm -f "$BIN_DIR/yt-dlp" "$BIN_DIR/.yt-dlp-real" "$BIN_DIR/ffmpeg" "$BIN_DIR/ffprobe"
rm -rf "$LIB_DIR"
mkdir -p "$LIB_DIR"

if [[ "$(basename "$YTDLP_PATH")" == "yt-dlp" ]] && head -1 "$YTDLP_PATH" 2>/dev/null | grep -q '^#!'; then
  echo "yt-dlp is a Python wrapper and is not portable; use the official yt-dlp_macos standalone asset via NEEDLE_YTDLP_PATH" >&2
  exit 1
fi
if ! file "$YTDLP_PATH" | grep -Eq 'Mach-O|executable'; then
  echo "yt-dlp must be an executable standalone release asset: $YTDLP_PATH" >&2
  exit 1
fi

install -m 0755 "$YTDLP_PATH" "$BIN_DIR/.yt-dlp-real"
cat > "$BIN_DIR/yt-dlp" <<'EOF'
#!/bin/sh
set -eu
exec "$(dirname "$0")/.yt-dlp-real" --js-runtimes "node:$(dirname "$0")/node" "$@"
EOF
chmod 0755 "$BIN_DIR/yt-dlp"
install -m 0755 "$FFMPEG_PATH" "$BIN_DIR/ffmpeg"
install -m 0755 "$FFPROBE_PATH" "$BIN_DIR/ffprobe"
install -m 0755 "$NODE_PATH" "$BIN_DIR/node"
# Keep the existing Mach-O signature layout while rewriting load commands.
# Removing it first can leave LINKEDIT padding that older tools cannot parse.
# All relocated copies are signed again before their first execution below.

copy_dependency() {
  local owner="$1" dep="$2" owner_dir="$3" base source target
  [[ "$dep" == /* ]] || return 0
  case "$dep" in
    /System/*|/usr/lib/*) return 0 ;;
  esac
  base="$(basename "$dep")"
  target="$LIB_DIR/$base"
  [[ -f "$target" ]] && return 0
  source="$dep"
  [[ -f "$source" ]] || { echo "unresolved non-system dependency for $owner: $dep" >&2; exit 1; }
  install -m 0644 "$source" "$target"
  install_name_tool -id "@loader_path/$base" "$target"
  patch_binary "$target" dylib
}

patch_binary() {
  local binary="$1" kind="$2" dep base replacement
  while IFS= read -r dep; do
    [[ -n "$dep" ]] || continue
    case "$dep" in
      /System/*|/usr/lib/*|@loader_path/*|@rpath/*) continue ;;
    esac
    base="$(basename "$dep")"
    # The first otool -L entry is a dylib's own install name. It must become
    # the new id above, never a dependency on itself via @loader_path.
    if [[ "$kind" == dylib && "$base" == "$(basename "$binary")" ]]; then
      continue
    fi
    if [[ "$kind" == dylib ]]; then replacement="@loader_path/$base"; else replacement="@loader_path/../lib/$base"; fi
    copy_dependency "$binary" "$dep" "$(dirname "$binary")"
    install_name_tool -change "$dep" "$replacement" "$binary"
  done < <(otool -L "$binary" | tail -n +2 | sed -E 's/^[[:space:]]+([^[:space:]]+).*/\1/')
}

patch_binary "$BIN_DIR/ffmpeg" executable
patch_binary "$BIN_DIR/ffprobe" executable
patch_binary "$BIN_DIR/node" executable

# Keep copied Mach-O tools runnable during the smoke test. The package step
# replaces these temporary ad-hoc signatures with the requested identity.
while IFS= read -r code; do
  /usr/bin/codesign --force --sign - "$code" >/dev/null
done < <(find "$LIB_DIR" -type f -name '*.dylib' -print)
/usr/bin/codesign --force --sign - "$BIN_DIR/ffmpeg" "$BIN_DIR/ffprobe" >/dev/null
/usr/bin/codesign --force --sign - "$BIN_DIR/node" >/dev/null

if ! "$BIN_DIR/yt-dlp" --version >/dev/null 2>&1; then
  echo "bundled yt-dlp failed its version check" >&2
  exit 1
fi
/usr/bin/codesign --verify --strict "$BIN_DIR/.yt-dlp-real"
"$BIN_DIR/ffmpeg" -version >/dev/null
"$BIN_DIR/ffprobe" -version >/dev/null
"$BIN_DIR/node" --version >/dev/null
FF_BUILD_FLAGS="$($FFMPEG_PATH -buildconf 2>&1 | tr '\n' ' ')"
if [[ "$FF_BUILD_FLAGS" == *"--enable-nonfree"* ]]; then
  echo "refusing to package FFmpeg built with --enable-nonfree" >&2
  exit 1
fi

YT_VERSION="$($BIN_DIR/yt-dlp --version)"
FF_VERSION="$($BIN_DIR/ffmpeg -version | sed -n '1s/^ffmpeg version //p')"
YT_SHA="$(shasum -a 256 "$BIN_DIR/yt-dlp" | awk '{print $1}')"
YT_REAL_SHA="$(shasum -a 256 "$BIN_DIR/.yt-dlp-real" | awk '{print $1}')"
FF_SHA="$(shasum -a 256 "$BIN_DIR/ffmpeg" | awk '{print $1}')"
FP_SHA="$(shasum -a 256 "$BIN_DIR/ffprobe" | awk '{print $1}')"
NODE_VERSION="$($BIN_DIR/node --version)"
NODE_SHA="$(shasum -a 256 "$BIN_DIR/node" | awk '{print $1}')"

export MANIFEST YT_VERSION YT_SHA YT_REAL_SHA FF_VERSION FF_SHA FP_SHA NODE_VERSION NODE_SHA FF_BUILD_FLAGS
python3 - <<'PY'
import json, os, pathlib
path = pathlib.Path(os.environ["MANIFEST"])
data = {
    "yt_dlp": {"path": "Contents/Resources/bin/yt-dlp", "real_path": "Contents/Resources/bin/.yt-dlp-real", "version": os.environ["YT_VERSION"], "sha256": os.environ["YT_SHA"], "real_sha256": os.environ["YT_REAL_SHA"], "source": "official yt-dlp_macos standalone release with bundled Node.js EJS runtime wrapper"},
    "ffmpeg": {"path": "Contents/Resources/bin/ffmpeg", "version": os.environ["FF_VERSION"], "sha256": os.environ["FF_SHA"], "source": "packager-provided FFmpeg build", "build_flags": os.environ["FF_BUILD_FLAGS"]},
    "ffprobe": {"path": "Contents/Resources/bin/ffprobe", "sha256": os.environ["FP_SHA"], "source": "same FFmpeg build as ffmpeg"},
    "node": {"path": "Contents/Resources/bin/node", "version": os.environ["NODE_VERSION"], "sha256": os.environ["NODE_SHA"], "source": "packager-provided Node.js runtime for yt-dlp EJS"},
}
path.write_text(json.dumps(data, indent=2) + "\n")
PY

cat > "$NOTICE" <<EOF
# Needle bundled tools

This application bundles the exact binaries listed in \`NeedleToolchain.json\`.
Verify the corresponding release sources and license files before redistributing
an artifact. Hashes are included so a release can be audited after packaging.

## yt-dlp

The bundled \`yt-dlp_macos\` standalone asset is GPLv3+. Source and release
checksums: https://github.com/yt-dlp/yt-dlp/releases

## FFmpeg and FFprobe

These binaries are from the same FFmpeg build. FFmpeg licensing depends on its
configure flags; review the upstream license and source for the exact build
before publishing: https://ffmpeg.org/legal.html and https://ffmpeg.org/download.html

The package must not be described as a trusted public macOS distribution until
it is signed with a Developer ID Application identity, has hardened runtime,
and passes Apple's notarization workflow.

## Node.js

The bundled Node.js runtime is used by yt-dlp's EJS challenge support. Record
its exact upstream release and license with the release artifact: https://nodejs.org/
EOF

echo "Bundled media tools in $BIN_DIR"
echo "Toolchain manifest: $MANIFEST"
