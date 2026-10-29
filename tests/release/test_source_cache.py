"""Exercise the release collector's embedded Python without Homebrew or network."""
import ast
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import textwrap
import unittest
from unittest import mock
import urllib.error


ROOT = Path(__file__).resolve().parents[2]


def collector_helpers():
    script = (ROOT / "scripts/collect-third-party-sources.sh").read_text()
    python = script.split("python3 - <<'PY'\n", 1)[1].rsplit("\nPY", 1)[0]
    tree = ast.parse(python)
    tree.body = [node for node in tree.body if isinstance(node, (ast.Import, ast.ImportFrom, ast.FunctionDef))]
    namespace = {}
    exec(compile(tree, "collect-third-party-sources.sh", "exec"), namespace)
    return namespace


def cache_restore_step():
    workflow = (ROOT / ".github/workflows/release.yml").read_text()
    step = workflow.split("      - name: Restore optional published source cache\n", 1)[1]
    step = step.split("      - name:", 1)[0].split("        run: |\n", 1)[1]
    return textwrap.dedent(step)


class SourceCacheTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.cache = self.root / "cache"
        self.cache.mkdir()
        self.target = self.root / "package.tar.gz"
        self.content = b"verified source archive"
        self.expected = hashlib.sha256(self.content).hexdigest()
        self.helpers = collector_helpers()
        self.environment = mock.patch.dict(os.environ, NEEDLE_SOURCE_CACHE=str(self.cache))
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.network = mock.patch.object(self.helpers["urllib"].request, "urlopen")
        self.urlopen = self.network.start()
        self.addCleanup(self.network.stop)
        self.sleep_patch = mock.patch.object(self.helpers["time"], "sleep")
        self.sleep = self.sleep_patch.start()
        self.addCleanup(self.sleep_patch.stop)

    def download(self, expected=None):
        return self.helpers["download_verified"]("https://example.test/source", self.target, expected)

    def test_matching_checksum_cache_avoids_network(self):
        (self.cache / self.target.name).write_bytes(self.content)
        self.assertEqual(self.download(self.expected), (self.expected, self.expected))
        self.assertEqual(self.target.read_bytes(), self.content)
        self.urlopen.assert_not_called()

    def test_corrupt_cache_is_refetched_and_verified(self):
        (self.cache / self.target.name).write_bytes(b"corrupt cached archive")
        self.urlopen.return_value = io.BytesIO(self.content)
        with mock.patch("sys.stderr", new=io.StringIO()):
            self.assertEqual(self.download(self.expected), (self.expected, self.expected))
        self.assertEqual(self.target.read_bytes(), self.content)
        self.urlopen.assert_called_once()

    def test_corrupt_cache_and_unavailable_network_fail_after_three_attempts(self):
        (self.cache / self.target.name).write_bytes(b"corrupt cached archive")
        self.urlopen.side_effect = urllib.error.URLError("offline")
        with mock.patch("sys.stderr", new=io.StringIO()), self.assertRaises(urllib.error.URLError):
            self.download(self.expected)
        self.assertEqual(self.urlopen.call_count, 3)
        self.assertEqual(self.sleep.call_args_list, [mock.call(1), mock.call(2)])
        self.assertFalse(self.target.exists())

    def test_cache_is_ignored_without_expected_checksum(self):
        (self.cache / self.target.name).write_bytes(b"unverified cache")
        self.urlopen.return_value = io.BytesIO(self.content)
        self.assertEqual(self.download(), (self.expected, None))
        self.assertEqual(self.target.read_bytes(), self.content)
        self.urlopen.assert_called_once()

    def test_network_checksum_mismatch_fails_and_removes_download(self):
        self.urlopen.return_value = io.BytesIO(b"wrong upstream archive")
        with self.assertRaisesRegex(SystemExit, "source checksum mismatch"):
            self.download(self.expected)
        self.urlopen.assert_called_once()
        self.assertFalse(self.target.exists())

    def test_transient_url_failure_retries_before_success(self):
        self.urlopen.side_effect = [urllib.error.URLError("connection reset"), io.BytesIO(self.content)]
        self.assertEqual(self.download(self.expected), (self.expected, self.expected))
        self.assertEqual(self.urlopen.call_count, 2)
        self.sleep.assert_called_once_with(1)

    def test_partial_transfer_is_discarded_before_retry(self):
        response = mock.MagicMock()
        response.__enter__.return_value.read.side_effect = [b"partial", ConnectionResetError("reset")]
        self.urlopen.side_effect = [response, io.BytesIO(self.content)]
        self.assertEqual(self.download(self.expected), (self.expected, self.expected))
        self.assertEqual(self.target.read_bytes(), self.content)
        self.assertEqual(self.urlopen.call_count, 2)

    def test_pypi_checks_metadata_before_reusing_cached_archive(self):
        (self.cache / self.target.name).write_bytes(self.content)
        metadata = {"urls": [{"packagetype": "sdist", "url": "https://example.test/sdist",
                              "digests": {"sha256": self.expected}}]}
        self.urlopen.return_value = io.BytesIO(json.dumps(metadata).encode())
        self.assertEqual(self.helpers["download_pypi"]("package", "1.0", self.target),
                         (self.expected, self.expected))
        self.urlopen.assert_called_once()
        self.assertEqual(self.urlopen.call_args.args[0].full_url, "https://pypi.org/pypi/package/1.0/json")

    def test_without_configured_cache_uses_verified_download(self):
        os.environ.pop("NEEDLE_SOURCE_CACHE", None)
        self.urlopen.return_value = io.BytesIO(self.content)
        self.assertEqual(self.download(self.expected), (self.expected, self.expected))
        self.urlopen.assert_called_once()


