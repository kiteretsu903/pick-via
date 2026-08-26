#!/usr/bin/env python3

import errno
import io
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).parent))

import smoke_e2e_runtime as runtime


class SmokeCompilerTests(unittest.TestCase):
    def test_cli_launch_failure_reports_only_sanitized_stage(self):
        stderr = io.StringIO()
        with mock.patch.dict(
            os.environ,
            {
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "LANG": "en_US.UTF-8",
                "LC_CTYPE": "UTF-8",
            },
            clear=True,
        ), mock.patch.object(
            runtime,
            "_run_missing_target_smoke",
            side_effect=runtime._SmokeStageFailure("compile-helper"),
        ), mock.patch.object(runtime.sys, "stderr", stderr):
            status = runtime._main(
                [
                    "launch-app",
                    "/private/tmp/private-app-name.app",
                    "/private/tmp/private-helper-name.swift",
                    "smoke_session_0123456789",
                ]
            )

        self.assertEqual(status, 1)
        self.assertEqual(
            stderr.getvalue(),
            "E2E smoke supervision stage failed: compile-helper\n",
        )
        self.assertNotIn("private", stderr.getvalue())

    def test_cli_launch_app_delegates_to_exact_smoke_supervision(self):
        with mock.patch.dict(
            os.environ,
            {
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "LANG": "en_US.UTF-8",
                "LC_CTYPE": "UTF-8",
            },
            clear=True,
        ), mock.patch.object(
            runtime, "_run_missing_target_smoke", return_value=True
        ) as supervise:
            status = runtime._main(
                [
                    "launch-app",
                    "/private/tmp/PickVia E2E.app",
                    "/private/tmp/open_with_app.swift",
                    "smoke_session_0123456789",
                ]
            )
        self.assertEqual(status, 0)
        supervise.assert_called_once_with(
            pathlib.Path("/private/tmp/PickVia E2E.app"),
            pathlib.Path("/private/tmp/open_with_app.swift"),
            "smoke_session_0123456789",
        )

    def test_smoke_finalizes_root_only_after_owned_process_group_is_absent(self):
        pinned_app = mock.Mock()
        pinned_app.path = pathlib.Path("/private/tmp/PickVia E2E.app")
        pinned_app.executable = pathlib.Path("/usr/bin/true")
        pinned_app.validate.return_value = True
        task_root = mock.Mock()
        task_root.require_current.return_value = pathlib.Path(
            "/private/tmp/pickvia-e2e-test"
        )
        task_root.open_fifo.return_value = 99
        task_root.child_path.return_value = pathlib.Path(
            "/private/tmp/pickvia-e2e-test/open_with_app"
        )
        task_root.audit_regular_files.return_value = True
        owner = mock.Mock()
        owner.cleanup.return_value = True
        application = mock.Mock()
        application.pid = 4242
        application.terminate_bounded.return_value = True
        application._group_state.return_value = "absent"
        sequence = mock.Mock()
        sequence.attach_mock(application.terminate_bounded, "terminate")
        sequence.attach_mock(owner.cleanup, "finalize")
        expected = b'{"outcome":"target-missing","session":"smoke_session_0123456789"}'

        with mock.patch.object(
            runtime.PinnedApplication, "open", return_value=pinned_app
        ), mock.patch.object(
            runtime.driver, "_TaskRootOwner", return_value=owner
        ), mock.patch.object(
            runtime.driver, "_make_task_root", return_value=task_root
        ), mock.patch.object(
            runtime, "_compile_smoke_helper", return_value=True
        ), mock.patch.object(
            runtime, "_run_smoke_helper", return_value=True
        ), mock.patch.object(
            runtime, "_read_smoke_status", return_value=expected
        ), mock.patch.object(
            runtime.ExactProcess, "start", return_value=application
        ), mock.patch.object(runtime.os, "close"):
            self.assertTrue(
                runtime._run_missing_target_smoke(
                    pinned_app.path,
                    pathlib.Path("/private/tmp/open_with_app.swift"),
                    "smoke_session_0123456789",
                )
            )

        self.assertLess(
            sequence.mock_calls.index(mock.call.terminate(term_timeout=4, kill_timeout=2)),
            sequence.mock_calls.index(mock.call.finalize()),
        )

    def test_ambiguous_app_process_group_preserves_task_root(self):
        pinned_app = mock.Mock()
        pinned_app.path = pathlib.Path("/private/tmp/PickVia E2E.app")
        pinned_app.executable = pathlib.Path("/usr/bin/true")
        pinned_app.validate.return_value = True
        task_root = mock.Mock()
        task_root.require_current.return_value = pathlib.Path(
            "/private/tmp/pickvia-e2e-preserved"
        )
        task_root.open_fifo.return_value = 99
        task_root.child_path.return_value = pathlib.Path(
            "/private/tmp/pickvia-e2e-preserved/open_with_app"
        )
        owner = mock.Mock()
        application = mock.Mock()
        application.pid = 4242
        application.terminate_bounded.return_value = False
        application._group_state.return_value = "ambiguous"
        expected = b'{"outcome":"target-missing","session":"smoke_session_0123456789"}'

        with mock.patch.object(
            runtime.PinnedApplication, "open", return_value=pinned_app
        ), mock.patch.object(
            runtime.driver, "_TaskRootOwner", return_value=owner
        ), mock.patch.object(
            runtime.driver, "_make_task_root", return_value=task_root
        ), mock.patch.object(
            runtime, "_compile_smoke_helper", return_value=True
        ), mock.patch.object(
            runtime, "_run_smoke_helper", return_value=True
        ), mock.patch.object(
            runtime, "_read_smoke_status", return_value=expected
        ), mock.patch.object(
            runtime.ExactProcess, "start", return_value=application
        ), mock.patch.object(runtime.os, "close"):
            with self.assertRaises(runtime.SmokePolicyError):
                runtime._run_missing_target_smoke(
                    pinned_app.path,
                    pathlib.Path("/private/tmp/open_with_app.swift"),
                    "smoke_session_0123456789",
                )

        owner.cleanup.assert_not_called()
        task_root.close.assert_called_once_with()

    def test_unpinned_app_startup_preserves_task_root_without_cleanup_authority(self):
        pinned_app = mock.Mock()
        pinned_app.path = pathlib.Path("/private/tmp/PickVia E2E.app")
        pinned_app.executable = pathlib.Path("/usr/bin/true")
        pinned_app.validate.return_value = True
        task_root = mock.Mock()
        task_root.require_current.return_value = pathlib.Path(
            "/private/tmp/pickvia-e2e-unpinned"
        )
        task_root.open_fifo.return_value = 99
        task_root.child_path.return_value = pathlib.Path(
            "/private/tmp/pickvia-e2e-unpinned/open_with_app"
        )
        owner = mock.Mock()

        with mock.patch.object(
            runtime.PinnedApplication, "open", return_value=pinned_app
        ), mock.patch.object(
            runtime.driver, "_TaskRootOwner", return_value=owner
        ), mock.patch.object(
            runtime.driver, "_make_task_root", return_value=task_root
        ), mock.patch.object(
            runtime, "_compile_smoke_helper", return_value=True
        ), mock.patch.object(
            runtime.ExactProcess,
            "start",
            side_effect=runtime._UnpinnedProcessError("uninspectable child"),
        ), mock.patch.object(runtime.os, "close"):
            with self.assertRaises(runtime.SmokePolicyError):
                runtime._run_missing_target_smoke(
                    pinned_app.path,
                    pathlib.Path("/private/tmp/open_with_app.swift"),
                    "smoke_session_0123456789",
                )

        owner.cleanup.assert_not_called()
        task_root.close.assert_called_once_with()

    def test_compile_helper_launches_resolved_swiftc_without_xcrun_transition(self):
        root = pathlib.Path(
            tempfile.mkdtemp(prefix="pickvia-swift-sdk-resolution-", dir="/private/tmp")
        )
        physical_sdk = root / "MacOSX.sdk"
        physical_sdk.mkdir()
        sdk_alias = root / "MacOSX.test.sdk"
        sdk_alias.symlink_to(physical_sdk)
        compiler = mock.Mock()
        compiler.wait_success.return_value = True
        compiler._group_state.return_value = "absent"
        resolved = {
            ("/usr/bin/xcrun", "--find", "swiftc"): "/usr/bin/true\n",
            (
                "/usr/bin/xcrun",
                "--sdk",
                "macosx",
                "--show-sdk-path",
            ): f"{sdk_alias}\n",
        }

        def run_resolver(arguments, **kwargs):
            return subprocess.CompletedProcess(
                arguments,
                0,
                stdout=resolved[tuple(arguments)],
                stderr="",
            )

        try:
            with mock.patch.dict(
                os.environ,
                {
                    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                    "LANG": "C",
                    "LC_CTYPE": "C",
                },
                clear=True,
            ), mock.patch.object(runtime.subprocess, "run", side_effect=run_resolver), mock.patch.object(
                runtime.ExactProcess, "start", return_value=compiler
            ) as start:
                status = runtime._main(
                    [
                        "compile-helper",
                        "/private/tmp/helper.swift",
                        "/private/tmp/helper",
                        "/private/tmp",
                    ]
                )
        finally:
            shutil.rmtree(root)

        self.assertEqual(status, 0)
        command = start.call_args.args[0]
        self.assertEqual(command[0], "/usr/bin/true")
        self.assertIn("-sdk", command)
        self.assertEqual(command[command.index("-sdk") + 1], os.fspath(physical_sdk))


