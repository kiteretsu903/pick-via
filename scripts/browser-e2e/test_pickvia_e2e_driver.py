#!/usr/bin/env python3

import ctypes
import errno
import os
import pathlib
import plistlib
import signal
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
HELPER_SOURCE = SCRIPT_DIR / "open_with_app.swift"
sys.path.insert(0, str(SCRIPT_DIR))
try:
    import pickvia_e2e_driver as driver
except ModuleNotFoundError:
    driver = None


class DriverAvailabilityTests(unittest.TestCase):
    def test_driver_module_exists(self):
        self.assertIsNotNone(driver, "PickVia E2E route driver is not implemented")


@unittest.skipIf(driver is None, "PickVia E2E route driver is not implemented")
class DriverFixture:
    def __init__(
        self,
        *,
        status_records=None,
        delivers_receipt=True,
        helper_delivers_to_app=True,
        spawn_browser=True,
        browser_identity_visible=True,
        receipt_without_browser=False,
        app_hangs=False,
        timeout=2.0,
        probe_kind="normal",
        exact_e2e_identity=True,
        leak_channel=None,
        preexisting_browser_pids=frozenset(),
        interrupt_on_kind=None,
        workspace_browser_parent=False,
        pid_reuse=False,
        multiple_new_browsers=False,
        browser_survives_termination=False,
        signal_during_cleanup=False,
        root_removal_fails=False,
        fifo_close_fails=False,
        app_ignores_term=False,
        hold_output_open=False,
        helper_fails=False,
        snapshot_failures=frozenset(),
        replacement_after_termination=False,
        late_browser_after_close=False,
        late_pid_reuses_baseline=False,
    ):
        self.status_records = status_records or [
            {"session": "session_0123456789", "outcome": "selected"}
        ]
        self.delivers_receipt = delivers_receipt
        self.helper_delivers_to_app = helper_delivers_to_app
        self.spawn_browser = spawn_browser
        self.browser_identity_visible = browser_identity_visible
        self.receipt_without_browser = receipt_without_browser
        self.app_hangs = app_hangs
        self.timeout = timeout
        self.probe_kind = probe_kind
        self.exact_e2e_identity = exact_e2e_identity
        self.leak_channel = leak_channel
        self.preexisting_browser_pids = set(preexisting_browser_pids)
        self.interrupt_on_kind = interrupt_on_kind
        self.workspace_browser_parent = workspace_browser_parent
        self.pid_reuse = pid_reuse
        self.multiple_new_browsers = multiple_new_browsers
        self.browser_survives_termination = browser_survives_termination
        self.signal_during_cleanup = signal_during_cleanup
        self.root_removal_fails = root_removal_fails
        self.fifo_close_fails = fifo_close_fails
        self.app_ignores_term = app_ignores_term
        self.hold_output_open = hold_output_open
        self.helper_fails = helper_fails
        self.snapshot_failures = set(snapshot_failures)
        self.replacement_after_termination = replacement_after_termination
        self.late_browser_after_close = late_browser_after_close
        self.late_pid_reuses_baseline = late_pid_reuses_baseline
        self.fixture_root = pathlib.Path(
            tempfile.mkdtemp(prefix="pickvia-driver-fixture-", dir="/private/tmp")
        )
        self.e2e_app = self.fixture_root / "PickVia E2E.app"
        self.e2e_executable = self.e2e_app / "Contents" / "MacOS" / "PickVia"
        self.browser_app = self.fixture_root / "Browser.app"
        self.browser_executable = self.browser_app / "Contents" / "MacOS" / "Browser"
        self.helper = self.fixture_root / "fake-helper"
        self.probe = self.fixture_root / "fake-probe"
        self.route_trigger = self.fixture_root / "route-trigger.fifo"
        self.browser_pid_file = self.fixture_root / "browser.pid"
        self.output_holder_pid_file = self.fixture_root / "output-holder.pid"
        self.task_root = None
        self.route = None
        self.observed_argv = []
        self.observed_environment = []
        self.launched_child_pids = []
        self.launched_processes = []
        self.launched_kinds = []
        self.closed_child_pids = []
        self.terminated_browser_pids = []
        self.terminated_browser_generations = []
        self.regular_file_snapshots = []
        self.captured_child_output = []
        self.clock_calls = 0
        self.identity_checks = []
        self.e2e_pid = None
        self.snapshot_call_count = 0
        self.snapshot_phases = []
        self.synthetic_browser_terminated = False
        self.final_sweep_all_children_stopped = False
        self._sent_cleanup_signal = False

    def __enter__(self):
        self.e2e_executable.parent.mkdir(parents=True)
        self.browser_executable.parent.mkdir(parents=True)
        os.mkfifo(self.route_trigger, 0o600)
        self._write_executable(self.e2e_executable, self._fake_e2e_source())
        self._write_executable(self.browser_executable, self._fake_browser_source())
        self._write_executable(self.helper, self._fake_helper_source())
        self.write_browser_plist("com.microsoft.edgemac", "Browser")
        if self.probe_kind == "normal":
            self.probe = SCRIPT_DIR / "localhost_probe.py"
        elif self.probe_kind in {"leak-stdout", "leak-stderr"}:
            self._write_executable(self.probe, self._leaking_probe_source())
        else:
            self._write_executable(self.probe, self._adversarial_probe_source())
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        for pid in self.browser_pids():
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        if self.output_holder_pid_file.exists():
            try:
                os.kill(int(self.output_holder_pid_file.read_text()), signal.SIGKILL)
            except ProcessLookupError:
                pass
        if self.task_root is not None and self.task_root.exists():
            self._remove_tree(self.task_root)
        self._remove_tree(self.fixture_root)

    def write_browser_plist(self, bundle_identifier, executable_name, app=None):
        app = pathlib.Path(app or self.browser_app)
        with (app / "Contents" / "Info.plist").open("wb") as stream:
            plistlib.dump(
                {
                    "CFBundleIdentifier": bundle_identifier,
                    "CFBundleExecutable": executable_name,
                },
                stream,
            )

    def browser_pids(self):
        if not self.browser_pid_file.exists():
            return []
        return [
            int(value)
            for value in self.browser_pid_file.read_text(encoding="ascii").split(",")
            if value
        ]

    def _fake_e2e_source(self):
        return """#!/usr/bin/env python3
import json
import os
import pathlib
import signal
import subprocess
import time
import urllib.request
root = pathlib.Path(__file__).resolve().parents[3]
signal.signal(signal.SIGCHLD, signal.SIG_IGN)
if %r: signal.signal(signal.SIGTERM, signal.SIG_IGN)
if %r:
    time.sleep(60)
route = (root / "route-trigger.fifo").read_bytes()
if %r:
    holder = subprocess.Popen(["/bin/sleep", "60"])
    (root / "output-holder.pid").write_text(str(holder.pid), encoding="ascii")
if %r == "app-stdout": os.write(1, route)
if %r == "app-stderr": os.write(2, route)
if %r == "app-overflow": os.write(1, b"x" * 70000)
records = %r
with open(os.environ["PICKVIA_E2E_STATUS_FIFO"], "w", encoding="utf-8") as stream:
    for record in records:
        stream.write(json.dumps(record, separators=(",", ":"), sort_keys=True) + "\\n")
        stream.flush()
outcomes = [record.get("outcome") for record in records if isinstance(record, dict)]
if "selected" in outcomes and "launch-error" not in outcomes:
    if %r:
        try: urllib.request.urlopen(route.decode("ascii"), timeout=1).read()
        except Exception: pass
    elif %r:
        executable = root / "Browser.app" / "Contents" / "MacOS" / "Browser"
        browsers = []
        for _ in range(%r):
            browser = subprocess.Popen([str(executable)], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            browser.stdin.write(route); browser.stdin.close(); browsers.append(browser)
        (root / "browser.pid").write_text(",".join(str(browser.pid) for browser in browsers), encoding="ascii")
time.sleep(60)
""" % (
            self.app_ignores_term,
            self.app_hangs,
            self.hold_output_open,
            self.leak_channel,
            self.leak_channel,
            self.leak_channel,
            self.status_records,
            self.receipt_without_browser,
            self.spawn_browser,
            2 if self.multiple_new_browsers else 1,
        )

    def _fake_browser_source(self):
        return (
            """#!/usr/bin/env python3
import sys
import time
import urllib.request
route = sys.stdin.buffer.read()
if %r:
    try: urllib.request.urlopen(route.decode("ascii"), timeout=1).read()
    except Exception: pass
time.sleep(60)
"""
            % self.delivers_receipt
        )

    def _fake_helper_source(self):
        return """#!/usr/bin/env python3
import os
import pathlib
import sys
route = sys.stdin.buffer.read()
if %r: raise SystemExit(23)
if %r == "helper-stdout": os.write(1, route)
if %r == "helper-stderr": os.write(2, route)
if %r:
    root = pathlib.Path(sys.argv[1]).parent
    with open(root / "route-trigger.fifo", "wb", buffering=0) as stream: stream.write(route)
""" % (
            self.helper_fails,
            self.leak_channel,
            self.leak_channel,
            self.helper_delivers_to_app,
        )

    def _leaking_probe_source(self):
        return (
            """#!/usr/bin/env python3
import json
import os
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
token = "TOKEN"
receipt = None
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        global receipt
        receipt = {"token": token, "receipt_time": time.time(), "remote_address": "127.0.0.1"}
        self.send_response(204); self.end_headers()
    def log_message(self, *args): pass
server = HTTPServer(("127.0.0.1", 0), Handler)
print(json.dumps({"port": server.server_address[1], "tokens": [token]}, separators=(",", ":")), flush=True)
server.handle_request()
print(json.dumps(receipt, separators=(",", ":"), sort_keys=True), flush=True)
route = ("http://127.0.0.1:%%d/%%s" %% (server.server_address[1], token)).encode("ascii")
if %r == "leak-stdout": os.write(1, route)
else: os.write(2, route)
server.server_close()
"""
            % self.probe_kind
        )

    def _adversarial_probe_source(self):
        if self.probe_kind == "invalid-ready":
            return "#!/usr/bin/env python3\nprint('not-json', flush=True)\n"
        receipt = {
            "wrong-token": '{"remote_address":"127.0.0.1","receipt_time":1,"token":"wrong"}',
            "wrong-remote": '{"remote_address":"127.0.0.2","receipt_time":1,"token":"TOKEN"}',
            "malformed": "not-json",
        }.get(self.probe_kind, "")
        return (
            """#!/usr/bin/env python3
import json
from http.server import BaseHTTPRequestHandler, HTTPServer
class Handler(BaseHTTPRequestHandler):
    def do_GET(self): self.send_response(204); self.end_headers()
    def log_message(self, *args): pass
server = HTTPServer(("127.0.0.1", 0), Handler)
print(json.dumps({"port": server.server_address[1], "tokens": ["TOKEN"]}, separators=(",", ":")), flush=True)
server.handle_request()
print(%r, flush=True)
server.server_close()
"""
            % receipt
        )

    def _write_executable(self, path, contents):
        path.write_text(contents, encoding="utf-8")
        path.chmod(0o700)

    def _remove_tree(self, root):
        if not root.exists():
            return
        for path in sorted(root.rglob("*"), reverse=True):
            if path.is_dir() and not path.is_symlink():
                path.rmdir()
            else:
                path.unlink()
        root.rmdir()

    def _monotonic(self):
        self.clock_calls += 1
        return time.monotonic()

    def _observe_process(self, kind, process, argv, environment):
        self.launched_child_pids.append(process.pid)
        self.launched_processes.append(process)
        self.launched_kinds.append(kind)
        self.observed_argv.append((kind, tuple(os.fspath(value) for value in argv)))
        self.observed_environment.append(
            (
                kind,
                tuple(
                    os.fsencode(f"{key}={value}")
                    for key, value in sorted((environment or {}).items())
                ),
            )
        )
        if kind == "e2e-app":
            self.e2e_pid = process.pid
        if kind == self.interrupt_on_kind:
            raise driver._DriverInterrupted

    def _observe_close(self, kind, pid):
        self.closed_child_pids.append(pid)

    def _observe_route(self, route):
        self.route = route

    def _check_e2e_identity(self, process, executable):
        self.identity_checks.append((process.pid, pathlib.Path(executable)))
        return self.exact_e2e_identity

    def _snapshot_browser_processes(self, executable, phase):
        self.snapshot_call_count += 1
        self.snapshot_phases.append(phase)
        if phase in self.snapshot_failures:
            raise OSError("injected process inspection failure")
        identities = {
            driver.ProcessIdentity(pid, 1, 1, pid, pathlib.Path(executable))
            for pid in self.preexisting_browser_pids
        }
        if self.pid_reuse and not self.browser_pid_file.exists():
            identities.add(
                driver.ProcessIdentity(700, 1, 1, 1, pathlib.Path(executable))
            )
        baseline_identities = set(identities)
        if self.browser_identity_visible and self.browser_pid_file.exists():
            for index, actual_pid in enumerate(self.browser_pids()):
                try:
                    os.kill(actual_pid, 0)
                except ProcessLookupError:
                    continue
                exposed_pid = 700 if self.pid_reuse and index == 0 else actual_pid
                identities.add(
                    driver.ProcessIdentity(
                        exposed_pid,
                        1 if self.workspace_browser_parent else self.e2e_pid,
                        2,
                        actual_pid,
                        pathlib.Path(executable),
                    )
                )
        synthetic = driver.ProcessIdentity(
            700 if self.late_pid_reuses_baseline else 900,
            1,
            9,
            99,
            pathlib.Path(executable),
        )
        if phase == "post-terminate" and self.replacement_after_termination:
            identities = set(baseline_identities)
            identities.add(synthetic)
        if phase in {"final-sweep", "final-post-terminate"}:
            self.final_sweep_all_children_stopped = all(
                process.poll() is not None for process in self.launched_processes
            )
            if (
                self.replacement_after_termination or self.late_browser_after_close
            ) and not self.synthetic_browser_terminated:
                identities.add(synthetic)
        return identities

    def _terminate_browser(self, identity, executable):
        self.terminated_browser_pids.append(identity.pid)
        self.terminated_browser_generations.append(identity.generation_key)
        if identity.start_seconds == 9:
            self.synthetic_browser_terminated = True
            return True
        if self.browser_survives_termination:
            return True
        actual_pid = self.browser_pids()[0] if self.pid_reuse else identity.pid
        try:
            os.kill(actual_pid, signal.SIGTERM)
        except ProcessLookupError:
            return True
        deadline = time.monotonic() + 0.5
        while time.monotonic() < deadline:
            try:
                os.kill(actual_pid, 0)
            except ProcessLookupError:
                return True
            time.sleep(0.01)
        return False

    def _capture_output(self, kind, channel, contents, overflow):
        self.captured_child_output.append((kind, channel, contents, overflow))

    def _before_cleanup(self, root):
        self.task_root = pathlib.Path(root)
        for path in self.task_root.rglob("*"):
            if path.is_file() and not path.is_symlink():
                self.regular_file_snapshots.append((path.name, path.read_bytes()))
        if self.signal_during_cleanup and not self._sent_cleanup_signal:
            self._sent_cleanup_signal = True
            os.kill(os.getpid(), signal.SIGTERM)

    def _remove_driver_root(self, root):
        if self.root_removal_fails:
            return False
        self._remove_tree(pathlib.Path(root))
        return True

    def _close_fifo(self, descriptor):
        os.close(descriptor)
        return not self.fifo_close_fails

    def run(self, *, config_overrides=None, dependency_overrides=None):
        dependency_values = dict(
            helper_executable=self.helper,
            probe_script=self.probe,
            monotonic=self._monotonic,
            process_observer=self._observe_process,
            termination_observer=self._observe_close,
            route_observer=self._observe_route,
            before_cleanup=self._before_cleanup,
            process_identity_checker=self._check_e2e_identity,
            browser_process_snapshot=self._snapshot_browser_processes,
            browser_process_terminator=self._terminate_browser,
            capture_observer=self._capture_output,
            task_root_remover=self._remove_driver_root,
            fifo_closer=self._close_fifo,
        )
        dependency_values.update(dependency_overrides or {})
        dependencies = driver.DriverDependencies(**dependency_values)
        config_values = dict(
            e2e_app=self.e2e_app,
            browser_app=self.browser_app,
            expected_browser_executable=self.browser_executable,
            target_id="com.microsoft.edgemac||normal",
            bundle_identifier="com.microsoft.edgemac",
            mode="normal",
            session_nonce="session_0123456789",
            timeout=self.timeout,
        )
        config_values.update(config_overrides or {})
        return driver.run_driver(
            driver.DriverConfig(**config_values),
            dependencies=dependencies,
        )


