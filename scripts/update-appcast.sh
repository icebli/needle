#!/usr/bin/env bash
set -euo pipefail

# Generate the signed Sparkle appcast for a directory of release archives.
# Sparkle's EdDSA private key stays in the release operator's login keychain;
# this script never accepts or writes a private key to the repository.
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PREVIEW=0
if [[ "${1:-}" == "--preview" ]]; then
  PREVIEW=1
  shift
fi
UPDATES_DIR="${1:-}"
VERSION="${2:-}"
SPARKLE_ROOT="${SPARKLE_ROOT:-$REPO_DIR/desktop/.build/artifacts/sparkle/Sparkle}"
GENERATE_APPCAST="$SPARKLE_ROOT/bin/generate_appcast"

if [[ $# != 2 || ! -d "$UPDATES_DIR" || ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Usage: $0 [--preview] /path/to/dmg-archives VERSION" >&2
  exit 2
fi

if [[ ! -x "$GENERATE_APPCAST" ]]; then
  echo "Sparkle tools not found at $GENERATE_APPCAST" >&2
  echo "Run: swift package resolve --package-path desktop" >&2
  exit 1
fi

shopt -s nullglob
archives=("$UPDATES_DIR"/*.dmg)
# Each invocation publishes one GitHub tag. Older entries may remain in
# appcast.xml, but older archives must not acquire this version's URL prefix.
[[ ${#archives[@]} == 1 && "$(basename "${archives[0]}")" == "Needle-$VERSION.dmg" ]] || {
  echo "Use a directory containing only Needle-$VERSION.dmg and the existing appcast.xml." >&2
  exit 1
}
for archive in "${archives[@]}"; do
  if [[ "$PREVIEW" == 1 ]]; then
    # An ad-hoc DMG itself is not a code object. Validate the app code inside
    # it and require the expected ad-hoc identity before generating a feed.
    mount_point=""
    cleanup_mount() {
      if [[ -n "$mount_point" ]]; then
        hdiutil detach "$mount_point" >/dev/null 2>&1 || true
        mount_point=""
      fi
    }
    trap cleanup_mount EXIT
    mount_output="$(hdiutil attach -plist -readonly -nobrowse "$archive")"
    mount_point="$(printf '%s' "$mount_output" | python3 -c 'import plistlib, sys
data = plistlib.loads(sys.stdin.buffer.read())
for entity in data.get("system-entities", []):
    path = entity.get("mount-point")
    if path:
        print(path)
        break
')"
    [[ -n "$mount_point" && -d "$mount_point/Needle.app" ]] || {
      echo "Preview archive does not contain Needle.app: $archive" >&2; exit 1;
    }
    preview_app="$mount_point/Needle.app"
    codesign --verify --deep --strict "$preview_app"
    signature_details="$(codesign -dv "$preview_app" 2>&1)"
    grep -q '^Signature=adhoc$' <<< "$signature_details" || {
      echo "Preview update must contain an ad-hoc signed Needle.app: $archive" >&2; exit 1;
    }
    python3 - "$preview_app/Contents/Info.plist" "$VERSION" "$REPO_DIR/desktop/Resources/UpdatePublicKey.txt" <<'PY'
import plistlib, sys
info = plistlib.load(open(sys.argv[1], 'rb'))
expected_key = ''.join(open(sys.argv[3]).read().split())
checks = {
    "CFBundleShortVersionString": sys.argv[2],
    "CFBundleVersion": str(int(sys.argv[2].split('.')[0]) * 1000000 + int(sys.argv[2].split('.')[1]) * 1000 + int(sys.argv[2].split('.')[2])),
    "SUFeedURL": "https://raw.githubusercontent.com/icebli/needle/main/appcast.xml",
    "SUPublicEDKey": expected_key,
}
for key, expected in checks.items():
    if info.get(key) != expected:
        raise SystemExit(f"preview bundle metadata mismatch for {key}")
if info.get("SUVerifyUpdateBeforeExtraction") is not True:
    raise SystemExit("preview bundle must require verification before extraction")
PY
    cleanup_mount
    trap - EXIT
  else
    codesign --verify --strict "$archive"
    signature_details="$(codesign -dv "$archive" 2>&1)"
    grep -q 'Authority=Developer ID Application:' <<< "$signature_details" || {
      echo "Update archives require Developer ID signatures: $archive" >&2; exit 1;
    }
    xcrun stapler validate "$archive"
    spctl --assess --type open --context context:primary-signature "$archive"
  fi
done
"$GENERATE_APPCAST" --account dev.tege.needle.updates \
  --download-url-prefix "https://github.com/icebli/needle/releases/download/v$VERSION/" "$UPDATES_DIR"
if [[ "$PREVIEW" == 1 ]]; then
  appcast="$UPDATES_DIR/appcast.xml"
  python3 - "$appcast" "$VERSION" "${archives[0]}" <<'PY'
import base64, pathlib, sys
import xml.etree.ElementTree as ET
path = pathlib.Path(sys.argv[1])
version = sys.argv[2]
archive = pathlib.Path(sys.argv[3])
parts = version.split('.')
build_version = str(int(parts[0]) * 1000000 + int(parts[1]) * 1000 + int(parts[2]))
if not path.is_file():
    raise SystemExit(f"Preview appcast missing: {path}")
ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
root = ET.parse(path).getroot()
for item in root.findall(".//item"):
    if item.findtext("sparkle:version", namespaces=ns) != build_version:
        continue
    if item.findtext("sparkle:shortVersionString", namespaces=ns) != version:
        continue
    enclosure = item.find("enclosure")
    if enclosure is None:
        continue
    # Sparkle's sparkle:edSignature attribute is represented by ElementTree
    # using its Clark-notation namespace key.
    signature = enclosure.get("{%s}edSignature" % ns["sparkle"], "")
    url = enclosure.get("url", "")
    length = enclosure.get("length", "")
    try:
        decoded = base64.b64decode(signature, validate=True)
        valid_length = int(length) == archive.stat().st_size
    except (ValueError, TypeError):
        valid_length = False
        decoded = b""
    expected_url = f"https://github.com/icebli/needle/releases/download/v{version}/Needle-{version}.dmg"
    if url == expected_url and len(decoded) == 64 and valid_length:
        break
else:
    raise SystemExit(f"Preview appcast has no valid Ed25519 enclosure for {version}")
PY
fi
