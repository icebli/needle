#!/usr/bin/env python3
"""Reject private metadata from a public source snapshot, alongside Gitleaks."""
import pathlib
import re
import io
import subprocess
import sys
import tarfile
import tempfile

# These are existing public integration identifiers and placeholder contacts.
PUBLIC_IDENTIFIERS = {"needle@tege.dev", "needle@example.com", "releases@needle.invalid"}
EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
PRIVATE = re.compile(r"/Us[e]rs/|forgejo\.lan\.|192\.168\.|10\.\d+\.\d+\.\d+|172\.(?:1[6-9]|2\d|3[01])\.")
INTERNAL = {".beads", ".claude", ".codex", ".fablize", ".codegraph", ".ruflo-prime.json", ".beads.gate.lock", "AGENTS.md", "CLAUDE.md", "plans"}


def audit(root: pathlib.Path) -> list[str]:
    failures = []
    for path in root.rglob("*"):
        relative = path.relative_to(root)
        if ".git" in relative.parts or not path.is_file():
            continue
        if any(part in INTERNAL for part in relative.parts):
            failures.append(f"{relative}: internal development file")
            continue
        try:
            content = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        if PRIVATE.search(content):
            failures.append(f"{relative}: private path or network address")
        addresses = set(EMAIL.findall(content))
        addresses -= PUBLIC_IDENTIFIERS
        # Apple's @2x icon resource filenames resemble email addresses.
        addresses = {value for value in addresses if not re.fullmatch(r"icon_\d+x\d+@2x\.png", value)}
        if addresses:
            failures.append(f"{relative}: unreviewed email-shaped value")
    return failures


# These already-public dependency maintenance commits are retained verbatim.
# New commits still require the release identity; all snapshots remain scanned.
REVIEWED_PUBLIC_COMMITS = frozenset({
    "72b015ddfa58a30b0fd94f28ee3034f2f647bf55",
    "76194986b1a5cb98779d435d691bed31b37c10a2",
    "7c7c430bf109002b77eece29fd16f4519fd427e9",
})


def audit_history(repository: pathlib.Path) -> list[str]:
    def git(*args):
        return subprocess.check_output(["git", "-C", str(repository), *args])

    failures = []
    identities = git("log", "--all", "--format=%H%x00%an%x00%ae%x00%cn%x00%ce").decode().splitlines()
    for entry in identities:
        revision, *values = entry.split("\0")
        if revision not in REVIEWED_PUBLIC_COMMITS and any(
            value not in {"Needle releases", "releases@needle.invalid"} for value in values
        ):
            failures.append("history: unreviewed author or committer identity")
            break
    tags = git("for-each-ref", "refs/tags", "--format=%(taggername)%0a%(taggeremail)").decode().splitlines()
    if any(value and value not in {"Needle releases", "<releases@needle.invalid>"} for value in tags):
        failures.append("history: unreviewed tagger identity")
    for revision in git("rev-list", "--all").decode().splitlines():
        if not git("ls-tree", "-r", "--name-only", revision).strip():
            continue
        with tempfile.TemporaryDirectory() as folder:
            contents = git("archive", "--format=tar", revision)
            if not contents:
                continue
            with tarfile.open(fileobj=io.BytesIO(contents)) as archive:
                archive.extractall(folder, filter="data")
            failures.extend(f"history {revision[:8]}: {error}" for error in audit(pathlib.Path(folder)))
    return failures


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--history":
        errors = audit_history(pathlib.Path(sys.argv[2]).resolve())
    elif len(sys.argv) == 2:
        errors = audit(pathlib.Path(sys.argv[1]).resolve())
    else:
        raise SystemExit("Usage: scripts/audit-distribution.py SOURCE_DIRECTORY | --history REPOSITORY")
    for error in errors:
        print(error, file=sys.stderr)
    raise SystemExit(1 if errors else 0)
