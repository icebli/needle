#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Distribution snapshots are explicit. Ordinary pushes continue to Forgejo.
if [[ $# != 1 || ! "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Usage: scripts/release.sh VERSION" >&2
  exit 2
fi
version="$1"
tag="v$version"
[[ "$(git branch --show-current)" == main ]] || { echo "Release from main." >&2; exit 1; }
[[ -z "$(git status --porcelain --untracked-files=no)" ]] || { echo "Commit or isolate tracked changes before releasing." >&2; exit 1; }
grep -q "^version = \"$version\"$" Cargo.toml || { echo "Cargo version does not match." >&2; exit 1; }
[[ -s "docs/releases/$tag.md" ]] || { echo "Missing curated docs/releases/$tag.md." >&2; exit 1; }
git cat-file -e "HEAD:docs/releases/$tag.md" || { echo "Release notes must be committed before tagging." >&2; exit 1; }
git remote get-url origin >/dev/null
github_url="$(git remote get-url github)"
[[ "$github_url" == https://github.com/icebli/needle.git ]] || { echo "Unexpected distribution destination; inspect the github remote." >&2; exit 1; }
if git rev-parse "$tag" >/dev/null 2>&1; then
  [[ "$(git rev-list -n 1 "$tag")" == "$(git rev-parse HEAD)" ]] || { echo "Tag already points to another commit." >&2; exit 1; }
else
  git tag -a "$tag" -m "Needle $version"
fi
git push origin main "refs/tags/$tag"
scripts/export-distribution.sh "$version"
echo "Published $tag to Forgejo and a curated snapshot to GitHub. GitHub Actions prepares a draft release for review."
