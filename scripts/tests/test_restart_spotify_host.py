import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch, Mock

spec = importlib.util.spec_from_file_location("restart_spotify_host", Path(__file__).parents[1] / "restart-spotify-host.py")
host = importlib.util.module_from_spec(spec)
spec.loader.exec_module(host)


class RestartHostTests(unittest.TestCase):
    def test_unrelated_executable_is_never_signalled(self):
        with patch.object(host, "listener_pids", return_value=[42]), patch.object(host, "executable_path", return_value="/other/server"), patch.object(host.os, "kill") as kill:
            with self.assertRaisesRegex(RuntimeError, "unrecognized executable"):
                host.restart("/installed/needle-browser-host", {"/installed/needle-browser-host"})
            kill.assert_not_called()

    def test_native_messaging_or_other_user_process_is_not_terminated(self):
        for uid, command in [(99999, "/installed/needle-browser-host serve"), (host.os.getuid(), "/installed/needle-browser-host")]:
            with self.subTest(uid=uid, command=command), patch.object(host, "executable_path", return_value="/installed/needle-browser-host"), patch.object(host.subprocess, "run", return_value=Mock(stdout=f" {uid} Thu Oct 29 12:00:00 2026 {command}\n")):
                with self.assertRaisesRegex(RuntimeError, "exact Needle serve"):
                    host.identity(42, {"/installed/needle-browser-host"})

    def test_verified_listener_is_revalidated_then_replaced_and_protocol_checked(self):
        expected = ("/installed/needle-browser-host", "same identity")
        with patch.object(host, "listener_pids", side_effect=[[42], [], [84]]), patch.object(host, "identity", return_value=expected) as identity, patch.object(host.os, "kill") as kill, patch.object(host.subprocess, "Popen") as launch, patch.object(host, "protocol_ready", return_value=True):
            launch.return_value.pid = 84
            launch.return_value.poll.return_value = None
            host.restart("/installed/needle-browser-host", {"/installed/needle-browser-host"})
            self.assertEqual(identity.call_count, 3)
            kill.assert_called_once_with(42, host.signal.SIGTERM)
            self.assertEqual(launch.call_args.args[0], ["/installed/needle-browser-host", "serve"])

    def test_pid_identity_change_is_never_signalled(self):
        with patch.object(host, "listener_pids", return_value=[42]), patch.object(host, "identity", side_effect=[("host", "one"), ("host", "two")]), patch.object(host.os, "kill") as kill:
            with self.assertRaisesRegex(RuntimeError, "changed during installation"):
                host.restart("host", {"host"})
            kill.assert_not_called()

    def test_exited_child_never_passes_from_some_other_ready_server(self):
        with patch.object(host, "listener_pids", side_effect=[[], []]), patch.object(host.subprocess, "Popen") as launch, patch.object(host, "protocol_ready", return_value=True):
            launch.return_value.poll.return_value = 0
            with self.assertRaisesRegex(RuntimeError, "did not confirm"):
                host.restart("/installed/needle-browser-host", {"/installed/needle-browser-host"})

    def test_ready_protocol_from_unrelated_listener_does_not_prove_upgrade(self):
        with patch.object(host, "listener_pids", side_effect=[[], [], [999]]), patch.object(host.subprocess, "Popen") as launch, patch.object(host, "protocol_ready", return_value=True):
            launch.return_value.pid = 84
            launch.return_value.poll.return_value = None
            with self.assertRaisesRegex(RuntimeError, "listener changed"):
                host.restart("/installed/needle-browser-host", {"/installed/needle-browser-host"})

    def test_macos_identity_accepts_exact_installed_path_with_spaces(self):
        path = "/example/Library/Application Support/Needle/bin/needle-browser-host"
        record = f"{host.os.getuid()} Thu Oct 29 12:00:00 2026 {path} serve"
        with patch.object(host, "executable_path", return_value=path), patch.object(host.subprocess, "run", return_value=Mock(stdout=record)):
            self.assertEqual(host.identity(84, {path}), (path, record))


if __name__ == "__main__":
    unittest.main()