class ProcessGroupSnapshotTests(unittest.TestCase):
    def test_reused_group_with_uninspectable_leader_rejects_whole_snapshot(self):
        process_group = 4242

        class Library:
            def proc_listpids(self, kind, user_identifier, values, size):
                if values is None:
                    return 2 * runtime.ctypes.sizeof(runtime.ctypes.c_int)
                values[0] = process_group
                values[1] = 5000
                return 2 * runtime.ctypes.sizeof(runtime.ctypes.c_int)

            def proc_pidinfo(self, process_identifier, kind, argument, information, size):
                if process_identifier == process_group:
                    return 0
                pointer = runtime.ctypes.cast(
                    information, runtime.ctypes.POINTER(runtime.driver._ProcBSDInfo)
                )
                pointer.contents.pbi_pgid = process_group
                return runtime.ctypes.sizeof(runtime.driver._ProcBSDInfo)

        identity = runtime.driver.ProcessIdentity(
            process_group, 1, 10, 20, pathlib.Path("/bin/sleep")
        )
        with mock.patch.object(runtime.driver, "_load_libproc", return_value=Library()), mock.patch.object(
            runtime.driver, "_darwin_process_identity", return_value=identity
        ):
            with self.assertRaises(runtime.SmokePolicyError):
                runtime._darwin_process_group_snapshot(process_group)


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
    def test_failed_group_snapshot_confirms_absence_only_with_esrch_probe(self):
        probes = []

        def signal_group(process_group, signal_number):
            probes.append((process_group, signal_number))
            raise ProcessLookupError(errno.ESRCH, "process group is absent")

        process = runtime.ExactProcess.for_test(
            pid=4242,
            poll=lambda: 0,
            wait=lambda timeout: 0,
            identity=lambda pid: None,
            signal_group=signal_group,
            process_group=lambda pid: pid,
            expected_identity="original",
            group_snapshot=lambda pid: (_ for _ in ()).throw(
                runtime.SmokePolicyError("group snapshot unavailable")
            ),
        )

        self.assertEqual(process._group_state(), "absent")
        self.assertEqual(probes, [(4242, 0)])

    def test_failed_group_snapshot_with_permission_error_remains_ambiguous(self):
        signals = []

        def signal_group(process_group, signal_number):
            signals.append((process_group, signal_number))
            raise PermissionError(errno.EPERM, "group inspection denied")

        process = runtime.ExactProcess.for_test(
            pid=4242,
            poll=lambda: 0,
            wait=lambda timeout: 0,
            identity=lambda pid: None,
            signal_group=signal_group,
            process_group=lambda pid: pid,
            expected_identity="original",
            group_snapshot=lambda pid: (_ for _ in ()).throw(
                runtime.SmokePolicyError("group snapshot unavailable")
            ),
        )

        self.assertEqual(process._group_state(), "ambiguous")
        self.assertFalse(process.terminate_bounded(term_timeout=0, kill_timeout=0))
        self.assertEqual(signals, [(4242, 0), (4242, 0)])

    def test_reused_unpinned_group_leader_is_never_signaled(self):
        expected = pathlib.Path("/usr/bin/true").resolve()
        replacement = runtime.driver.ProcessIdentity(
            4242, 1, 30, 40, pathlib.Path("/usr/bin/false").resolve()
        )
        process = mock.Mock(pid=4242, args=[os.fspath(expected)])
        process.poll.return_value = None
        process.stdin = None
        process.stdout = None
        process.stderr = None
        with mock.patch.object(
            runtime.subprocess, "Popen", return_value=process
        ), mock.patch.object(runtime.os, "killpg") as signal_group, mock.patch.object(
            runtime.os, "getpgid", return_value=4242
        ), mock.patch.object(
            runtime, "_darwin_process_group_snapshot"
        ) as snapshot:
            with self.assertRaises(runtime.SmokePolicyError):
                runtime.ExactProcess.start(
                    [expected],
                    environment={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin"},
                    identity_resolver=lambda _pid: replacement,
                )
        signal_group.assert_not_called()
        snapshot.assert_not_called()

    def test_identity_inspection_failure_never_signals_unpinned_group(self):
        expected = pathlib.Path("/usr/bin/true").resolve()
        process = mock.Mock(pid=4242, args=[os.fspath(expected)])
        process.poll.return_value = None
        process.stdin = None
        process.stdout = None
        process.stderr = None
        with mock.patch.object(
            runtime.subprocess, "Popen", return_value=process
        ), mock.patch.object(runtime.os, "killpg") as signal_group, mock.patch.object(
            runtime.os, "getpgid", return_value=4242
        ), mock.patch.object(
            runtime, "_darwin_process_group_snapshot"
        ) as snapshot, mock.patch.object(
            runtime.time, "monotonic", side_effect=(0.0, 0.0, 1.0)
        ):
            with self.assertRaises(runtime.SmokePolicyError):
                runtime.ExactProcess.start(
                    [expected],
                    environment={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin"},
                    identity_resolver=lambda _pid: (_ for _ in ()).throw(
                        runtime.driver._IdentityInspectionError()
                    ),
                )
        signal_group.assert_not_called()
        snapshot.assert_not_called()

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

    def test_replacement_between_term_and_kill_is_never_killed(self):
        signals = []
        expected = runtime.driver.ProcessIdentity(
            4242, 1, 10, 20, pathlib.Path("/bin/sleep")
        )
        replacement = runtime.driver.ProcessIdentity(
            4242, 1, 30, 40, pathlib.Path("/bin/other")
        )
        snapshots = iter(
            (
                frozenset({expected}),
                frozenset({expected}),
                frozenset({replacement}),
            )
        )
        process = runtime.ExactProcess.for_test(
            pid=4242,
            poll=lambda: None,
            wait=lambda timeout: None,
            identity=lambda pid: expected,
            signal_group=lambda process_group, signal_number: signals.append(
                (process_group, signal_number)
            ),
            process_group=lambda pid: pid,
            expected_identity=expected,
            group_snapshot=lambda pid: next(snapshots),
        )
        self.assertFalse(process.terminate_bounded(term_timeout=0, kill_timeout=0))
        self.assertEqual(signals, [(4242, runtime.signal.SIGTERM)])

    def test_timeout_terminates_exact_process_group_and_descendant(self):
        fixture = pathlib.Path(
            tempfile.mkdtemp(prefix="pickvia-smoke-process-", dir="/private/tmp")
        )
        child_pid_file = fixture / "child.pid"
        process = runtime.ExactProcess.start(
            [
                "/bin/bash",
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
                "/bin/bash",
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
                "/bin/bash",
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

if __name__ == "__main__":
    unittest.main()
