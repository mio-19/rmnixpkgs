"""Runtime regression tests; hardware commands are mocked explicitly."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


class RuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.parent = Path(self.temp.name)
        meta = self.parent / "metadata.json"
        meta.write_text(json.dumps({"tools": "/nix/store/test-tools", "caBundle": "/nix/store/test-ca",
                                    "bridge": "/nix/store/test-bridge", "quill": "/nix/store/test-quill",
                                    "kernelRelease": "test-waydroid", "osVersion": "test"}))
        with patch.dict(os.environ, RMPP_ANDROID_META=str(meta)):
            spec = importlib.util.spec_from_file_location("runtime", Path(__file__).with_name("android.py"))
            self.runtime = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(self.runtime)
        self.runtime.RESOLV_CONF = self.parent / "resolv.conf"
        self.runtime.RESOLV_CONF.write_text("nameserver 127.0.0.1\n")
        self.runtime.STATE = self.parent / "state"
        self.runtime.ROOT = self.runtime.STATE / "rootfs"

    def test_prepare_is_owned_persistent_and_idempotent(self):
        runtime = self.runtime
        runtime.prepare()
        machine_id = (runtime.ROOT / "etc/machine-id").read_text()
        runtime.prepare()
        self.assertEqual((runtime.ROOT / "etc/machine-id").read_text(), machine_id)
        self.assertEqual(os.readlink(runtime.ROOT / "bin"), "/nix/store/test-tools/bin")
        manifest = set((runtime.STATE / "manifest").read_text().splitlines())
        for path in runtime.ROOT.rglob("*"):
            self.assertIn(str(path), manifest)
        self.assertEqual(runtime.STATE.stat().st_mode & 0o777, 0o700)

    def test_foreign_root_is_not_adopted(self):
        self.runtime.STATE.mkdir()
        foreign = self.runtime.STATE / "foreign"
        foreign.write_text("keep")
        with self.assertRaisesRegex(RuntimeError, "foreign"):
            self.runtime.prepare()
        self.assertEqual(foreign.read_text(), "keep")

    def test_gpu_configuration_preserves_downloaded_image_settings(self):
        path = self.parent / "waydroid.cfg"
        path.write_text("[waydroid]\narch=arm64\nimages_path=/var/lib/waydroid/images\n[properties]\npersist.sys.test=keep\n")
        self.runtime.configure_gpu(path)
        config = self.runtime.configparser.ConfigParser()
        config.read(path)
        self.assertEqual(config["waydroid"]["arch"], "arm64")
        self.assertEqual(config["properties"]["persist.sys.test"], "keep")
        self.assertEqual(config["properties"]["ro.hardware.egl"], "mesa")
        self.assertEqual(config["properties"]["gralloc.gbm.device"], "/dev/dri/renderD128")

    def test_recovery_refuses_live_owned_processes(self):
        runtime = self.runtime
        runtime.prepare()
        flag = runtime.STATE / "restore-xochitl"
        flag.write_text("test-session")
        with patch.object(runtime, "session_processes", return_value=[123]), patch.object(runtime, "run") as run, patch.object(runtime, "power_lock") as power:
            with self.assertRaisesRegex(RuntimeError, "live panel owner"):
                runtime.recover()
            run.assert_not_called()
            power.assert_not_called()
        self.assertTrue(flag.exists())
        with patch.object(runtime, "session_processes", return_value=[]), patch.object(runtime, "run") as run, patch.object(runtime, "power_lock") as power:
            runtime.recover()
            run.assert_called_once_with("systemctl", "start", "xochitl")
            power.assert_called_once_with(False)
        self.assertFalse(flag.exists())

    def test_teardown_releases_bridge_before_namespace_and_stock_ui(self):
        runtime = self.runtime
        runtime.prepare()
        (runtime.ROOT / "var/lib/waydroid/waydroid.cfg").touch()
        events = []
        class Process:
            pid = 987
            returncode = None
            def poll(self):
                return self.returncode
            def terminate(self):
                events.append("bridge terminate")
                self.returncode = 0
            def wait(self, timeout=None):
                events.append("bridge reaped")
                return 0
        session, bridge = Process(), Process()
        def popen(command, **kwargs):
            if "_namespace" in command:
                (runtime.ROOT / "run/rmpp-session-ready").touch()
                return session
            return bridge
        def command(*args, **kwargs):
            if args[:3] == ("systemctl", "stop", "xochitl"):
                events.append("stock stopped")
            return runtime.subprocess.CompletedProcess(args, 1 if args[:2] == ("ip", "link") else 0, stdout=b"")
        def inside(pid, *args, **kwargs):
            return runtime.subprocess.CompletedProcess(args, 0, stdout=b"1")
        with patch.object(runtime, "check_device"), patch.object(runtime, "power_lock"), patch.object(runtime, "run", side_effect=command), patch.object(runtime.subprocess, "Popen", side_effect=popen), patch.object(runtime, "inside", side_effect=inside), patch.object(runtime.time, "sleep"), patch.object(runtime, "terminate", side_effect=lambda *a, **k: events.append("namespace stopped")), patch.object(runtime, "recover", side_effect=lambda: events.append("stock restored")):
            runtime.takeover()
        self.assertEqual(events, ["stock stopped", "bridge terminate", "bridge reaped", "namespace stopped", "stock restored"])

    def test_internal_command_refuses_host_mount_namespace(self):
        with patch.object(self.runtime.os, "readlink", return_value="mnt:[123]"), patch.object(self.runtime, "run") as run:
            with self.assertRaisesRegex(RuntimeError, "separate mount namespace"):
                self.runtime.enter_root()
            run.assert_not_called()

    def test_mount_namespace_is_private_and_exec_preserves_arguments(self):
        command = self.runtime.namespace_command("init", "-s", "VANILLA")
        self.assertEqual(command[:5], ["unshare", "--mount", "--propagation", "private", "--"])
        self.assertEqual(command[-4:], ["_namespace", "init", "-s", "VANILLA"])


if __name__ == "__main__":
    unittest.main()
