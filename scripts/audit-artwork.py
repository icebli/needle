#!/usr/bin/env python3
"""Explain artwork coverage without modifying music, bookmarks, or preferences."""
import argparse
from collections import Counter
import json
from pathlib import Path
import plistlib
import subprocess
import time


def run_json(cli, arguments):
    try:
        result = subprocess.run([cli, *arguments], capture_output=True, text=True, timeout=90)
    except subprocess.TimeoutExpired:
        return {"status": "error", "reason": "cli_timeout"}
    if result.returncode:
        return {"status": "error", "reason": "cli_request_failed", "detail": result.stderr.strip()}
    try:
        value = json.loads(result.stdout.splitlines()[-1])
        if not isinstance(value, dict):
            raise ValueError("Expected a JSON object")
        return value
    except (IndexError, ValueError):
        return {"status": "error", "reason": "invalid_cli_json"}


def audit(cli, root, preferences):
    scan = run_json(cli, ["library-scan", str(root), "--json"])
    if scan.get("ok") is not True:
        raise RuntimeError(f"Library inventory failed: {scan}")
    rows = []
    jobs = [("file", item) for item in scan["tracks"]]
    if preferences and preferences.exists():
        with preferences.open("rb") as stream:
            saved = plistlib.load(stream).get("needle.bookmarks", b"[]")
        jobs += [("bookmark", item) for item in json.loads(saved)]
    for kind, item in jobs:
        row = {"kind": kind, "artist": item.get("artist"), "title": item.get("title"),
               "album": item.get("album"), "path": item.get("path"), "id": item.get("id")}
        if kind == "bookmark" and item.get("artwork"):
            result = {"status": "existing", "artwork": item["artwork"]}
        elif not row["artist"] or not row["title"]:
            result = {"status": "unmatched", "reason": "missing_artist_or_title"}
        else:
            args = ["artwork", "--artist", row["artist"], "--title", row["title"],
                    "--album", row["album"] or "", "--dry-run", "--json"]
            if kind == "file":
                args += ["--path", row["path"]]
            else:
                args += ["--source-title", item["candidate"]["title"]]
            result = run_json(cli, args)
            if result.get("status") != "existing":
                time.sleep(1.1)
        row["result"] = result
        rows.append(row)
        print(f"{len(rows)}/{len(jobs)} {row['artist']} - {row['title']}: {result['status']}", flush=True)
    return {"summary": dict(Counter(row["result"]["status"] for row in rows)),
            "miss_reasons": dict(Counter(row["result"].get("reason", "unknown") for row in rows
                                         if row["result"]["status"] in ("unmatched", "error"))),
            "inventory_warnings": scan.get("warnings", []), "rows": rows}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", default="needle")
    parser.add_argument("--root", type=Path, default=Path.home() / "Music/needle")
    parser.add_argument("--preferences", type=Path,
                        default=Path.home() / "Library/Preferences/dev.tege.needle.desktop.plist")
    parser.add_argument("--output", type=Path, required=True)
    options = parser.parse_args()
    report = audit(options.cli, options.root, options.preferences)
    options.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({key: report[key] for key in ("summary", "miss_reasons")}, indent=2))