@unittest.skipIf(driver is None, "PickVia E2E route driver is not implemented")
class PickViaE2EDriverTests(unittest.TestCase):
    def test_posttermination_replacement_generation_is_preserved_as_ambiguous(self):
        with DriverFixture(replacement_after_termination=True) as fixture:
            result = fixture.run()
            self.assertEqual(result.exit_code, driver.DRIVER_BROWSER_IDENTITY_AMBIGUOUS)
            self.assertEqual(result.report["outcome"], "identity-ambiguous")
            self.assertEqual(len(fixture.terminated_browser_generations), 1)
            self.assertNotIn(900, fixture.terminated_browser_pids)
            self.assertTrue(fixture.final_sweep_all_children_stopped)
            self.assertFalse(fixture.task_root.exists())

    def test_late_browser_after_process_close_is_cleaned_but_prevents_success(self):
        records = [{"session": "session_0123456789", "outcome": "target-missing"}]
        with DriverFixture(
            status_records=records, late_browser_after_close=True
        ) as fixture:
            result = fixture.run()
            self.assertEqual(result.exit_code, driver.DRIVER_CLEANUP_FAILURE)
            self.assertEqual(result.report["outcome"], "cleanup-error")
            self.assertEqual(fixture.terminated_browser_pids, [900])
            self.assertTrue(fixture.final_sweep_all_children_stopped)
            self.assertFalse(fixture.task_root.exists())

    def test_final_sweep_allows_only_immutable_baseline_generations(self):
        records = [{"session": "session_0123456789", "outcome": "target-missing"}]
        with DriverFixture(
            status_records=records, preexisting_browser_pids={41, 42}
        ) as fixture:
            result = fixture.run()
            self.assertEqual(result.exit_code, driver.DRIVER_SELECTION_REJECTED)
            self.assertEqual(fixture.terminated_browser_pids, [])
            self.assertTrue(fixture.final_sweep_all_children_stopped)

    def test_final_sweep_treats_reused_baseline_pid_as_new_generation(self):
        records = [{"session": "session_0123456789", "outcome": "target-missing"}]
        with DriverFixture(
            status_records=records,
            preexisting_browser_pids={700},
            late_browser_after_close=True,
            late_pid_reuses_baseline=True,
        ) as fixture:
            result = fixture.run()
            self.assertEqual(result.exit_code, driver.DRIVER_CLEANUP_FAILURE)
            self.assertEqual(fixture.terminated_browser_pids, [700])
            self.assertEqual(fixture.terminated_browser_generations[0][1:3], (9, 99))

    def test_unknown_final_snapshot_is_cleanup_error_and_root_still_closes(self):
        records = [{"session": "session_0123456789", "outcome": "target-missing"}]
        with DriverFixture(
            status_records=records, snapshot_failures={"final-sweep"}
        ) as fixture:
            result = fixture.run()
            self.assertEqual(result.exit_code, driver.DRIVER_CLEANUP_FAILURE)
            self.assertEqual(result.report["outcome"], "cleanup-error")
            self.assertEqual(fixture.terminated_browser_pids, [])
            self.assertFalse(fixture.task_root.exists())

    def test_browser_termination_treats_authoritative_presignal_absence_as_benign(self):
        executable = pathlib.Path("/Applications/Browser.app/Contents/MacOS/Browser")
        identity = driver.ProcessIdentity(123, 1, 2, 3, executable)
        with mock.patch.object(
            driver, "_snapshot_exact_browser_processes", return_value=frozenset()
        ), mock.patch.object(driver.os, "kill") as kill:
            self.assertTrue(
                driver._terminate_exact_browser_process(identity, executable)
            )
            kill.assert_not_called()
        with mock.patch.object(
            driver,
            "_snapshot_exact_browser_processes",
            side_effect=driver._IdentityInspectionError,
        ), mock.patch.object(driver.os, "kill") as kill:
            with self.assertRaises(driver._IdentityInspectionError):
                driver._terminate_exact_browser_process(identity, executable)
            kill.assert_not_called()

    def test_baseline_identity_inspection_failure_aborts_before_route_delivery(self):
        with DriverFixture(
            preexisting_browser_pids={41}, snapshot_failures={"baseline"}
        ) as fixture:
            result = fixture.run()
            self.assertEqual(result.exit_code, driver.DRIVER_IDENTITY_FAILURE)
            self.assertEqual(result.report["outcome"], "identity-inspection-error")
            self.assertIsNone(fixture.route)
            self.assertEqual(fixture.launched_kinds, [])
            self.assertEqual(fixture.terminated_browser_pids, [])

    def test_observation_inspection_failure_never_attributes_or_terminates_browser(
        self,
    ):
        with DriverFixture(
            preexisting_browser_pids={41}, snapshot_failures={"observation"}
        ) as fixture:
            result = fixture.run()
            self.assertEqual(result.exit_code, driver.DRIVER_IDENTITY_FAILURE)
            self.assertEqual(result.report["outcome"], "identity-inspection-error")
            self.assertIsNotNone(fixture.route)
            self.assertEqual(fixture.terminated_browser_pids, [])
            self.assertFalse(result.report["exact_browser_process_identity"])

    def test_cleanup_sweep_inspection_failure_is_cleanup_failure_without_termination(
        self,
    ):
        with DriverFixture(snapshot_failures={"cleanup-sweep"}) as fixture:
            result = fixture.run()
            self.assertEqual(result.exit_code, driver.DRIVER_CLEANUP_FAILURE)
            self.assertEqual(result.report["outcome"], "cleanup-error")
            self.assertEqual(fixture.terminated_browser_pids, [])

    def test_pretermination_revalidation_failure_is_cleanup_failure_and_never_kills(
        self,
    ):
        with DriverFixture(snapshot_failures={"pre-terminate"}) as fixture:
            result = fixture.run()
            self.assertEqual(result.exit_code, driver.DRIVER_CLEANUP_FAILURE)
            self.assertEqual(result.report["outcome"], "cleanup-error")
            self.assertEqual(fixture.terminated_browser_pids, [])

    def test_posttermination_absence_scan_failure_never_reports_cleanup_success(self):
        with DriverFixture(snapshot_failures={"post-terminate"}) as fixture:
            result = fixture.run()
            self.assertEqual(result.exit_code, driver.DRIVER_CLEANUP_FAILURE)
            self.assertEqual(result.report["outcome"], "cleanup-error")
            self.assertEqual(len(fixture.terminated_browser_pids), 1)

    def test_proc_listpids_failure_and_incomplete_enumeration_are_not_empty_snapshots(
        self,
    ):
        class FailedListPIDs:
            def proc_listpids(self, *_arguments):
                return -1

        class IncompleteListPIDs:
            calls = 0

            def proc_listpids(self, _kind, _uid, _buffer, size):
                self.calls += 1
                return ctypes.sizeof(ctypes.c_int) if self.calls == 1 else size

        for library in (FailedListPIDs(), IncompleteListPIDs()):
            with self.subTest(library=type(library).__name__):
                with self.assertRaises(driver._IdentityInspectionError):
                    driver._snapshot_exact_browser_processes(
                        pathlib.Path(
                            "/Applications/Browser.app/Contents/MacOS/Browser"
                        ),
                        library=library,
                    )

    def test_only_esrch_process_identity_race_is_benign(self):
        class FailedPIDInfo:
            def __init__(self, error_number):
                self.error_number = error_number

            def proc_pidpath(self, *_arguments):
                ctypes.set_errno(self.error_number)
                return -1

            def proc_listpids(self, _kind, _uid, buffer, _size):
                if buffer is None:
                    return ctypes.sizeof(ctypes.c_int)
                buffer[0] = 123
                return ctypes.sizeof(ctypes.c_int)

        class FailedBSDInfo:
            def proc_pidpath(self, _pid, buffer, _size):
                buffer.value = b"/Applications/Browser.app/Contents/MacOS/Browser"
                return len(buffer.value)

            def proc_pidinfo(self, *_arguments):
                ctypes.set_errno(errno.EIO)
                return -1

        with self.assertRaises(driver._ProcessDisappeared):
            driver._darwin_process_identity(123, FailedPIDInfo(errno.ESRCH))
        with self.assertRaises(driver._IdentityInspectionError):
            driver._darwin_process_identity(123, FailedPIDInfo(errno.EIO))
        self.assertEqual(
            driver._snapshot_exact_browser_processes(
                pathlib.Path("/Applications/Browser.app/Contents/MacOS/Browser"),
                library=FailedPIDInfo(errno.ESRCH),
            ),
            frozenset(),
        )
        with self.assertRaises(driver._IdentityInspectionError):
            driver._snapshot_exact_browser_processes(
                pathlib.Path("/Applications/Browser.app/Contents/MacOS/Browser"),
                library=FailedPIDInfo(errno.EIO),
            )
        with self.assertRaises(driver._IdentityInspectionError):
            driver._darwin_process_identity(123, FailedBSDInfo())

    def test_browser_control_is_bound_to_exact_bundle_metadata_and_executable(self):
        with DriverFixture() as fixture:
            beta_app = fixture.fixture_root / "Microsoft Edge Beta.app"
            beta_executable = beta_app / "Contents" / "MacOS" / "Microsoft Edge Beta"
            beta_executable.parent.mkdir(parents=True)
            fixture._write_executable(beta_executable, "#!/bin/sh\nexit 0\n")
            fixture.write_browser_plist(
                "com.microsoft.edgemac.Beta", "Microsoft Edge Beta", beta_app
            )
            result = fixture.run(
                config_overrides={
                    "browser_app": beta_app,
                    "expected_browser_executable": beta_executable,
                }
            )
            self.assertEqual(result.exit_code, driver.DRIVER_IDENTITY_FAILURE)
            self.assertEqual(result.report["outcome"], "identity-error")
            self.assertIsNone(fixture.route)

        with DriverFixture() as fixture:
            fixture.write_browser_plist("com.microsoft.edgemac", "OtherBrowser")
            result = fixture.run()
            self.assertEqual(result.exit_code, driver.DRIVER_IDENTITY_FAILURE)
            self.assertIsNone(fixture.route)

        with DriverFixture() as fixture:
            other = fixture.browser_executable.parent / "OtherBrowser"
            fixture._write_executable(other, "#!/bin/sh\nexit 0\n")
            result = fixture.run(
                config_overrides={"expected_browser_executable": other}
            )
            self.assertEqual(result.exit_code, driver.DRIVER_IDENTITY_FAILURE)
            self.assertIsNone(fixture.route)

    def test_helper_receives_exact_e2e_app_and_never_browser_app(self):
        with DriverFixture() as fixture:
            result = fixture.run()
            helper_argv = next(
                argv
                for kind, argv in fixture.observed_argv
                if kind == "exact-app-helper"
            )
            self.assertEqual(result.exit_code, driver.DRIVER_SUCCESS)
            self.assertEqual(helper_argv, (str(fixture.helper), str(fixture.e2e_app)))
            self.assertNotIn(str(fixture.browser_app), helper_argv)

    def test_fake_chain_cannot_select_or_receive_without_helper_delivery_to_e2e(self):
        with DriverFixture(helper_delivers_to_app=False, timeout=0.25) as fixture:
            result = fixture.run()
            self.assertEqual(result.exit_code, driver.DRIVER_TIMEOUT)
            self.assertFalse(result.report["token_received"])
            self.assertFalse(result.report["exact_browser_process_identity"])

    def test_driver_keeps_url_out_of_harness_control_and_output_channels(self):
        with DriverFixture() as fixture:
            result = fixture.run()
            self.assertEqual(result.exit_code, driver.DRIVER_SUCCESS)
            route_bytes = fixture.route.encode("ascii")
            for _, argv in fixture.observed_argv:
                self.assertNotIn(fixture.route, "\0".join(argv))
            for _, environment in fixture.observed_environment:
                self.assertNotIn(route_bytes, b"\0".join(environment))
            self.assertNotIn(route_bytes, result.status_line)
            self.assertNotIn(route_bytes, result.stdout)
            self.assertNotIn(route_bytes, result.stderr)
            for _, _, contents, _ in fixture.captured_child_output:
                self.assertNotIn(route_bytes, contents)
            for _, contents in fixture.regular_file_snapshots:
                self.assertNotIn(route_bytes, contents)

    def test_child_output_route_leaks_fail_privately_for_every_owned_channel(self):
        channels = (
            "app-stdout",
            "app-stderr",
            "helper-stdout",
            "helper-stderr",
            "leak-stdout",
            "leak-stderr",
        )
        for channel in channels:
            with self.subTest(channel=channel), DriverFixture(
                leak_channel=channel,
                probe_kind=channel if channel.startswith("leak-") else "normal",
            ) as fixture:
                result = fixture.run()
                route = fixture.route.encode("ascii")
                self.assertEqual(result.exit_code, driver.DRIVER_PRIVACY_FAILURE)
                self.assertNotIn(route, result.stdout)
                self.assertNotIn(route, result.stderr)
                self.assertTrue(
                    any(
                        route in contents
                        for _, _, contents, _ in fixture.captured_child_output
                    )
                )

    def test_child_output_capture_is_bounded_and_overflow_fails_closed(self):
        with DriverFixture(leak_channel="app-overflow") as fixture:
            result = fixture.run()
            app_stdout = next(
                record
                for record in fixture.captured_child_output
                if record[0:2] == ("e2e-app", "stdout")
            )
            self.assertEqual(result.exit_code, driver.DRIVER_PRIVACY_FAILURE)
            self.assertLessEqual(len(app_stdout[2]), driver.MAXIMUM_CAPTURE_BYTES)
            self.assertTrue(app_stdout[3])

    def test_selected_requires_independent_receipt_and_exact_browser_identity(self):
        with DriverFixture(delivers_receipt=False, timeout=0.3) as fixture:
            self.assertEqual(fixture.run().exit_code, driver.DRIVER_RECEIPT_TIMEOUT)
        with DriverFixture(
            receipt_without_browser=True, spawn_browser=False, timeout=1.0
        ) as fixture:
            result = fixture.run()
            self.assertEqual(result.exit_code, driver.DRIVER_BROWSER_IDENTITY_TIMEOUT)
            self.assertTrue(result.report["token_received"])
            self.assertFalse(result.report["exact_browser_process_identity"])

    def test_browser_identity_is_reported_separately_from_e2e_identity(self):
        with DriverFixture() as fixture:
            result = fixture.run()
            self.assertTrue(result.report["exact_process_identity"])
            self.assertTrue(result.report["exact_browser_process_identity"])
            self.assertEqual(
                fixture.identity_checks, [(fixture.e2e_pid, fixture.e2e_executable)]
            )
            self.assertEqual(
                set(result.report),
                {
                    "session",
                    "outcome",
                    "token_received",
                    "exact_process_identity",
                    "exact_browser_process_identity",
                    "elapsed_bound_seconds",
                },
            )

    def test_only_new_exact_browser_child_is_terminated(self):
        with DriverFixture(preexisting_browser_pids={41, 42}) as fixture:
            result = fixture.run()
            new_pid = fixture.browser_pids()[0]
            self.assertEqual(result.exit_code, driver.DRIVER_SUCCESS)
            self.assertEqual(fixture.terminated_browser_pids, [new_pid])
            self.assertTrue({41, 42}.isdisjoint(fixture.terminated_browser_pids))
            with self.assertRaises(ProcessLookupError):
                os.kill(new_pid, 0)

    def test_workspace_parent_new_generation_is_owned_without_ppid_guessing(self):
        with DriverFixture(workspace_browser_parent=True) as fixture:
            result = fixture.run()
            self.assertEqual(result.exit_code, driver.DRIVER_SUCCESS)
            self.assertEqual(
                fixture.terminated_browser_pids, [fixture.browser_pids()[0]]
            )

    def test_pid_reuse_is_distinguished_by_start_generation(self):
        with DriverFixture(pid_reuse=True) as fixture:
            result = fixture.run()
            self.assertEqual(result.exit_code, driver.DRIVER_SUCCESS)
            self.assertEqual(fixture.terminated_browser_pids, [700])

    def test_multiple_new_browser_generations_fail_ambiguous_without_termination(self):
        with DriverFixture(multiple_new_browsers=True) as fixture:
            result = fixture.run()
            self.assertEqual(result.exit_code, driver.DRIVER_BROWSER_IDENTITY_AMBIGUOUS)
            self.assertEqual(result.report["outcome"], "identity-ambiguous")
            self.assertEqual(fixture.terminated_browser_pids, [])

    def test_nonstring_wrong_session_unknown_and_duplicate_statuses_are_invalid(self):
        invalid_sequences = (
            [{"session": ["session_0123456789"], "outcome": "selected"}],
            [{"session": "session_0123456789", "outcome": ["selected"]}],
            [{"session": "wrong_session_1234", "outcome": "selected"}],
            [{"session": "session_0123456789", "outcome": "arbitrary-message"}],
            [{"session": "session_0123456789", "outcome": "selected"}] * 2,
            [
                {"session": "session_0123456789", "outcome": "selected"},
                {"session": "session_0123456789", "outcome": "target-missing"},
            ],
        )
        for records in invalid_sequences:
            with self.subTest(records=records), DriverFixture(
                status_records=records
            ) as fixture:
                self.assertEqual(fixture.run().exit_code, driver.DRIVER_INVALID_STATUS)

    def test_selected_then_launch_error_is_product_failure_before_receipt(self):
        records = [
            {"session": "session_0123456789", "outcome": "selected"},
            {"session": "session_0123456789", "outcome": "launch-error"},
        ]
        with DriverFixture(status_records=records) as fixture:
            result = fixture.run()
            self.assertEqual(result.exit_code, driver.DRIVER_SELECTION_REJECTED)
            self.assertEqual(result.report["outcome"], "launch-error")
            self.assertFalse(result.report["token_received"])

    def test_closed_rejection_is_sanitized_selection_failure(self):
        records = [{"session": "session_0123456789", "outcome": "target-missing"}]
        with DriverFixture(status_records=records) as fixture:
            result = fixture.run()
            self.assertEqual(result.exit_code, driver.DRIVER_SELECTION_REJECTED)
            self.assertEqual(result.report["outcome"], "target-missing")

    def test_driver_rejects_adversarial_receipts(self):
        for kind in ("wrong-token", "wrong-remote", "malformed"):
            with self.subTest(kind=kind), DriverFixture(probe_kind=kind) as fixture:
                self.assertEqual(fixture.run().exit_code, driver.DRIVER_INVALID_RECEIPT)

    def test_driver_times_out_and_closes_exact_direct_children(self):
        with DriverFixture(app_hangs=True, timeout=0.25) as fixture:
            result = fixture.run()
            self.assertEqual(result.exit_code, driver.DRIVER_TIMEOUT)
            self.assertEqual(
                set(fixture.closed_child_pids), set(fixture.launched_child_pids)
            )

    def test_driver_cleans_fifo_receiver_and_isolated_support_root(self):
        observations = {}
        with DriverFixture() as fixture:
            original = fixture._before_cleanup

            def inspect(root):
                fifo = pathlib.Path(root) / "status.fifo"
                metadata = fifo.lstat()
                observations.update(
                    mode=stat.S_IMODE(metadata.st_mode),
                    is_fifo=stat.S_ISFIFO(metadata.st_mode),
                    owner=metadata.st_uid,
                    parent=fifo.parent,
                )
                original(root)

            fixture._before_cleanup = inspect
            result = fixture.run()
            root = fixture.task_root
            self.assertEqual(result.exit_code, driver.DRIVER_SUCCESS)
        self.assertFalse(root.exists())
        self.assertEqual(root.parent, pathlib.Path("/private/tmp"))
        self.assertEqual(observations["mode"], 0o600)
        self.assertTrue(observations["is_fifo"])
        self.assertEqual(observations["owner"], os.getuid())
        self.assertEqual(observations["parent"], root)

    def test_driver_cleans_owned_state_when_interrupted(self):
        with DriverFixture(interrupt_on_kind="receiver") as fixture:
            result = fixture.run()
            root = fixture.task_root
            self.assertEqual(result.exit_code, driver.DRIVER_PROCESS_ERROR)
            self.assertEqual(result.report["outcome"], "driver-error")
            self.assertEqual(
                set(fixture.closed_child_pids), set(fixture.launched_child_pids)
            )
        self.assertFalse(root.exists())

    def test_signal_during_finalization_is_deferred_until_cleanup_finishes(self):
        with DriverFixture(signal_during_cleanup=True) as fixture:
            result = fixture.run()
            root = fixture.task_root
            self.assertEqual(result.exit_code, driver.DRIVER_CLEANUP_FAILURE)
            self.assertEqual(result.report["outcome"], "cleanup-interrupted")
        self.assertFalse(root.exists())

    def test_term_timeout_live_drainer_browser_survivor_and_root_failure_are_cleanup_errors(
        self,
    ):
        cases = (
            {"app_ignores_term": True},
            {"hold_output_open": True},
            {"browser_survives_termination": True},
            {"root_removal_fails": True},
            {"fifo_close_fails": True},
        )
        for case in cases:
            with self.subTest(case=case), DriverFixture(**case) as fixture:
                result = fixture.run()
                self.assertEqual(result.exit_code, driver.DRIVER_CLEANUP_FAILURE)
                self.assertEqual(result.report["outcome"], "cleanup-error")

    def test_driver_closes_every_owned_child_pipe(self):
        with DriverFixture() as fixture:
            fixture.run()
            for process in fixture.launched_processes:
                for stream in (process.stdin, process.stdout, process.stderr):
                    if stream is not None:
                        self.assertTrue(stream.closed)

    def test_driver_caps_timeout_at_thirty_seconds_and_uses_monotonic_clock(self):
        with DriverFixture(timeout=300) as fixture:
            result = fixture.run()
            self.assertEqual(result.exit_code, driver.DRIVER_SUCCESS)
            self.assertLessEqual(result.report["elapsed_bound_seconds"], 30.0)
            self.assertGreater(fixture.clock_calls, 1)

    def test_driver_fails_before_route_when_e2e_identity_is_wrong(self):
        with DriverFixture(exact_e2e_identity=False) as fixture:
            result = fixture.run()
            self.assertEqual(result.exit_code, driver.DRIVER_IDENTITY_FAILURE)
            self.assertEqual(result.report["outcome"], "identity-error")
            self.assertFalse(result.report["exact_process_identity"])
            self.assertIsNone(fixture.route)
            self.assertNotIn("exact-app-helper", fixture.launched_kinds)

    def test_driver_rejects_route_counts_other_than_one_without_launching(self):
        with DriverFixture() as fixture:
            config = driver.DriverConfig(
                e2e_app=fixture.e2e_app,
                browser_app=fixture.browser_app,
                expected_browser_executable=fixture.browser_executable,
                target_id="com.microsoft.edgemac||normal",
                bundle_identifier="com.microsoft.edgemac",
                mode="normal",
                session_nonce="session_0123456789",
                route_count=2,
            )
            result = driver.run_driver(config)
            self.assertEqual(result.exit_code, driver.DRIVER_USAGE)
            self.assertEqual(fixture.launched_child_pids, [])

    def test_failure_taxonomy_is_exact_and_sanitized(self):
        cases = (
            (
                lambda: DriverFixture(probe_kind="invalid-ready"),
                {},
                driver.DRIVER_READINESS_FAILURE,
                "readiness-error",
            ),
            (
                DriverFixture,
                {
                    "helper_executable": None,
                    "helper_source": pathlib.Path("/private/tmp/missing-helper.swift"),
                },
                driver.DRIVER_HELPER_FAILURE,
                "helper-error",
            ),
            (
                lambda: DriverFixture(helper_fails=True),
                {},
                driver.DRIVER_HELPER_FAILURE,
                "helper-error",
            ),
        )
        for make_fixture, overrides, expected_code, expected_outcome in cases:
            with self.subTest(
                expected_outcome=expected_outcome
            ), make_fixture() as fixture:
                result = fixture.run(dependency_overrides=overrides)
                self.assertEqual(result.exit_code, expected_code)
                self.assertEqual(result.report["outcome"], expected_outcome)
                self.assertNotIn(
                    fixture.route or "never", result.stdout.decode("ascii")
                )


