#!/usr/bin/env bash
set -euo pipefail
if [[ $# != 2 || "$1" != *.dmg || ! -f "$1" ]]; then
  echo "Usage: scripts/notarize-release.sh DMG KEYCHAIN_PROFILE" >&2
  exit 2
fi
artifact="$1"
profile="$2"
# Credentials belong in a notarytool keychain profile, never in this repository.
codesign --verify --strict "$artifact"
codesign -dv --verbose=4 "$artifact" 2>&1 | grep -q 'Authority=Developer ID Application:' || {
  echo "DMG must be signed with Developer ID Application before notarization." >&2
  exit 1
}
receipt="$(mktemp "${TMPDIR:-/tmp}/needle-notary.XXXXXX")"
trap 'rm -f "$receipt"' EXIT
xcrun notarytool submit "$artifact" --keychain-profile "$profile" --wait --output-format json > "$receipt"
[[ "$(plutil -extract status raw -o - "$receipt")" == Accepted ]] || {
  cat "$receipt" >&2
  echo "Apple did not accept this artifact. Inspect the submission log before continuing." >&2
  exit 1
}
xcrun stapler staple "$artifact"
xcrun stapler validate "$artifact"
spctl --assess --type open --context context:primary-signature --verbose "$artifact"
echo "Notarization and Gatekeeper assessment passed: $artifact"
