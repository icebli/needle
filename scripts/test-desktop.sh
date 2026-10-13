#!/usr/bin/env bash
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
swift build --package-path "$REPO_DIR/desktop"
BIN_DIR="$(swift build --package-path "$REPO_DIR/desktop" --show-bin-path)"
FRAMEWORK="$REPO_DIR/desktop/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
# SwiftPM test runners search this rpath for binary framework dependencies.
mkdir -p "$BIN_DIR/PackageFrameworks"
ditto "$FRAMEWORK" "$BIN_DIR/PackageFrameworks/Sparkle.framework"
swift test --package-path "$REPO_DIR/desktop" "$@"