@unittest.skipIf(driver is None, "PickVia E2E route driver is not implemented")
class ExactAppHelperTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = pathlib.Path(
            tempfile.mkdtemp(prefix="pickvia-helper-test-", dir="/private/tmp")
        )
        cls.executable = cls.root / "open_with_app"
        completed = subprocess.run(
            ["xcrun", "swiftc", str(HELPER_SOURCE), "-o", str(cls.executable)],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=30,
            check=False,
        )
        if completed.returncode != 0:
            raise AssertionError("exact-app helper did not compile")

    @classmethod
    def tearDownClass(cls):
        if not hasattr(cls, "root"):
            return
        for path in sorted(cls.root.rglob("*"), reverse=True):
            if path.is_dir() and not path.is_symlink():
                path.rmdir()
            else:
                path.unlink()
        cls.root.rmdir()

    def run_helper(self, arguments, stdin):
        return subprocess.run(
            [str(self.executable), *arguments],
            input=stdin,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=3,
            check=False,
        )

    def test_helper_requires_exactly_one_app_argument(self):
        missing = self.run_helper([], b"https://127.0.0.1/token")
        extra = self.run_helper(
            ["/Applications/A.app", "/Applications/B.app"], b"https://127.0.0.1/token"
        )
        self.assertNotEqual(missing.returncode, 0)
        self.assertNotEqual(extra.returncode, 0)
        self.assertEqual(missing.stdout, b"")
        self.assertEqual(extra.stdout, b"")
        self.assertEqual(missing.stderr, b"invalid arguments\n")
        self.assertEqual(extra.stderr, b"invalid arguments\n")

    def test_helper_rejects_non_http_schemes_and_input_above_byte_cap(self):
        cases = (
            (
                ["/Applications/not-an-app"],
                b"https://127.0.0.1/token",
                b"invalid application\n",
            ),
            (
                ["/Applications/A.app"],
                b"file:///private/tmp/secret",
                b"invalid input\n",
            ),
            (["/Applications/A.app"], b"ftp://127.0.0.1/token", b"invalid input\n"),
            (["/Applications/A.app"], b"x" * 4097, b"invalid input\n"),
        )
        for arguments, stdin, expected_error in cases:
            with self.subTest(arguments=arguments, size=len(stdin)):
                result = self.run_helper(arguments, stdin)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, b"")
                self.assertEqual(result.stderr, expected_error)
                self.assertNotIn(stdin, result.stderr)

    def test_helper_source_disables_activation_recents_and_arbitrary_errors(self):
        source = HELPER_SOURCE.read_text(encoding="utf-8")
        self.assertIn("configuration.activates = false", source)
        self.assertIn("configuration.addsToRecentItems = false", source)
        self.assertIn("NSWorkspace.shared.open(", source)
        self.assertNotIn("localizedDescription", source)


if __name__ == "__main__":
    unittest.main()
