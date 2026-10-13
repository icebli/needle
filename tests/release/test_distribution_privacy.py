import importlib.util
import os
import pathlib
import subprocess
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("audit", pathlib.Path(__file__).parents[2] / "scripts/audit-distribution.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class PrivacyTests(unittest.TestCase):
    def check(self, name, content):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
            return MODULE.audit(root)

    def test_public_identifiers_and_loopback_are_allowed(self):
        self.assertEqual(self.check("source.txt", "needle@tege.dev needle@example.com 127.0.0.1 icon_16x16@2x.png"), [])

    def test_personal_email_is_rejected_without_echoing_value(self):
        address = "person" + "@" + "private.test"
        errors = self.check("source.txt", address)
        self.assertTrue(errors)
        self.assertNotIn(address, " ".join(errors))

    def test_private_path_and_network_are_rejected(self):
        for content in ("/" + "Users/person/file", "192" + ".168.1.2", "10" + ".25.8.4", "172" + ".20.1.2"):
            self.assertTrue(self.check("source.txt", content))

    def test_internal_tracker_is_rejected(self):
        self.assertTrue(self.check(".beads/config.json", "{}"))

    def make_repository(self):
        folder = tempfile.TemporaryDirectory()
        root = pathlib.Path(folder.name)
        subprocess.run(["git", "init", "-q", str(root)], check=True)
        subprocess.run(["git", "-C", str(root), "config", "user.name", "Needle releases"], check=True)
        subprocess.run(["git", "-C", str(root), "config", "user.email", "releases@needle.invalid"], check=True)
        return folder, root

    def commit(self, root, path, content, *, committer=None):
        target = root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content)
        subprocess.run(["git", "-C", str(root), "add", path], check=True)
        environment = os.environ.copy()
        if committer:
            environment.update({"GIT_COMMITTER_NAME": committer[0], "GIT_COMMITTER_EMAIL": committer[1]})
        subprocess.run(["git", "-C", str(root), "commit", "-q", "-m", "snapshot"], check=True, env=environment)

    def test_empty_repository_history_is_allowed(self):
        folder, root = self.make_repository()
        self.addCleanup(folder.cleanup)
        self.assertEqual(MODULE.audit_history(root), [])

    def test_removed_internal_file_remains_rejected_in_history(self):
        folder, root = self.make_repository()
        self.addCleanup(folder.cleanup)
        self.commit(root, ".beads/config.yaml", "internal")
        subprocess.run(["git", "-C", str(root), "rm", "-q", ".beads/config.yaml"], check=True)
        subprocess.run(["git", "-C", str(root), "commit", "-q", "-m", "remove internal file"], check=True)
        errors = MODULE.audit_history(root)
        self.assertTrue(any("internal development file" in error for error in errors))

    def test_private_committer_identity_is_rejected(self):
        folder, root = self.make_repository()
        self.addCleanup(folder.cleanup)
        self.commit(root, "README.md", "public", committer=("Private committer", "person" + "@" + "private.test"))
        self.assertIn("history: unreviewed author or committer identity", MODULE.audit_history(root))

    def test_private_annotated_tag_identity_is_rejected(self):
        folder, root = self.make_repository()
        self.addCleanup(folder.cleanup)
        self.commit(root, "README.md", "public")
        environment = os.environ.copy()
        environment.update({"GIT_COMMITTER_NAME": "Private tagger", "GIT_COMMITTER_EMAIL": "tagger" + "@" + "private.test"})
        subprocess.run(["git", "-C", str(root), "tag", "-a", "v0.2.0", "-m", "release"], check=True, env=environment)
        self.assertIn("history: unreviewed tagger identity", MODULE.audit_history(root))


if __name__ == "__main__":
    unittest.main()