class SourceCacheRestoreTests(unittest.TestCase):
    def test_optional_cache_404_continues_to_upstream_collection(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            curl = root / "curl"
            curl.write_text("#!/bin/sh\nexit 22\n")
            curl.chmod(0o755)
            step = cache_restore_step().replace("${{ github.repository }}", "icebli/needle")
            result = subprocess.run(["bash", "-e", "-c", step], capture_output=True, text=True,
                                    env=dict(os.environ, PATH=f"{root}:{os.environ['PATH']}",
                                             RUNNER_TEMP=str(root), NEEDLE_SOURCE_CACHE=str(root / "cache")))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("cache unavailable; collection will fetch upstream", result.stdout)

    def restore(self, members):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        root = Path(directory.name)
        archive, cache = root / "previous.tar.gz", root / "cache"
        cache.mkdir()
        with tarfile.open(archive, "w:gz") as tar:
            for name, content, kind in members:
                member = tarfile.TarInfo(name)
                member.type = kind
                if kind == tarfile.REGTYPE:
                    member.size = len(content)
                    tar.addfile(member, io.BytesIO(content))
                else:
                    member.linkname = "../../outside"
                    tar.addfile(member)
        python = cache_restore_step().split("<<'PY'\n", 1)[1].split("\nPY", 1)[0]
        result = subprocess.run(["python3", "-", str(archive), str(cache)], input=python,
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return root, cache, result.stdout

    def test_restore_copies_only_regular_source_archives(self):
        _, cache, output = self.restore([
            ("./sources/package.tar.gz", b"source", tarfile.REGTYPE),
            ("./licenses/LICENSE", b"license", tarfile.REGTYPE),
        ])
        self.assertEqual([item.name for item in cache.iterdir()], ["package.tar.gz"])
        self.assertEqual((cache / "package.tar.gz").read_bytes(), b"source")
        self.assertIn("Restored 1 optional source archives", output)

    def test_restore_rejects_traversal_and_links_without_writing_sources(self):
        for name, kind in [("sources/../../outside", tarfile.REGTYPE),
                           ("/sources/outside", tarfile.REGTYPE),
                           ("sources/package.tar.gz", tarfile.SYMTYPE),
                           ("sources/package.tar.gz", tarfile.LNKTYPE)]:
            with self.subTest(name=name, kind=kind):
                root, cache, output = self.restore([
                    ("sources/valid.tar.gz", b"source", tarfile.REGTYPE),
                    (name, b"untrusted", kind),
                ])
                self.assertFalse((root / "outside").exists())
                self.assertEqual(list(cache.iterdir()), [])
                self.assertIn("Published source cache unavailable", output)


if __name__ == "__main__":
    unittest.main()
