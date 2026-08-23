#!/usr/bin/env python3

import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).parent))

import smoke_e2e_runtime as runtime


class SmokeAppIdentityTests(unittest.TestCase):
    def setUp(self):
        self.root = pathlib.Path(
            tempfile.mkdtemp(prefix="pickvia-smoke-policy-", dir="/private/tmp")
        )
        self.app = self.root / "PickVia E2E.app"
        self.executable = self.app / "Contents" / "MacOS" / "PickVia"
        self.executable.parent.mkdir(parents=True)
        shutil.copyfile("/usr/bin/true", self.executable)
        self.executable.chmod(0o700)
        (self.app / "Contents" / "Info.plist").write_bytes(b"plist")
        resources = self.app / "Contents" / "Resources"
        resources.mkdir()
        (resources / "PickVia.icns").write_bytes(b"icon")
        (resources / "PickViaMenuBarTemplate.png").write_bytes(b"menu")
        signature = self.app / "Contents" / "_CodeSignature"
        signature.mkdir()
        (signature / "CodeResources").write_bytes(b"signature")

    def tearDown(self):
        shutil.rmtree(self.root)

    def test_relative_app_argument_becomes_absolute_physical_identity(self):
        relative = os.path.relpath(self.app, pathlib.Path.cwd())
        pinned = runtime.PinnedApplication.open(relative)
        try:
            self.assertEqual(pinned.path, self.app.resolve())
            self.assertTrue(pinned.validate())
        finally:
            pinned.close()

    def test_cli_canonicalizes_explicit_relative_app_argument(self):
        completed = subprocess.run(
            [
                sys.executable,
                str(pathlib.Path(runtime.__file__).resolve()),
                "canonical-app",
                os.path.relpath(self.app, self.root),
            ],
            cwd=self.root,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin"},
            timeout=3,
            check=False,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(completed.stdout, (str(self.app.resolve()) + "\n").encode())

    def test_cli_app_identity_changes_when_executable_is_replaced(self):
        command = [
            sys.executable,
            str(pathlib.Path(runtime.__file__).resolve()),
            "app-identity",
            str(self.app),
        ]
        before = subprocess.run(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin"},
            timeout=3,
            check=False,
        )
        self.executable.unlink()
        self.executable.write_bytes(b"replacement")
        self.executable.chmod(0o700)
        after = subprocess.run(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin"},
            timeout=3,
            check=False,
        )
        self.assertEqual((before.returncode, after.returncode), (0, 0))
        self.assertNotEqual(before.stdout, after.stdout)

    def test_cli_app_identity_changes_when_info_plist_is_modified(self):
        command = [
            sys.executable,
            str(pathlib.Path(runtime.__file__).resolve()),
            "app-identity",
            str(self.app),
        ]
        environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}
        before = subprocess.run(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment,
            timeout=3,
            check=False,
        )
        (self.app / "Contents" / "Info.plist").write_bytes(b"modified plist")
        after = subprocess.run(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment,
            timeout=3,
            check=False,
        )
        self.assertEqual((before.returncode, after.returncode), (0, 0))
        self.assertNotEqual(before.stdout, after.stdout)

    def test_cli_rejects_parent_secret_environment(self):
        completed = subprocess.run(
            [
                sys.executable,
                str(pathlib.Path(runtime.__file__).resolve()),
                "canonical-app",
                str(self.app),
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env={
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "LANG": "en_US.UTF-8",
                "LC_CTYPE": "UTF-8",
                "PICKVIA_PARENT_SENTINEL_SECRET": "must-not-enter-policy",
            },
            timeout=3,
            check=False,
        )
        self.assertNotEqual(completed.returncode, 0)
        self.assertEqual(completed.stdout, b"")
        self.assertEqual(completed.stderr, b"")

    def test_symlinked_app_argument_is_rejected(self):
        alias = self.root / "Alias.app"
        alias.symlink_to(self.app)
        with self.assertRaises(runtime.SmokePolicyError):
            runtime.PinnedApplication.open(alias)

    def test_replacement_after_pin_is_detected_before_launch(self):
        pinned = runtime.PinnedApplication.open(self.app)
        original = self.root / "original.app"
        try:
            self.app.rename(original)
            self.app.mkdir()
            self.assertFalse(pinned.validate())
        finally:
            pinned.close()


class PreferenceSnapshotTests(unittest.TestCase):
    def setUp(self):
        self.home = pathlib.Path(
            tempfile.mkdtemp(prefix="pickvia-smoke-preferences-", dir="/private/tmp")
        )
        self.preferences = self.home / "Library" / "Preferences"
        self.by_host = self.preferences / "ByHost"
        self.by_host.mkdir(parents=True)

    def tearDown(self):
        shutil.rmtree(self.home)

    def test_snapshot_reads_root_and_byhost_through_pinned_directories(self):
        (self.preferences / "dev.bozhenpeng.PickVia.E2E.plist").write_bytes(b"root")
        (self.by_host / "dev.bozhenpeng.PickVia.E2E.host.plist").write_bytes(b"host")
        snapshot = runtime.PreferenceDirectorySnapshot.open(self.home)
        try:
            records = snapshot.capture()
            self.assertEqual(len(records), 2)
            self.assertTrue(snapshot.validate_directories())
        finally:
            snapshot.close()

    def test_file_replacement_during_read_fails_closed(self):
        artifact = self.preferences / "dev.bozhenpeng.PickVia.E2E.plist"
        artifact.write_bytes(b"original")

        def replace_after_open(directory_name, name):
            self.assertEqual(directory_name, "Preferences")
            held = artifact.with_suffix(".held")
            artifact.rename(held)
            artifact.write_bytes(b"replacement")

        snapshot = runtime.PreferenceDirectorySnapshot.open(
            self.home, after_open=replace_after_open
        )
        try:
            with self.assertRaises(runtime.SmokePolicyError):
                snapshot.capture()
        finally:
            snapshot.close()

    def test_directory_replacement_is_detected(self):
        snapshot = runtime.PreferenceDirectorySnapshot.open(self.home)
        original = self.home / "Library" / "Preferences-held"
        try:
            self.preferences.rename(original)
            self.preferences.mkdir()
            self.assertFalse(snapshot.validate_directories())
        finally:
            snapshot.close()


class ExactProcessTests(unittest.TestCase):
    def test_pid_reuse_is_never_signaled(self):
        signals = []
        identities = iter(("replacement",))
        process = runtime.ExactProcess.for_test(
            pid=4242,
            poll=lambda: None,
            wait=lambda timeout: None,
            identity=lambda pid: next(identities),
            signal_group=lambda process_group, signal_number: signals.append(
                (process_group, signal_number)
            ),
            process_group=lambda pid: pid,
            expected_identity="original",
        )
        self.assertFalse(process.terminate_bounded(term_timeout=0, kill_timeout=0))
        self.assertEqual(signals, [])

    def test_timeout_terminates_exact_process_group_and_descendant(self):
        fixture = pathlib.Path(
            tempfile.mkdtemp(prefix="pickvia-smoke-process-", dir="/private/tmp")
        )
        child_pid_file = fixture / "child.pid"
        process = runtime.ExactProcess.start(
            [
                "/bin/sh",
                "-c",
                f"/bin/sleep 60 & child=$!; echo $child > {child_pid_file}; wait",
            ],
            environment={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin"},
        )
        try:
            for _ in range(100):
                if child_pid_file.exists():
                    break
                runtime.time.sleep(0.01)
            child_pid = int(child_pid_file.read_text(encoding="ascii"))
            self.assertTrue(process.terminate_bounded(term_timeout=1, kill_timeout=1))
            with self.assertRaises(ProcessLookupError):
                os.kill(child_pid, 0)
        finally:
            process.close_streams()
            shutil.rmtree(fixture)

    def test_leader_exit_before_termination_still_cleans_owned_descendant(self):
        fixture = pathlib.Path(
            tempfile.mkdtemp(prefix="pickvia-smoke-leader-exit-", dir="/private/tmp")
        )
        child_pid_file = fixture / "child.pid"
        process = runtime.ExactProcess.start(
            [
                "/bin/sh",
                "-c",
                f"/bin/sleep 60 & child=$!; echo $child > {child_pid_file}; /bin/sleep 0.1; exit 0",
            ],
            environment={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin"},
        )
        child_pid = None
        try:
            for _ in range(100):
                if child_pid_file.exists():
                    break
                runtime.time.sleep(0.01)
            child_pid = int(child_pid_file.read_text(encoding="ascii"))
            process.process.wait(timeout=1)
            self.assertTrue(process.terminate_bounded(term_timeout=1, kill_timeout=1))
            with self.assertRaises(ProcessLookupError):
                os.kill(child_pid, 0)
        finally:
            if child_pid is not None:
                try:
                    os.killpg(process.pid, 9)
                except ProcessLookupError:
                    pass
            try:
                process.process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                pass
            process.close_streams()
            shutil.rmtree(fixture)

    def test_leader_exit_after_term_still_kills_term_ignoring_descendant(self):
        fixture = pathlib.Path(
            tempfile.mkdtemp(prefix="pickvia-smoke-term-exit-", dir="/private/tmp")
        )
        child_pid_file = fixture / "child.pid"
        process = runtime.ExactProcess.start(
            [
                "/bin/sh",
                "-c",
                f"trap 'exit 0' TERM; /bin/sh -c 'trap \"\" TERM; echo $$ > {child_pid_file}; exec /bin/sleep 60' & wait",
            ],
            environment={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin"},
        )
        child_pid = None
        try:
            for _ in range(100):
                if child_pid_file.exists():
                    break
                runtime.time.sleep(0.01)
            child_pid = int(child_pid_file.read_text(encoding="ascii"))
            self.assertTrue(process.terminate_bounded(term_timeout=0.1, kill_timeout=1))
            with self.assertRaises(ProcessLookupError):
                os.kill(child_pid, 0)
        finally:
            if child_pid is not None:
                try:
                    os.killpg(process.pid, 9)
                except ProcessLookupError:
                    pass
            try:
                process.process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                pass
            process.close_streams()
            shutil.rmtree(fixture)

    def test_identity_pin_failure_cleans_attributable_process_group(self):
        fixture = pathlib.Path(
            tempfile.mkdtemp(prefix="pickvia-smoke-pin-failure-", dir="/private/tmp")
        )
        child_pid_file = fixture / "child.pid"
        with self.assertRaises(runtime.SmokePolicyError):
            runtime.ExactProcess.start(
                [
                    "/bin/sh",
                    "-c",
                    f"/bin/sleep 60 & child=$!; echo $child > {child_pid_file}; wait",
                ],
                environment={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin"},
                identity_resolver=lambda pid: None,
                identity_timeout=0.05,
            )
        for _ in range(100):
            if child_pid_file.exists():
                break
            runtime.time.sleep(0.01)
        child_pid = int(child_pid_file.read_text(encoding="ascii"))
        with self.assertRaises(ProcessLookupError):
            os.kill(child_pid, 0)
        shutil.rmtree(fixture)


if __name__ == "__main__":
    unittest.main()
