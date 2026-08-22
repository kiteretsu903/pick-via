#!/usr/bin/env python3

import json
import os
import pathlib
import stat
import subprocess
import sys
import tempfile
import time
import unittest


SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
DRIVER_PATH = SCRIPT_DIR / "pickvia_e2e_driver.py"
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
        status_outcome="selected",
        status_session="session_0123456789",
        delivers_receipt=True,
        app_hangs=False,
        timeout=2.0,
        probe_kind="normal",
        exact_process_identity=True,
        status_extra_line=False,
        interrupt_on_kind=None,
    ):
        self.status_outcome = status_outcome
        self.status_session = status_session
        self.delivers_receipt = delivers_receipt
        self.app_hangs = app_hangs
        self.timeout = timeout
        self.probe_kind = probe_kind
        self.exact_process_identity = exact_process_identity
        self.status_extra_line = status_extra_line
        self.interrupt_on_kind = interrupt_on_kind
        self.fixture_root = pathlib.Path(
            tempfile.mkdtemp(prefix="pickvia-driver-fixture-", dir="/private/tmp")
        )
        self.e2e_app = self.fixture_root / "PickVia E2E.app"
        self.e2e_executable = self.e2e_app / "Contents" / "MacOS" / "PickVia"
        self.browser_app = self.fixture_root / "Browser.app"
        self.helper = self.fixture_root / "fake-helper"
        self.probe = self.fixture_root / "fake-probe"
        self.task_root = None
        self.route = None
        self.observed_argv = []
        self.observed_environment = []
        self.launched_child_pids = []
        self.launched_processes = []
        self.launched_kinds = []
        self.terminated_pids = []
        self.preexisting_pids = {41, 42}
        self.regular_file_snapshots = []
        self.clock_calls = 0
        self.identity_checks = []

    def __enter__(self):
        self.e2e_executable.parent.mkdir(parents=True)
        self.browser_app.mkdir()
        self._write_executable(
            self.e2e_executable,
            """#!/usr/bin/env python3
import json
import os
import time

if %r:
    time.sleep(60)
else:
    record = {"session": %r, "outcome": %r}
    with open(os.environ["PICKVIA_E2E_STATUS_FIFO"], "w", encoding="utf-8") as stream:
        stream.write(json.dumps(record, separators=(",", ":"), sort_keys=True) + "\\n")
        if %r:
            stream.write(json.dumps(record, separators=(",", ":"), sort_keys=True) + "\\n")
"""
            % (
                self.app_hangs,
                self.status_session,
                self.status_outcome,
                self.status_extra_line,
            ),
        )
        self._write_executable(
            self.helper,
            """#!/usr/bin/env python3
import sys
import urllib.request

route = sys.stdin.buffer.read()
if %r:
    try:
        urllib.request.urlopen(route.decode("ascii"), timeout=1).read()
    except Exception:
        pass
"""
            % self.delivers_receipt,
        )
        if self.probe_kind == "normal":
            self.probe = SCRIPT_DIR / "localhost_probe.py"
        else:
            receipt = {
                "wrong-token": '{"remote_address":"127.0.0.1","receipt_time":1,"token":"wrong"}',
                "wrong-remote": '{"remote_address":"127.0.0.2","receipt_time":1,"token":"TOKEN"}',
                "malformed": "not-json",
            }.get(self.probe_kind, "")
            self._write_executable(
                self.probe,
                """#!/usr/bin/env python3
import json
import time
print(json.dumps({"port": 9, "tokens": ["TOKEN"]}, separators=(",", ":")), flush=True)
line = %r
if line:
    print(line, flush=True)
else:
    time.sleep(60)
"""
                % receipt,
            )
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        self._remove_tree(self.fixture_root)

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
        self.observed_argv.append(tuple(os.fsencode(value) for value in argv))
        self.observed_environment.append(
            tuple(
                os.fsencode(f"{key}={value}")
                for key, value in sorted((environment or {}).items())
            )
        )
        if kind == self.interrupt_on_kind:
            raise driver._DriverInterrupted

    def _observe_termination(self, kind, pid):
        self.terminated_pids.append(pid)

    def _observe_route(self, route):
        self.route = route

    def _check_process_identity(self, process, executable):
        self.identity_checks.append((process.pid, pathlib.Path(executable)))
        return self.exact_process_identity

    def _before_cleanup(self, root):
        self.task_root = pathlib.Path(root)
        for path in self.task_root.rglob("*"):
            if path.is_file() and not path.is_symlink():
                self.regular_file_snapshots.append((path.name, path.read_bytes()))

    def run(self):
        dependencies = driver.DriverDependencies(
            helper_executable=self.helper,
            probe_script=self.probe,
            monotonic=self._monotonic,
            process_observer=self._observe_process,
            termination_observer=self._observe_termination,
            route_observer=self._observe_route,
            before_cleanup=self._before_cleanup,
            process_identity_checker=self._check_process_identity,
        )
        config = driver.DriverConfig(
            e2e_app=self.e2e_app,
            browser_app=self.browser_app,
            target_id="com.microsoft.edgemac||normal",
            bundle_identifier="com.microsoft.edgemac",
            mode="normal",
            session_nonce="session_0123456789",
            timeout=self.timeout,
        )
        return driver.run_driver(config, dependencies=dependencies)


