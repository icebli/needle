#!/usr/bin/env bash
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
swift build --package-path "$REPO_DIR/desktop"
swift test --package-path "$REPO_DIR/desktop" "$@"
