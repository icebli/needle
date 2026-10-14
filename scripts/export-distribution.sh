#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
REPO_DIR="$PWD"
if [[ $# -lt 1 || $# -gt 2 || ! "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ( $# == 2 && "$2" != --check && "$2" != --feed-only && "$2" != --docs-only && "$2" != --source-only ) ]]; then
  echo "Usage: scripts/export-distribution.sh VERSION [--check|--feed-only|--docs-only|--source-only]" >&2
  exit 2
fi
version="$1"
tag="v$version"
source_commit="$(git rev-parse HEAD)"
github_url="$(git remote get-url github)"
[[ "$github_url" == https://github.com/icebli/needle.git ]] || {
  echo "Unexpected distribution destination; inspect the github remote." >&2; exit 1;
}
git cat-file -e "HEAD:docs/releases/$tag.md"
scanner="${NEEDLE_GITLEAKS:-$(command -v gitleaks || true)}"
[[ -n "$scanner" && -x "$scanner" ]] || {
  echo "A verified Gitleaks executable is required. Set NEEDLE_GITLEAKS to its absolute path." >&2; exit 1;
}
scanner="$(cd "$(dirname "$scanner")" && pwd)/$(basename "$scanner")"
stage="$(mktemp -d "${TMPDIR:-/tmp}/needle-distribution.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
git clone --quiet "$github_url" "$stage/repo"
python3 scripts/audit-distribution.py --history "$stage/repo"
if [[ -n "$(git -C "$stage/repo" branch --show-current)" ]]; then
  git -C "$stage/repo" checkout -B main
fi

if [[ "${2:-}" == --feed-only || "${2:-}" == --docs-only ]]; then
  # Maintenance copies a fixed allowlist; existing release tags are immutable.
  files=(appcast.xml)
  message="Update Sparkle appcast"
  if [[ "$2" == --docs-only ]]; then
    files=(README.md CHANGELOG.md docs/GETTING_STARTED.md docs/CLI.md docs/desktop.md docs/browser-extension.md)
    while IFS= read -r file; do files+=("$file"); done < <(git ls-tree -r --name-only "$source_commit" docs/releases)
    git -C "$stage/repo" rm -f --ignore-unmatch -- docs/RELEASING.md docs/QA.md docs/architecture.md docs/THIRD_PARTY_RELEASE.md >/dev/null
    message="Update release guides"
  fi
  for file in "${files[@]}"; do
    git show "$source_commit:$file" > "$stage/repo/$file"
  done
  "$scanner" dir --config "$REPO_DIR/.gitleaks.toml" --redact --no-banner "$stage/repo"
  python3 scripts/audit-distribution.py "$stage/repo"
  cd "$stage/repo"
  git config user.name 'Needle releases'
  git config user.email 'releases@needle.invalid'
  git add -- "${files[@]}"
  # Include removals of maintainer-only documentation.
  if [[ "$2" == --docs-only ]]; then git add -u -- docs; fi
  if git diff --cached --quiet; then
    echo "GitHub maintenance files already match; no remote changes made."
    exit 0
  fi
  git commit --quiet -m "$message"
  git push origin main
  echo "Published audited maintenance files; existing GitHub tags were not changed."
  exit 0
fi

git -C "$stage/repo" rm -r -f --ignore-unmatch -- . >/dev/null
# Export only committed, public-facing source. Development trackers, agent
# configuration, private commit messages and original author emails stay local.
git archive "$source_commit" Cargo.toml Cargo.lock LICENSE README.md CHANGELOG.md \
  .gitignore .gitleaks.toml .github appcast.xml assets crates desktop docs tests scripts browser-extension native-host spicetify \
  | tar -xf - -C "$stage/repo"
# Maintainer remote/export instructions are local operational guidance.
# The sharing repository contains reader-facing guides and source only.
rm -f "$stage/repo/docs/RELEASING.md" "$stage/repo/docs/QA.md" \
  "$stage/repo/docs/architecture.md" "$stage/repo/docs/THIRD_PARTY_RELEASE.md"
"$scanner" dir --config "$REPO_DIR/.gitleaks.toml" --redact --no-banner "$stage/repo"
python3 scripts/audit-distribution.py "$stage/repo"
cd "$stage/repo"
git config user.name 'Needle releases'
git config user.email 'releases@needle.invalid'
git add --all
if ! git diff --cached --quiet; then
  git commit --quiet -m "Release source snapshot $tag"
fi
if [[ "${2:-}" == --source-only ]]; then
  "$scanner" git --config "$REPO_DIR/.gitleaks.toml" --redact --no-banner .
  python3 "$REPO_DIR/scripts/audit-distribution.py" --history .
  git push origin main
  echo "Published audited source maintenance; release tags unchanged."
  exit 0
fi
if git rev-parse "$tag" >/dev/null 2>&1; then
  [[ "$(git rev-list -n 1 "$tag")" == "$(git rev-parse HEAD)" ]] || {
    echo "Existing GitHub tag points to a different snapshot; do not move it." >&2; exit 1;
  }
else
  git tag -a "$tag" -m "Needle $version"
fi
"$scanner" git --config "$REPO_DIR/.gitleaks.toml" --redact --no-banner .
python3 "$REPO_DIR/scripts/audit-distribution.py" --history .
if [[ "${2:-}" == --check ]]; then
  echo "Privacy checks passed; no remote changes made."
  exit 0
fi
git push origin main "refs/tags/$tag"
echo "Published reviewed source snapshot $tag; Forgejo's history remains separate."