@unittest.skipIf(driver is None, "PickVia E2E route driver is not implemented")
class PickViaE2EDriverTests(unittest.TestCase):
    def test_driver_passes_no_url_in_argv_environment_status_or_regular_files(self):
        with DriverFixture() as fixture:
            result = fixture.run()
            self.assertEqual(result.exit_code, driver.DRIVER_SUCCESS)
            route_bytes = fixture.route.encode("ascii")
            for argv in fixture.observed_argv:
                self.assertNotIn(route_bytes, b"\0".join(argv))
            for environment in fixture.observed_environment:
                self.assertNotIn(route_bytes, b"\0".join(environment))
            self.assertNotIn(route_bytes, result.status_line)
            self.assertNotIn(route_bytes, result.stdout)
            self.assertNotIn(route_bytes, result.stderr)
            for _, contents in fixture.regular_file_snapshots:
                self.assertNotIn(route_bytes, contents)

    def test_driver_requires_selected_status_and_independent_receiver_receipt(self):
        with DriverFixture(delivers_receipt=False, timeout=0.3) as fixture:
            self.assertEqual(fixture.run().exit_code, driver.DRIVER_RECEIPT_TIMEOUT)
        with DriverFixture(status_outcome="target-missing") as fixture:
            self.assertEqual(fixture.run().exit_code, driver.DRIVER_SELECTION_REJECTED)

    def test_driver_rejects_wrong_session_and_unknown_status(self):
        with DriverFixture(status_session="wrong_session_1234") as fixture:
            self.assertEqual(fixture.run().exit_code, driver.DRIVER_INVALID_STATUS)
        with DriverFixture(status_outcome="arbitrary-message") as fixture:
            self.assertEqual(fixture.run().exit_code, driver.DRIVER_INVALID_STATUS)
        with DriverFixture(status_extra_line=True) as fixture:
            self.assertEqual(fixture.run().exit_code, driver.DRIVER_INVALID_STATUS)

    def test_driver_rejects_adversarial_receipts(self):
        for kind in ("wrong-token", "wrong-remote", "malformed"):
            with self.subTest(kind=kind), DriverFixture(probe_kind=kind) as fixture:
                self.assertEqual(fixture.run().exit_code, driver.DRIVER_INVALID_RECEIPT)

    def test_driver_times_out_and_terminates_exact_children(self):
        with DriverFixture(app_hangs=True, timeout=0.25) as fixture:
            result = fixture.run()
            self.assertEqual(result.exit_code, driver.DRIVER_TIMEOUT)
            self.assertEqual(
                set(fixture.terminated_pids), set(fixture.launched_child_pids)
            )

    def test_driver_cleans_fifo_receiver_and_isolated_support_root(self):
        with DriverFixture() as fixture:
            result = fixture.run()
            root = fixture.task_root
            self.assertEqual(result.exit_code, driver.DRIVER_SUCCESS)
            self.assertIsNotNone(root)
        self.assertFalse(root.exists())
        self.assertEqual(root.parent, pathlib.Path("/private/tmp"))

    def test_driver_creates_owned_0600_direct_child_fifo(self):
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
            self.assertEqual(fixture.run().exit_code, driver.DRIVER_SUCCESS)

        self.assertEqual(observations["mode"], 0o600)
        self.assertTrue(observations["is_fifo"])
        self.assertEqual(observations["owner"], os.getuid())
        self.assertEqual(observations["parent"], fixture.task_root)

    def test_driver_never_terminates_preexisting_processes(self):
        with DriverFixture() as fixture:
            fixture.run()
            self.assertTrue(
                fixture.preexisting_pids.isdisjoint(fixture.terminated_pids)
            )

    def test_driver_cleans_owned_state_when_interrupted(self):
        with DriverFixture(interrupt_on_kind="receiver") as fixture:
            result = fixture.run()
            root = fixture.task_root
            self.assertEqual(result.exit_code, driver.DRIVER_PROCESS_ERROR)
            self.assertEqual(
                set(fixture.terminated_pids), set(fixture.launched_child_pids)
            )
        self.assertIsNotNone(root)
        self.assertFalse(root.exists())

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

    def test_result_is_closed_sanitized_json(self):
        with DriverFixture() as fixture:
            result = fixture.run()
            self.assertEqual(
                set(result.report),
                {
                    "session",
                    "outcome",
                    "token_received",
                    "exact_process_identity",
                    "elapsed_bound_seconds",
                },
            )
            self.assertEqual(result.report["outcome"], "selected")
            self.assertTrue(result.report["token_received"])
            self.assertTrue(result.report["exact_process_identity"])
            self.assertEqual(
                fixture.identity_checks,
                [(fixture.launched_processes[1].pid, fixture.e2e_executable)],
            )
            self.assertNotIn(fixture.route, json.dumps(result.report, sort_keys=True))

    def test_driver_fails_closed_before_routing_when_app_identity_is_wrong(self):
        with DriverFixture(exact_process_identity=False) as fixture:
            result = fixture.run()
            self.assertEqual(result.exit_code, driver.DRIVER_PROCESS_ERROR)
            self.assertFalse(result.report["exact_process_identity"])
            self.assertIsNone(fixture.route)
            self.assertNotIn("exact-app-helper", fixture.launched_kinds)

    def test_driver_rejects_route_counts_other_than_one_without_launching(self):
        with DriverFixture() as fixture:
            config = driver.DriverConfig(
                e2e_app=fixture.e2e_app,
                browser_app=fixture.browser_app,
                target_id="com.microsoft.edgemac||normal",
                bundle_identifier="com.microsoft.edgemac",
                mode="normal",
                session_nonce="session_0123456789",
                route_count=2,
            )
            result = driver.run_driver(config)
            self.assertEqual(result.exit_code, driver.DRIVER_USAGE)
            self.assertEqual(fixture.launched_child_pids, [])


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
            ["/Applications/A.app", "/Applications/B.app"],
            b"https://127.0.0.1/token",
        )
        self.assertNotEqual(missing.returncode, 0)
        self.assertNotEqual(extra.returncode, 0)
        self.assertEqual(missing.stdout, b"")
        self.assertEqual(extra.stdout, b"")
        self.assertEqual(missing.stderr, b"invalid arguments\n")
        self.assertEqual(extra.stderr, b"invalid arguments\n")

    def test_helper_rejects_non_app_non_http_and_oversized_input_with_fixed_errors(
        self,
    ):
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
            (["/Applications/A.app"], b"x" * 4097, b"invalid input\n"),
        )
        for arguments, stdin, expected_error in cases:
            with self.subTest(arguments=arguments, size=len(stdin)):
                result = self.run_helper(arguments, stdin)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, b"")
                self.assertEqual(result.stderr, expected_error)
                self.assertNotIn(stdin, result.stderr)

    def test_helper_source_disables_activation_and_recents(self):
        source = HELPER_SOURCE.read_text(encoding="utf-8")
        self.assertIn("configuration.activates = false", source)
        self.assertIn("configuration.addsToRecentItems = false", source)
        self.assertIn("NSWorkspace.shared.open(", source)
        self.assertNotIn("localizedDescription", source)


if __name__ == "__main__":
    unittest.main()
