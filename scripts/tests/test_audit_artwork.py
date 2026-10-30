import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("audit_artwork", Path(__file__).parents[1] / "audit-artwork.py")
audit_artwork = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit_artwork)


class ArtworkAuditTests(unittest.TestCase):
    def test_timeout_and_invalid_output_remain_explicit_row_errors(self):
        with patch.object(audit_artwork.subprocess, "run", side_effect=subprocess.TimeoutExpired("needle", 90)):
            self.assertEqual(audit_artwork.run_json("needle", []), {"status": "error", "reason": "cli_timeout"})
        for text in ["", "not json", "[]"]:
            with patch.object(audit_artwork.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, text, "")):
                self.assertEqual(audit_artwork.run_json("needle", []), {"status": "error", "reason": "invalid_cli_json"})

    def test_every_lookup_is_read_only_and_missing_reasons_are_counted(self):
        tracks = [{"path": "/music/a.mp3", "artist": "A", "title": "Song", "album": "Album"},
                  {"path": "/music/b.mp3", "artist": "B", "title": "Other"}]
        replies = [{"ok": True, "tracks": tracks}, {"status": "matched", "artwork": {"url": "cover"}},
                   {"status": "unmatched", "reason": "source_identity_or_filename_conflict"}]
        with patch.object(audit_artwork, "run_json", side_effect=replies) as run, \
             patch.object(audit_artwork.time, "sleep"):
            result = audit_artwork.audit("needle", Path("/music"), None)
        self.assertEqual(result["summary"], {"matched": 1, "unmatched": 1})
        self.assertEqual(result["miss_reasons"], {"source_identity_or_filename_conflict": 1})
        for call in run.call_args_list[1:]:
            self.assertIn("--dry-run", call.args[1])
            self.assertIn("--path", call.args[1])

    def test_bookmarks_keep_source_identity_and_existing_covers(self):
        bookmarks = [{"id": "one", "artist": "A", "title": "Song", "album": "",
                      "candidate": {"title": "A - Song (Remix)"}},
                     {"id": "two", "artist": "B", "title": "Other", "artwork": {"url": "existing"}}]
        with tempfile.TemporaryDirectory() as root:
            preferences = Path(root) / "preferences.plist"
            preferences.write_bytes(plistlib.dumps({"needle.bookmarks": json.dumps(bookmarks).encode()}))
            before = preferences.read_bytes()
            with patch.object(audit_artwork, "run_json", side_effect=[{"ok": True, "tracks": []},
                             {"status": "unmatched", "reason": "catalog"}]) as run, \
                 patch.object(audit_artwork.time, "sleep"):
                result = audit_artwork.audit("needle", Path(root), preferences)
            self.assertEqual(preferences.read_bytes(), before)
        self.assertEqual(result["summary"], {"unmatched": 1, "existing": 1})
        args = run.call_args_list[1].args[1]
        self.assertEqual(args[args.index("--source-title") + 1], "A - Song (Remix)")
        self.assertIn("--dry-run", args)
        self.assertNotIn("--path", args)

    def test_failed_inventory_cannot_report_successful_coverage(self):
        with patch.object(audit_artwork, "run_json", return_value={"status": "error", "reason": "failed"}):
            with self.assertRaises(RuntimeError):
                audit_artwork.audit("needle", Path("/music"), None)


if __name__ == "__main__":
    unittest.main()
