#!/usr/bin/env python3

import ctypes
import errno
import hashlib
import hmac
import json
import os
import pathlib
import plistlib
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import types
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


class SequenceClock:
    def __init__(self):
        self.value = 0.0

    def __call__(self):
        self.value += 1.0
        return self.value


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
        timeout=5.0,
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
        helper_failure_phase=None,
        helper_hangs_after_delivery=False,
        snapshot_failures=frozenset(),
        replacement_after_termination=False,
        late_browser_after_close=False,
        late_pid_reuses_baseline=False,
        delayed_browser_after_final_sweep=False,
        repeated_delayed_browser=False,
        real_quiescence_clock=False,
        proof_deadline_phase=None,
        proof_clock_escape=5.0,
        provenance_records=None,
        provenance_mechanism="process",
        expected_mechanism=None,
        browser_binding_mutation=None,
        provenance_second_delay=0.0,
        provenance_second_partial=False,
        provenance_first_partial=False,
        provenance_before_status=False,
        status_delay=0.0,
        status_trailing_payload=b"",
        status_trailing_delay=0.0,
    ):
        if proof_deadline_phase not in {
            None,
            "status-written",
            "receipt-delivered",
            "helper-started",
            "helper-and-browser",
            "helper-and-receipt",
            "helper-exited",
            "complete-proof",
        }:
            raise ValueError("unknown proof deadline phase")
        self.status_records = (
            [{"session": "$session", "outcome": "selected"}]
            if status_records is None
            else status_records
        )
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
        self.helper_failure_phase = helper_failure_phase
        self.helper_hangs_after_delivery = helper_hangs_after_delivery
        self.snapshot_failures = set(snapshot_failures)
        self.replacement_after_termination = replacement_after_termination
        self.late_browser_after_close = late_browser_after_close
        self.late_pid_reuses_baseline = late_pid_reuses_baseline
        self.delayed_browser_after_final_sweep = delayed_browser_after_final_sweep
        self.repeated_delayed_browser = repeated_delayed_browser
        self.real_quiescence_clock = real_quiescence_clock
        self.proof_deadline_phase = proof_deadline_phase
        self.proof_clock_escape = proof_clock_escape
        self.provenance_records = provenance_records
        self.provenance_mechanism = provenance_mechanism
        self.expected_mechanism = expected_mechanism or provenance_mechanism
        self.browser_binding_mutation = browser_binding_mutation
        self.provenance_second_delay = provenance_second_delay
        self.provenance_second_partial = provenance_second_partial
        self.provenance_first_partial = provenance_first_partial
        self.provenance_before_status = provenance_before_status
        self.status_delay = status_delay
        self.status_trailing_payload = status_trailing_payload
        self.status_trailing_delay = status_trailing_delay
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
        self.routes = []
        self.observed_argv = []
        self.observed_environment = []
        self.launched_child_pids = []
        self.launched_processes = []
        self.launched_kinds = []
        self.closed_child_pids = []
        self.terminated_browser_pids = []
        self.terminated_browser_generations = []
        self.browser_termination_deadlines = []
        self.regular_file_snapshots = []
        self.captured_child_output = []
        self.clock_calls = 0
        self.identity_checks = []
        self.browser_binding_checks = []
        self.e2e_pid = None
        self.e2e_identity = None
        self.snapshot_call_count = 0
        self.snapshot_phases = []
        self.synthetic_browser_terminated = False
        self.repeated_synthetic_browser_terminated = False
        self.final_sweep_all_children_stopped = False
        self.quiescence_snapshot_count = 0
        self.quiescence_clock = 0.0
        self._sent_cleanup_signal = False
        self._proof_clock_base = None
        self._proof_clock_phase_start = None
        self._proof_clock_escape = None
        self._proof_clock_deferred_elapsed = 0.0
        self._fixture_child_identities = {}

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
            self._remember_fixture_child(pid)
        if self.output_holder_pid_file.exists():
            try:
                self._remember_fixture_child(
                    int(self.output_holder_pid_file.read_text(encoding="ascii"))
                )
            except (OSError, ValueError):
                pass
        self._terminate_remembered_fixture_children()
        if self.task_root is not None and self.task_root.exists():
            self._remove_tree(self.task_root)
        self._remove_tree(self.fixture_root)

    def _remember_fixture_child(self, pid):
        try:
            identity = driver._darwin_process_identity(pid)
        except (driver._ProcessDisappeared, driver._IdentityInspectionError):
            return False
        if (
            self.e2e_pid is None
            or self.e2e_identity is None
            or identity.parent_pid != self.e2e_pid
        ):
            return False
        try:
            current_parent = driver._darwin_process_identity(self.e2e_pid)
        except (driver._ProcessDisappeared, driver._IdentityInspectionError):
            return False
        if current_parent.generation_key != self.e2e_identity.generation_key:
            return False
        self._fixture_child_identities[pid] = identity
        return True

    def _terminate_remembered_fixture_children(self):
        for pid, expected in tuple(self._fixture_child_identities.items()):
            try:
                current = driver._darwin_process_identity(pid)
            except (driver._ProcessDisappeared, driver._IdentityInspectionError):
                continue
            if current.generation_key != expected.generation_key:
                continue
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass

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
import types
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
provenance_records = %r
provenance_before_status = %r
def write_provenance():
    if provenance_records is None:
        return
    descriptor = os.open(os.environ["PICKVIA_E2E_PROVENANCE_FIFO"], os.O_WRONLY)
    try:
        for index, record in enumerate(provenance_records):
            if index > 0: time.sleep(%r)
            resolved = dict(record)
            if resolved.get("request") == "$request":
                resolved["request"] = os.environ["PICKVIA_E2E_REQUEST_NONCE"]
            if resolved.get("processIdentifier") == "$browser_pid":
                resolved["processIdentifier"] = browsers[0].pid
            payload = (json.dumps(resolved, separators=(",", ":"), sort_keys=True) + "\\n").encode("utf-8")
            if (index == 0 and %r) or (index > 0 and %r):
                payload = payload[:max(1, len(payload) // 2)]
            os.write(descriptor, payload)
    finally:
        os.close(descriptor)
if provenance_before_status:
    write_provenance()
    time.sleep(%r)
with open(os.environ["PICKVIA_E2E_STATUS_FIFO"], "w", encoding="utf-8") as stream:
    for record in records:
        resolved = dict(record)
        if resolved.get("session") == "$session":
            resolved["session"] = os.environ["PICKVIA_E2E_SESSION_NONCE"]
        stream.write(json.dumps(resolved, separators=(",", ":"), sort_keys=True) + "\\n")
        stream.flush()
    if %r:
        time.sleep(%r)
        os.write(stream.fileno(), %r)
(root / "status-written").touch()
outcomes = [record.get("outcome") for record in records if isinstance(record, dict)]
if "selected" in outcomes and "launch-error" not in outcomes:
    if %r:
        try:
            urllib.request.urlopen(route.decode("ascii"), timeout=5).read()
            (root / "receipt-delivered").touch()
        except Exception: pass
    elif %r:
        executable = root / "Browser.app" / "Contents" / "MacOS" / "Browser"
        browsers = []
        existing = []
        if (root / "browser.pid").exists():
            for value in (root / "browser.pid").read_text(encoding="ascii").split(","):
                try:
                    os.kill(int(value), 0); existing.append(int(value))
                except (ProcessLookupError, ValueError): pass
        if existing:
            urllib.request.urlopen(route.decode("ascii"), timeout=5).read()
            (root / "receipt-delivered").touch()
            browsers = [types.SimpleNamespace(pid=value) for value in existing]
        else:
            for _ in range(%r):
                browser = subprocess.Popen([str(executable)], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                browser.stdin.write(route); browser.stdin.close(); browsers.append(browser)
        (root / "browser.pid").write_text(",".join(str(browser.pid) for browser in browsers), encoding="ascii")
    if provenance_records is None:
        provenance_records = [{
            "session": os.environ["PICKVIA_E2E_SESSION_NONCE"],
            "request": os.environ["PICKVIA_E2E_REQUEST_NONCE"],
            "target": os.environ["PICKVIA_E2E_TARGET_ID"],
            "bundleIdentifier": os.environ["PICKVIA_E2E_BUNDLE_ID"],
            "mode": os.environ["PICKVIA_E2E_MODE"],
            "mechanism": %r,
            "processIdentifier": 700 if %r else browsers[0].pid,
            "outcome": "launch-observed",
        }]
if not provenance_before_status:
    write_provenance()
time.sleep(60)
""" % (
            self.app_ignores_term,
            self.app_hangs,
            self.hold_output_open,
            self.leak_channel,
            self.leak_channel,
            self.leak_channel,
            self.status_records,
            self.provenance_records,
            self.provenance_before_status,
            self.provenance_second_delay,
            self.provenance_first_partial,
            self.provenance_second_partial,
            self.status_delay,
            bool(self.status_trailing_payload),
            self.status_trailing_delay,
            self.status_trailing_payload,
            self.receipt_without_browser,
            self.spawn_browser,
            2 if self.multiple_new_browsers else 1,
            self.provenance_mechanism,
            self.pid_reuse,
        )

    def _fake_browser_source(self):
        return (
            """#!/usr/bin/env python3
import pathlib
import sys
import time
import urllib.request
route = sys.stdin.buffer.read()
if %r:
    try:
        urllib.request.urlopen(route.decode("ascii"), timeout=5).read()
        (pathlib.Path(__file__).resolve().parents[3] / "receipt-delivered").touch()
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
    marker = {
        "after-status": root / "status-written",
        "after-browser": root / "browser.pid",
        "after-receipt": root / "receipt-delivered",
    }.get(%r)
    if marker is not None:
        import time
        deadline = time.monotonic() + 5.0
        while not marker.exists() and time.monotonic() < deadline: time.sleep(0.005)
        if marker.name == "browser.pid": time.sleep(0.1)
        if marker.name == "receipt-delivered": time.sleep(0.5)
        raise SystemExit(23)
    if %r:
        import time
        time.sleep(60)
""" % (
            self.helper_fails,
            self.leak_channel,
            self.leak_channel,
            self.helper_delivers_to_app,
            self.helper_failure_phase,
            self.helper_hangs_after_delivery,
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
        valid = '{"remote_address":"127.0.0.1","receipt_time":1,"token":"TOKEN"}'
        if self.probe_kind in {
            "duplicate-receipt-coalesced",
            "duplicate-receipt-delayed",
            "partial-trailing-receipt",
        }:
            receipt = valid
        emission = (
            f"sys.stdout.write(({valid!r} + '\\n') * 2); sys.stdout.flush()"
            if self.probe_kind == "duplicate-receipt-coalesced"
            else f"print({receipt!r}, flush=True)"
        )
        trailing = {
            "duplicate-receipt-delayed": (
                f"time.sleep(0.05); print({valid!r}, flush=True)"
            ),
            "partial-trailing-receipt": (
                'time.sleep(0.24); sys.stdout.write("{\\"token\\":"); '
                "sys.stdout.flush()"
            ),
        }.get(self.probe_kind, "")
        return """#!/usr/bin/env python3
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
class Handler(BaseHTTPRequestHandler):
    def do_GET(self): self.send_response(204); self.end_headers()
    def log_message(self, *args): pass
server = HTTPServer(("127.0.0.1", 0), Handler)
print(json.dumps({"port": server.server_address[1], "tokens": ["TOKEN"]}, separators=(",", ":")), flush=True)
server.handle_request()
%s
%s
server.server_close()
""" % (emission, trailing)

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
        now = time.monotonic()
        if self.proof_deadline_phase is None:
            return now
        if self._proof_clock_base is None:
            self._proof_clock_base = now
            self._proof_clock_escape = now + self.proof_clock_escape
        if self._proof_phase_is_ready():
            if self._proof_clock_phase_start is None:
                self._proof_clock_phase_start = now
            return (
                self._proof_clock_base
                + self._proof_clock_deferred_elapsed
                + (now - self._proof_clock_phase_start)
            )
        if now >= self._proof_clock_escape:
            return (
                self._proof_clock_base + self.timeout + (now - self._proof_clock_escape)
            )
        return self._proof_clock_base

    def _sleep_after_proof(self, seconds):
        if not self._proof_phase_is_ready():
            raise AssertionError("proof clock advanced before proof completion")
        started = time.monotonic()
        time.sleep(seconds)
        if self._proof_clock_phase_start is None:
            self._proof_clock_deferred_elapsed += time.monotonic() - started

    def _proof_phase_is_ready(self):
        helper_started = any(kind == "exact-app-helper" for kind in self.launched_kinds)
        helper_succeeded = any(
            kind == "exact-app-helper" and process.poll() == 0
            for kind, process in zip(self.launched_kinds, self.launched_processes)
        )
        browser_started = self.browser_pid_file.exists()
        receipt_delivered = (self.fixture_root / "receipt-delivered").exists()
        status_written = (self.fixture_root / "status-written").exists()
        return {
            "status-written": status_written,
            "receipt-delivered": receipt_delivered,
            "helper-started": helper_started,
            "helper-exited": helper_succeeded,
            "helper-and-browser": helper_succeeded and browser_started,
            "helper-and-receipt": helper_succeeded and receipt_delivered,
            "complete-proof": (
                helper_succeeded and browser_started and receipt_delivered
            ),
        }.get(self.proof_deadline_phase, False)

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
            try:
                self.e2e_identity = driver._darwin_process_identity(process.pid)
            except (driver._ProcessDisappeared, driver._IdentityInspectionError):
                self.e2e_identity = None
        if kind == self.interrupt_on_kind:
            raise driver._DriverInterrupted

    def _observe_close(self, kind, pid):
        self.closed_child_pids.append(pid)

    def _observe_route(self, route):
        self.route = route
        self.routes.append(route)

    def _check_e2e_identity(self, process, executable):
        self.identity_checks.append((process.pid, pathlib.Path(executable)))
        return self.exact_e2e_identity

    def _snapshot_browser_processes(self, executable, phase):
        self.snapshot_call_count += 1
        self.snapshot_phases.append(phase)
        for pid in self.browser_pids():
            self._remember_fixture_child(pid)
        if self.output_holder_pid_file.exists():
            try:
                self._remember_fixture_child(
                    int(self.output_holder_pid_file.read_text(encoding="ascii"))
                )
            except (OSError, ValueError):
                pass
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
        if phase in {"quiescence", "quiescence-post-terminate"}:
            self.quiescence_snapshot_count += 1
            if (
                self.delayed_browser_after_final_sweep
                and self.quiescence_snapshot_count >= 2
                and not self.synthetic_browser_terminated
            ):
                identities.add(synthetic)
            if (
                self.repeated_delayed_browser
                and self.synthetic_browser_terminated
                and self.quiescence_snapshot_count >= 4
                and not self.repeated_synthetic_browser_terminated
            ):
                identities.add(
                    driver.ProcessIdentity(
                        901,
                        1,
                        10,
                        100,
                        pathlib.Path(executable),
                    )
                )
        return identities

    def _terminate_browser(self, identity, executable, deadline=None):
        self.terminated_browser_pids.append(identity.pid)
        self.terminated_browser_generations.append(identity.generation_key)
        self.browser_termination_deadlines.append(deadline)
        if identity.start_seconds == 9:
            self.synthetic_browser_terminated = True
            return True
        if identity.start_seconds == 10:
            self.repeated_synthetic_browser_terminated = True
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

    def _resolve_browser_pid(self, pid):
        for identity in self._snapshot_browser_processes(
            self.browser_executable, "provenance-resolution"
        ):
            if identity.pid == pid:
                return identity
        raise driver._ProcessDisappeared

    def _check_browser_binding(self, application, executable, bundle_identifier):
        self.browser_binding_checks.append(
            (pathlib.Path(application), pathlib.Path(executable), bundle_identifier)
        )
        if (
            len(self.browser_binding_checks) == 2
            and self.browser_binding_mutation == "wrong-bundle"
        ):
            self.write_browser_plist("com.example.Replacement", "Browser")
        elif (
            len(self.browser_binding_checks) == 2
            and self.browser_binding_mutation == "wrong-executable"
        ):
            self.write_browser_plist(bundle_identifier, "OtherBrowser")
        driver._validate_browser_binding(application, executable, bundle_identifier)

    def _capture_output(self, kind, channel, contents, overflow):
        self.captured_child_output.append((kind, channel, contents, overflow))

    def _quiescence_monotonic(self):
        if self.real_quiescence_clock:
            return time.monotonic()
        return self.quiescence_clock

    def _quiescence_sleep(self, seconds):
        if self.real_quiescence_clock:
            time.sleep(seconds)
        else:
            self.quiescence_clock += seconds

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
        return root.remove()

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
            browser_process_identity=self._resolve_browser_pid,
            browser_binding_checker=self._check_browser_binding,
            browser_static_identity_checker=lambda _application,
            _executable,
            _bundle,
            _expected: None,
            browser_running_code_checker=lambda _pid,
            _application,
            _executable,
            _bundle: None,
            browser_process_terminator=self._terminate_browser,
            quiescence_monotonic=self._quiescence_monotonic,
            quiescence_sleep=self._quiescence_sleep,
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
            expected_mechanism=self.expected_mechanism,
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
    def _make_task_root(self):
        owner = driver._TaskRootOwner()
        try:
            return driver._make_task_root(owner)
        except BaseException:
            owner.cleanup()
            raise

    def test_driver_config_generates_a_fresh_default_request_secret(self):
        values = dict(
            e2e_app=pathlib.Path("/Applications/PickVia E2E.app"),
            browser_app=pathlib.Path("/Applications/Browser.app"),
            expected_browser_executable=pathlib.Path(
                "/Applications/Browser.app/Contents/MacOS/Browser"
            ),
            target_id="com.example.Browser||normal",
            bundle_identifier="com.example.Browser",
            mode="normal",
            expected_mechanism="workspace",
            session_nonce="session_0123456789",
        )
        first = driver.DriverConfig(**values)
        second = driver.DriverConfig(**values)
        self.assertRegex(first.request_nonce, r"\A[0-9a-f]{32}\Z")
        self.assertRegex(second.request_nonce, r"\A[0-9a-f]{32}\Z")
        self.assertNotEqual(first.request_nonce, second.request_nonce)

    def test_driver_publishes_authenticated_bounded_cleanup_handoff(self):
        handoff_directory = pathlib.Path(
            tempfile.mkdtemp(prefix="pickvia-matrix-handoff-", dir="/private/tmp")
        )
        handoff_directory.chmod(0o700)
        handoff_path = handoff_directory / "cleanup-ledger.jsonl"
        descriptor = os.open(
            handoff_path,
            os.O_RDWR | os.O_APPEND | os.O_CREAT | os.O_EXCL,
            0o600,
        )
        os.unlink(handoff_path)
        handoff_directory.rmdir()
        token = "7" * 64
        secret_reader, secret_writer = os.pipe()
        os.write(secret_writer, (token + "\n").encode("ascii"))
        os.close(secret_writer)
        try:
            with DriverFixture() as fixture:
                result = fixture.run(
                    config_overrides={
                        "cleanup_handoff_descriptor": os.dup(descriptor),
                        "cleanup_handoff_secret_descriptor": secret_reader,
                    }
                )
            self.assertEqual(result.exit_code, driver.DRIVER_SUCCESS)
            contents = os.pread(descriptor, os.fstat(descriptor).st_size, 0)
            lines = contents.splitlines()
            self.assertGreaterEqual(len(lines), 5)
            self.assertLessEqual(len(lines), driver.MAXIMUM_HANDOFF_RECORDS)
            transitions = []
            for counter, line in enumerate(lines, 1):
                self.assertLessEqual(len(line) + 1, driver.MAXIMUM_HANDOFF_RECORD_BYTES)
                record = json.loads(line)
                payload = record["payload"]
                canonical = json.dumps(
                    payload,
                    sort_keys=True,
                    separators=(",", ":"),
                    ensure_ascii=True,
                ).encode("ascii")
                self.assertTrue(
                    hmac.compare_digest(
                        record["authentication"],
                        hmac.new(
                            bytes.fromhex(token), canonical, hashlib.sha256
                        ).hexdigest(),
                    )
                )
                self.assertEqual(payload["counter"], counter)
                transitions.append(payload["transition"])
            self.assertEqual(transitions[:2], ["initialized", "root-owned"])
            self.assertIn("child-owned", transitions)
            self.assertIn("browser-owned", transitions)
            self.assertEqual(transitions[-1], "finalized")
            self.assertTrue(json.loads(lines[-1])["payload"]["taskRootFinalized"])
        finally:
            os.close(descriptor)

    def test_three_state_controller_orders_routes_and_reopens_distinct_generation(self):
        executable = pathlib.Path("/Applications/Fake.app/Contents/MacOS/Fake")
        cold = driver.ProcessIdentity(7101, 1, 10, 1, executable)
        reopened = driver.ProcessIdentity(7102, 1, 11, 2, executable)
        live = set()
        routed = []
        signaled = []

        sessions = (
            "session_cold_0000",
            "session_running_0",
            "session_reopen_00",
        )

        def route(state, session, request):
            routed.append((state, session, request))
            if state == "cold":
                live.add(cold)
                return cold
            if state == "running":
                return cold
            live.add(reopened)
            return reopened

        proofs = driver._run_three_state_controller(
            sessions=sessions,
            requests=("request_cold_0000", "request_running_0", "request_reopen_00"),
            route=route,
            snapshot=lambda _phase: frozenset(live),
            attest=lambda identity: identity in live,
            terminate=lambda identity: signaled.append(identity)
            or not live.remove(identity),
            monotonic=SequenceClock(),
            sleep=lambda _seconds: None,
        )
        self.assertEqual(
            [(state, session) for state, session, _ in routed],
            list(zip(("cold", "running", "reopen"), sessions)),
        )
        self.assertEqual(proofs, (cold, cold, reopened))
        self.assertEqual(signaled, [cold])

    def test_three_state_controller_rejects_preexisting_replacement_reuse_and_forgery(
        self,
    ):
        executable = pathlib.Path("/Applications/Fake.app/Contents/MacOS/Fake")
        cold = driver.ProcessIdentity(7201, 1, 20, 1, executable)
        replacement = driver.ProcessIdentity(7201, 1, 21, 1, executable)
        cases = ("preexisting", "death", "replacement", "forged", "same-reopen")
        for case in cases:
            with self.subTest(case=case):
                live = {cold} if case == "preexisting" else set()
                routed = []
                signaled = []

                def route(state, _session, _request):
                    routed.append(state)
                    if state == "cold":
                        live.add(cold)
                        return cold
                    if state == "running":
                        if case == "death":
                            live.clear()
                        elif case == "replacement":
                            live.clear()
                            live.add(replacement)
                        return replacement if case == "forged" else cold
                    live.add(cold if case == "same-reopen" else replacement)
                    return cold if case == "same-reopen" else replacement

                with self.assertRaises(driver._StateSequenceError):
                    driver._run_three_state_controller(
                        sessions=(
                            "session_cold_0000",
                            "session_running_0",
                            "session_reopen_00",
                        ),
                        requests=(
                            "request_cold_0000",
                            "request_running_0",
                            "request_reopen_00",
                        ),
                        route=route,
                        snapshot=lambda _phase: frozenset(live),
                        attest=lambda identity: identity in live,
                        terminate=lambda identity: signaled.append(identity)
                        or not live.remove(identity),
                        monotonic=SequenceClock(),
                        sleep=lambda _seconds: None,
                    )
                if case == "preexisting":
                    self.assertEqual(routed, [])
                self.assertNotIn(replacement, signaled)

    def test_three_state_controller_rejects_missing_or_reused_session_or_request(self):
        valid_sessions = (
            "session_cold_0000",
            "session_running_0",
            "session_reopen_00",
        )
        valid_requests = (
            "request_cold_0000",
            "request_running_0",
            "request_reopen_00",
        )
        for sessions, requests in (
            ((), valid_requests),
            (("session_same_0000",) * 3, valid_requests),
            (valid_sessions, ()),
            (valid_sessions, ("request_same_0000",) * 3),
            (valid_sessions, ("request_cold_0000", "request_running_0")),
        ):
            routed = []
            with (
                self.subTest(sessions=sessions, requests=requests),
                self.assertRaises(driver._StateSequenceError),
            ):
                driver._run_three_state_controller(
                    sessions=sessions,
                    requests=requests,
                    route=lambda state, session, request: routed.append(
                        (state, session, request)
                    ),
                    snapshot=lambda _phase: frozenset(),
                    attest=lambda _identity: False,
                    terminate=lambda _identity: False,
                    monotonic=SequenceClock(),
                    sleep=lambda _seconds: None,
                )
            self.assertEqual(routed, [])

    def test_three_state_controller_rejects_failed_exact_termination(self):
        executable = pathlib.Path("/Applications/Fake.app/Contents/MacOS/Fake")
        cold = driver.ProcessIdentity(7301, 1, 30, 1, executable)
        reopened = driver.ProcessIdentity(7302, 1, 31, 1, executable)
        live = set()

        def route(state, _session, _request):
            if state == "cold":
                live.add(cold)
                return cold
            if state == "reopen":
                live.add(reopened)
                return reopened
            return cold

        def failed_termination(identity):
            live.remove(identity)
            return False

        with self.assertRaises(driver._StateSequenceError):
            driver._run_three_state_controller(
                sessions=(
                    "session_cold_0000",
                    "session_running_0",
                    "session_reopen_00",
                ),
                requests=(
                    "request_cold_0000",
                    "request_running_0",
                    "request_reopen_00",
                ),
                route=route,
                snapshot=lambda _phase: frozenset(live),
                attest=lambda identity: identity in live,
                terminate=failed_termination,
                monotonic=SequenceClock(),
                sleep=lambda _seconds: None,
            )

    def test_three_state_controller_preserves_typed_route_failure_and_ownership(self):
        executable = pathlib.Path("/Applications/Fake.app/Contents/MacOS/Fake")
        identity = driver.ProcessIdentity(7351, 1, 35, 1, executable)
        failure = driver._ReceiptTimeout(
            False,
            b"selected",
            True,
            frozenset({identity}),
            "launch-observed",
        )

        def route(_state, _session, _request):
            raise failure

        with self.assertRaises(driver._ReceiptTimeout) as raised:
            driver._run_three_state_controller(
                sessions=(
                    "session_cold_0000",
                    "session_running_0",
                    "session_reopen_00",
                ),
                requests=(
                    "request_cold_0000",
                    "request_running_0",
                    "request_reopen_00",
                ),
                route=route,
                snapshot=lambda _phase: frozenset(),
                attest=lambda _identity: False,
                terminate=lambda _identity: False,
                monotonic=SequenceClock(),
                sleep=lambda _seconds: None,
            )
        self.assertIs(raised.exception, failure)
        self.assertEqual(raised.exception.owned_browsers, frozenset({identity}))

    def test_driver_sequence_owns_one_root_routes_three_fresh_requests_and_finalizes(
        self,
    ):
        requests = (
            "request_cold_0000",
            "request_running_0",
            "request_reopen_00",
        )
        sessions = (
            "session_cold_0000",
            "session_running_0",
            "session_reopen_00",
        )
        with DriverFixture() as fixture:
            observed_fifos = []
            static_checks = []

            def inspect_fifos(root):
                observed_fifos.extend(
                    sorted(
                        path.name
                        for path in pathlib.Path(root).iterdir()
                        if stat.S_ISFIFO(path.lstat().st_mode)
                    )
                )
                fixture._before_cleanup(root)

            result = fixture.run(
                config_overrides={
                    "state": "sequence",
                    "route_count": 3,
                    "session_nonce": sessions[0],
                    "sequence_sessions": sessions,
                    "sequence_requests": requests,
                    "browser_app_identity": "b" * 64,
                },
                dependency_overrides={
                    "before_cleanup": inspect_fifos,
                    "browser_static_identity_checker": (
                        lambda application,
                        executable,
                        bundle,
                        expected: static_checks.append(
                            (application, executable, bundle, expected)
                        )
                    ),
                },
            )
            self.assertEqual(result.exit_code, driver.DRIVER_SUCCESS)
            self.assertEqual(len(fixture.routes), 3)
            self.assertEqual(len(set(fixture.routes)), 3)
            route_environments = [
                dict(item.split(b"=", 1) for item in environment)
                for kind, environment in fixture.observed_environment
                if kind == "e2e-app"
            ]
            self.assertEqual(
                [
                    environment[b"PICKVIA_E2E_SESSION_NONCE"].decode("ascii")
                    for environment in route_environments
                ],
                list(sessions),
            )
            self.assertEqual(
                result.report["sessionHashes"],
                [
                    hashlib.sha256(session.encode("ascii")).hexdigest()
                    for session in sessions
                ],
            )
            self.assertEqual(
                [proof["session"] for proof in result.report["stateProofs"]],
                list(sessions),
            )
            self.assertGreaterEqual(len(static_checks), 5)
            self.assertTrue(all(check[-1] == "b" * 64 for check in static_checks))
            self.assertEqual(len(fixture.terminated_browser_generations), 2)
            self.assertNotEqual(
                fixture.terminated_browser_generations[0],
                fixture.terminated_browser_generations[1],
            )
            self.assertEqual(
                observed_fifos,
                [
                    "provenance-cold.fifo",
                    "provenance-reopen.fifo",
                    "provenance-running.fifo",
                    "status-cold.fifo",
                    "status-reopen.fifo",
                    "status-running.fifo",
                ],
            )
            self.assertTrue(result.report["cleanup_success"])
            self.assertTrue(result.report["task_root_finalized"])
            self.assertFalse(fixture.task_root.exists())

    def test_driver_sequence_preserves_preexisting_user_generation_and_does_not_route(
        self,
    ):
        with DriverFixture(preexisting_browser_pids={7401}) as fixture:
            result = fixture.run(
                config_overrides={
                    "state": "sequence",
                    "route_count": 3,
                    "session_nonce": "session_cold_0000",
                    "sequence_sessions": (
                        "session_cold_0000",
                        "session_running_0",
                        "session_reopen_00",
                    ),
                    "sequence_requests": (
                        "request_cold_0000",
                        "request_running_0",
                        "request_reopen_00",
                    ),
                }
            )
            self.assertEqual(result.exit_code, driver.DRIVER_BROWSER_IDENTITY_AMBIGUOUS)
            self.assertEqual(result.report["outcome"], "state-sequence-error")
            self.assertEqual(fixture.routes, [])
            self.assertNotIn(7401, fixture.terminated_browser_pids)
            self.assertTrue(result.report["task_root_finalized"])

    def test_driver_sequence_preserves_typed_failure_and_cleans_only_safe_generation(
        self,
    ):
        cases = (
            (
                "receipt-timeout",
                {
                    "delivers_receipt": False,
                    "proof_deadline_phase": "helper-and-browser",
                    "timeout": 0.3,
                },
                driver.DRIVER_RECEIPT_TIMEOUT,
            ),
            (
                "helper-exit-timeout",
                {
                    "helper_hangs_after_delivery": True,
                    "proof_deadline_phase": "receipt-delivered",
                    "timeout": 2.0,
                },
                driver.DRIVER_HELPER_FAILURE,
            ),
            (
                "invalid-receipt",
                {"probe_kind": "wrong-token"},
                driver.DRIVER_INVALID_RECEIPT,
            ),
        )
        for expected_outcome, fixture_options, expected_exit in cases:
            with (
                self.subTest(expected_outcome=expected_outcome),
                DriverFixture(**fixture_options) as fixture,
            ):
                result = fixture.run(
                    config_overrides={
                        "state": "sequence",
                        "route_count": 3,
                        "session_nonce": "session_cold_0000",
                        "sequence_sessions": (
                            "session_cold_0000",
                            "session_running_0",
                            "session_reopen_00",
                        ),
                        "sequence_requests": (
                            "request_cold_0000",
                            "request_running_0",
                            "request_reopen_00",
                        ),
                    }
                )
                self.assertEqual(result.exit_code, expected_exit)
                self.assertEqual(result.report["outcome"], expected_outcome)
                self.assertTrue(result.report["exact_browser_process_identity"])
                self.assertEqual(result.report["launch_provenance"], "launch-observed")
                self.assertEqual(len(result.report["stateProofs"]), 1)
                safe_proof = result.report["stateProofs"][0]
                self.assertTrue(safe_proof["browserIdentity"])
                self.assertEqual(safe_proof["provenance"], "launch-observed")
                self.assertGreater(safe_proof["processIdentifier"], 0)
                self.assertEqual(len(fixture.terminated_browser_generations), 1)
                self.assertTrue(result.report["cleanup_success"])
                self.assertTrue(result.report["task_root_finalized"])
                self.assertFalse(fixture.task_root.exists())
                if expected_outcome == "receipt-timeout":
                    proof = safe_proof
                    self.assertEqual(proof["state"], "cold")
                    self.assertEqual(proof["session"], "session_cold_0000")
                    self.assertEqual(proof["request"], "request_cold_0000")
                    self.assertEqual(proof["outcome"], "receipt-timeout")
                    self.assertFalse(proof["receipt"])
                    self.assertTrue(proof["browserIdentity"])
                    self.assertEqual(proof["provenance"], "launch-observed")
                    self.assertGreater(proof["processIdentifier"], 0)
                for pid in fixture.terminated_browser_pids:
                    with self.assertRaises(ProcessLookupError):
                        os.kill(pid, 0)

    def test_driver_sequence_identity_timeout_has_no_cleanup_authority_or_signal(self):
        with DriverFixture(
            receipt_without_browser=True,
            spawn_browser=False,
            timeout=1.0,
            proof_deadline_phase="helper-and-receipt",
        ) as fixture:
            result = fixture.run(
                config_overrides={
                    "state": "sequence",
                    "route_count": 3,
                    "session_nonce": "session_cold_0000",
                    "sequence_sessions": (
                        "session_cold_0000",
                        "session_running_0",
                        "session_reopen_00",
                    ),
                    "sequence_requests": (
                        "request_cold_0000",
                        "request_running_0",
                        "request_reopen_00",
                    ),
                }
            )
            self.assertEqual(result.exit_code, driver.DRIVER_BROWSER_IDENTITY_TIMEOUT)
            self.assertEqual(result.report["outcome"], "browser-identity-timeout")
            self.assertEqual(fixture.terminated_browser_pids, [])
            self.assertTrue(result.report["cleanup_success"])
            self.assertFalse(fixture.task_root.exists())

    def test_driver_sequence_cleanup_failure_overrides_helper_primary_outcome(self):
        with DriverFixture(
            helper_hangs_after_delivery=True,
            proof_deadline_phase="receipt-delivered",
            browser_survives_termination=True,
            timeout=2.0,
        ) as fixture:
            result = fixture.run(
                config_overrides={
                    "state": "sequence",
                    "route_count": 3,
                    "session_nonce": "session_cold_0000",
                    "sequence_sessions": (
                        "session_cold_0000",
                        "session_running_0",
                        "session_reopen_00",
                    ),
                    "sequence_requests": (
                        "request_cold_0000",
                        "request_running_0",
                        "request_reopen_00",
                    ),
                }
            )
            self.assertEqual(result.exit_code, driver.DRIVER_CLEANUP_FAILURE)
            self.assertEqual(result.report["outcome"], "cleanup-error")
            self.assertFalse(result.report["cleanup_success"])
            self.assertTrue(result.report["task_root_finalized"])

    def test_driver_sequence_preserves_exact_catalog_refusal_as_unsupported_proof(self):
        for refusal in ("target-disabled", "target-missing", "target-mode-mismatch"):
            with (
                self.subTest(refusal=refusal),
                DriverFixture(
                    status_records=[{"session": "$session", "outcome": refusal}],
                    spawn_browser=False,
                ) as fixture,
            ):
                result = fixture.run(
                    config_overrides={
                        "state": "sequence",
                        "route_count": 3,
                        "session_nonce": "session_cold_0000",
                        "sequence_sessions": (
                            "session_cold_0000",
                            "session_running_0",
                            "session_reopen_00",
                        ),
                        "sequence_requests": (
                            "request_cold_0000",
                            "request_running_0",
                            "request_reopen_00",
                        ),
                    }
                )
                self.assertEqual(result.exit_code, driver.DRIVER_SELECTION_REJECTED)
                self.assertEqual(result.report["outcome"], refusal)
                self.assertFalse(result.report["token_received"])
                self.assertFalse(result.report["exact_browser_process_identity"])
                self.assertEqual(result.report["launch_provenance"], "none")
                self.assertEqual(len(result.report["stateProofs"]), 1)
                proof = result.report["stateProofs"][0]
                self.assertEqual(proof["outcome"], refusal)
                self.assertEqual(proof["session"], "session_cold_0000")
                self.assertFalse(proof["browserIdentity"])
                self.assertIsNone(proof["processIdentifier"])
                self.assertEqual(fixture.terminated_browser_pids, [])
                self.assertTrue(result.report["cleanup_success"])
                self.assertFalse(fixture.task_root.exists())

    def _metadata_on_device(self, metadata, device):
        return types.SimpleNamespace(
            st_mode=metadata.st_mode,
            st_ino=metadata.st_ino,
            st_dev=device,
            st_uid=metadata.st_uid,
            st_size=metadata.st_size,
            st_mtime_ns=metadata.st_mtime_ns,
            st_ctime_ns=metadata.st_ctime_ns,
        )

    def _swap_pinned_root(self, pinned):
        path = pinned.path
        original = path.with_name(f"{path.name}-original")
        path.rename(original)
        path.mkdir(mode=0o700)
        marker = path / "replacement-must-survive"
        marker.write_bytes(b"replacement")
        return path, original, marker

    def _clean_swapped_roots(self, pinned, path, original):
        pinned.close()
        for candidate in (path, original):
            if candidate.exists():
                shutil.rmtree(candidate)

    def test_task_root_pin_failure_never_deletes_open_time_replacement(self):
        created = {}
        real_mkdtemp = tempfile.mkdtemp
        real_open = os.open

        def make_root(*args, **kwargs):
            path = pathlib.Path(real_mkdtemp(*args, **kwargs))
            created["path"] = path
            return os.fspath(path)

        def swap_before_open(path, flags, *args, **kwargs):
            candidate = pathlib.Path(path)
            if (
                "path" in created
                and candidate == created["path"]
                and "original" not in created
            ):
                original = candidate.with_name(f"{candidate.name}-original")
                candidate.rename(original)
                candidate.mkdir(mode=0o700)
                marker = candidate / "replacement-must-survive"
                marker.write_bytes(b"replacement")
                created.update(original=original, marker=marker)
            return real_open(path, flags, *args, **kwargs)

        try:
            with (
                mock.patch("tempfile.mkdtemp", side_effect=make_root),
                mock.patch("os.open", side_effect=swap_before_open),
            ):
                with self.assertRaises(OSError):
                    self._make_task_root()
            self.assertEqual(created["marker"].read_bytes(), b"replacement")
            self.assertTrue(created["original"].exists())
        finally:
            for key in ("path", "original"):
                candidate = created.get(key)
                if candidate is not None and candidate.exists():
                    shutil.rmtree(candidate)

    def test_task_root_fchmod_interrupt_closes_descriptor_and_removes_root(self):
        created = {"descriptors": []}
        real_mkdtemp = tempfile.mkdtemp
        real_open = os.open

        def make_root(*args, **kwargs):
            path = pathlib.Path(real_mkdtemp(*args, **kwargs))
            created["path"] = path
            return os.fspath(path)

        def record_open(*args, **kwargs):
            descriptor = real_open(*args, **kwargs)
            created["descriptors"].append(descriptor)
            return descriptor

        def interrupt(_descriptor, _mode):
            raise driver._DriverInterrupted

        try:
            with (
                mock.patch("tempfile.mkdtemp", side_effect=make_root),
                mock.patch("os.open", side_effect=record_open),
                mock.patch("os.fchmod", side_effect=interrupt),
            ):
                with self.assertRaises(driver._DriverInterrupted):
                    self._make_task_root()
            self.assertFalse(created["path"].exists())
            self.assertGreaterEqual(len(created["descriptors"]), 2)
            for descriptor in created["descriptors"]:
                with self.assertRaises(OSError):
                    os.fstat(descriptor)
        finally:
            path = created.get("path")
            if path is not None and path.exists():
                shutil.rmtree(path)
            for descriptor in created["descriptors"]:
                try:
                    os.close(descriptor)
                except OSError:
                    pass

    def test_task_root_remove_uses_bounded_native_exclusive_finalizer(self):
        pinned = self._make_task_root()
        (pinned.path / "owned").write_bytes(b"owned")
        real_run = subprocess.run
        observed = []

        def record_run(arguments, *args, **kwargs):
            if len(arguments) == 13 and arguments[3] == pinned.path.name:
                observed.append(("root-empty", os.listdir(pinned.descriptor)))
            observed.append((tuple(map(os.fspath, arguments)), dict(kwargs)))
            return real_run(arguments, *args, **kwargs)

        with (
            mock.patch.object(driver.subprocess, "run", side_effect=record_run),
            mock.patch.object(
                driver,
                "_empty_task_root_fingerprint",
                wraps=driver._empty_task_root_fingerprint,
            ) as fingerprint,
        ):
            self.assertTrue(pinned.remove())
        self.assertFalse(pinned.path.exists())
        self.assertEqual(fingerprint.call_count, 2)
        compile_calls = [
            call for call in observed if call[0][:2] == ("/usr/bin/xcrun", "clang")
        ]
        self.assertLessEqual(len(compile_calls), 1)
        if compile_calls:
            self.assertEqual(float(compile_calls[0][1]["timeout"]), 10.0)
        helper_calls = [
            call
            for call in observed
            if isinstance(call[0], tuple)
            and len(call[0]) == 13
            and call[0][3] == pinned.path.name
        ]
        self.assertEqual(len(helper_calls), 1)
        self.assertIn(("root-empty", []), observed)
        helper_arguments, helper_options = helper_calls[0]
        self.assertEqual(float(helper_options["timeout"]), 2.0)
        self.assertEqual(
            set(helper_options["pass_fds"]),
            {pinned.parent_descriptor, pinned.descriptor},
        )
        self.assertNotIn("PICKVIA_PARENT_SENTINEL_SECRET", helper_options["env"])
        self.assertTrue(helper_arguments[3].startswith("pickvia-e2e-"))
        self.assertTrue(helper_arguments[4].startswith(".pickvia-finalize-"))
        self.assertEqual(
            pathlib.Path(helper_arguments[0]).parent.parent.name,
            "browser-e2e-tools",
        )

    def test_task_root_owner_clears_successful_root_for_repeated_trap(self):
        owner = driver._TaskRootOwner()
        pinned = driver._make_task_root(owner)
        path = pinned.path
        self.assertTrue(owner.cleanup())
        self.assertIsNone(owner.root)
        self.assertFalse(path.exists())
        self.assertTrue(owner.cleanup())

    def test_native_finalizer_timeout_preserves_root_and_fails_closed(self):
        pinned = self._make_task_root()
        try:
            with mock.patch.object(
                driver.subprocess,
                "run",
                side_effect=subprocess.TimeoutExpired(["/usr/bin/xcrun", "clang"], 10),
            ):
                self.assertFalse(pinned.remove())
            self.assertTrue(pinned.path.is_dir())
        finally:
            pinned.close()
            if pinned.path.exists():
                shutil.rmtree(pinned.path)

    def test_poisoned_cached_helper_is_rejected_and_owned_root_is_preserved(self):
        cache_repository = pathlib.Path(
            tempfile.mkdtemp(
                prefix="pickvia-cleanup-cache-fixture-", dir="/private/tmp"
            )
        )
        pinned = self._make_task_root()
        owner = driver._TaskRootOwner()
        owner.register(pinned)
        try:
            with mock.patch.object(
                driver,
                "_cleanup_cache_repository",
                return_value=cache_repository,
            ):
                helper = driver._pin_exclusive_cleanup_helper()
                helper.close()
                records = list(
                    (cache_repository / ".build-e2e" / "browser-e2e-tools").glob(
                        "exclusive-cleanup-*"
                    )
                )
                self.assertEqual(len(records), 1)
                cached_executable = records[0] / "helper"
                cached_executable.unlink()
                shutil.copyfile("/usr/bin/true", cached_executable)
                cached_executable.chmod(0o700)
                self.assertFalse(owner.cleanup())
            self.assertIs(owner.root, pinned)
            self.assertTrue(pinned.path.is_dir())
        finally:
            pinned.close()
            if pinned.path.exists():
                shutil.rmtree(pinned.path)
            shutil.rmtree(cache_repository)

    def test_false_exit_zero_helper_fails_postcondition_and_preserves_root(self):
        pinned = self._make_task_root()
        owner = driver._TaskRootOwner()
        owner.register(pinned)
        helper = mock.Mock(path=pathlib.Path("/usr/bin/true"))
        helper.validate.return_value = True
        try:
            with mock.patch.object(
                driver, "_pin_exclusive_cleanup_helper", return_value=helper
            ):
                self.assertFalse(owner.cleanup())
            self.assertIs(owner.root, pinned)
            self.assertTrue(pinned.path.is_dir())
            self.assertEqual(list(pinned.path.iterdir()), [])
        finally:
            pinned.close()
            if pinned.path.exists():
                shutil.rmtree(pinned.path)

    def test_concurrent_cache_publish_never_deletes_unknown_staging_entry(self):
        cache_repository = pathlib.Path(
            tempfile.mkdtemp(prefix="pickvia-cleanup-cache-race-", dir="/private/tmp")
        )
        try:
            with mock.patch.object(
                driver,
                "_cleanup_cache_repository",
                return_value=cache_repository,
            ):
                source_digest = driver._stable_cleanup_source_digest()
                cache_path, cache_descriptor = driver._open_owned_cache_directory()

                def collide_with_unknown(descriptor, staging_name, _record_name):
                    staging_descriptor = os.open(
                        staging_name,
                        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                        dir_fd=descriptor,
                    )
                    try:
                        unknown = os.open(
                            "unknown-must-survive",
                            os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                            0o600,
                            dir_fd=staging_descriptor,
                        )
                        os.close(unknown)
                    finally:
                        os.close(staging_descriptor)
                    raise FileExistsError(errno.EEXIST, "injected collision")

                try:
                    with mock.patch.object(
                        driver,
                        "_rename_at_exclusive",
                        side_effect=collide_with_unknown,
                    ):
                        with self.assertRaises(OSError):
                            driver._publish_cleanup_helper(
                                cache_path,
                                cache_descriptor,
                                source_digest,
                                f"exclusive-cleanup-record-{source_digest}",
                            )
                    staging = list(cache_path.glob(".exclusive-cleanup-staging-*"))
                    self.assertEqual(len(staging), 1)
                    self.assertTrue((staging[0] / "unknown-must-survive").is_file())
                    self.assertTrue((staging[0] / "helper").is_file())
                    self.assertTrue((staging[0] / "record.json").is_file())
                finally:
                    os.close(cache_descriptor)
        finally:
            shutil.rmtree(cache_repository)

    def test_file_added_between_empty_passes_blocks_native_helper(self):
        pinned = self._make_task_root()
        helper = mock.Mock(path=pathlib.Path("/usr/bin/false"))
        helper.validate.return_value = True
        real_fingerprint = driver._empty_task_root_fingerprint
        calls = 0

        def add_after_first(task_root, budget):
            nonlocal calls
            fingerprint = real_fingerprint(task_root, budget)
            calls += 1
            if calls == 1:
                (pinned.path / "late-file").write_bytes(b"preserve")
            return fingerprint

        try:
            with (
                mock.patch.object(
                    driver, "_pin_exclusive_cleanup_helper", return_value=helper
                ),
                mock.patch.object(
                    driver, "_empty_task_root_fingerprint", side_effect=add_after_first
                ),
                mock.patch.object(driver, "_invoke_exclusive_cleanup_helper") as invoke,
            ):
                self.assertFalse(pinned.remove())
            invoke.assert_not_called()
            self.assertEqual((pinned.path / "late-file").read_bytes(), b"preserve")
        finally:
            pinned.close()
            if pinned.path.exists():
                shutil.rmtree(pinned.path)

    def test_transient_file_growth_between_empty_passes_blocks_native_helper(self):
        pinned = self._make_task_root()
        helper = mock.Mock(path=pathlib.Path("/usr/bin/false"))
        helper.validate.return_value = True
        real_fingerprint = driver._empty_task_root_fingerprint
        calls = 0

        def grow_after_first(task_root, budget):
            nonlocal calls
            fingerprint = real_fingerprint(task_root, budget)
            calls += 1
            if calls == 1:
                transient = pinned.path / "transient"
                transient.write_bytes(b"x")
                with transient.open("ab") as stream:
                    stream.write(b"growth")
                transient.unlink()
            return fingerprint

        try:
            with (
                mock.patch.object(
                    driver, "_pin_exclusive_cleanup_helper", return_value=helper
                ),
                mock.patch.object(
                    driver, "_empty_task_root_fingerprint", side_effect=grow_after_first
                ),
                mock.patch.object(driver, "_invoke_exclusive_cleanup_helper") as invoke,
            ):
                self.assertFalse(pinned.remove())
            invoke.assert_not_called()
            self.assertTrue(pinned.path.is_dir())
        finally:
            pinned.close()
            if pinned.path.exists():
                shutil.rmtree(pinned.path)

    def test_root_replacement_between_empty_passes_blocks_native_helper(self):
        pinned = self._make_task_root()
        helper = mock.Mock(path=pathlib.Path("/usr/bin/false"))
        helper.validate.return_value = True
        real_fingerprint = driver._empty_task_root_fingerprint
        calls = 0
        original = pinned.path.with_name(f"{pinned.path.name}-original")

        def replace_after_first(task_root, budget):
            nonlocal calls
            fingerprint = real_fingerprint(task_root, budget)
            calls += 1
            if calls == 1:
                pinned.path.rename(original)
                pinned.path.mkdir(mode=0o700)
                (pinned.path / "replacement-must-survive").write_bytes(b"replacement")
            return fingerprint

        try:
            with (
                mock.patch.object(
                    driver, "_pin_exclusive_cleanup_helper", return_value=helper
                ),
                mock.patch.object(
                    driver,
                    "_empty_task_root_fingerprint",
                    side_effect=replace_after_first,
                ),
                mock.patch.object(driver, "_invoke_exclusive_cleanup_helper") as invoke,
            ):
                self.assertFalse(pinned.remove())
            invoke.assert_not_called()
            self.assertEqual(
                (pinned.path / "replacement-must-survive").read_bytes(),
                b"replacement",
            )
            self.assertTrue(original.is_dir())
        finally:
            pinned.close()
            for candidate in (pinned.path, original):
                if candidate.exists():
                    shutil.rmtree(candidate)

    def test_task_root_second_fstat_interrupt_closes_both_fds_and_removes_root(self):
        created = {"descriptors": [], "fstat_calls": 0}
        real_mkdtemp = tempfile.mkdtemp
        real_open = os.open
        real_fstat = os.fstat

        def make_root(*args, **kwargs):
            path = pathlib.Path(real_mkdtemp(*args, **kwargs))
            created["path"] = path
            return os.fspath(path)

        def record_open(*args, **kwargs):
            descriptor = real_open(*args, **kwargs)
            created["descriptors"].append(descriptor)
            return descriptor

        def interrupt_second_fstat(descriptor):
            created["fstat_calls"] += 1
            if created["fstat_calls"] == 2:
                raise driver._DriverInterrupted
            return real_fstat(descriptor)

        try:
            with (
                mock.patch("tempfile.mkdtemp", side_effect=make_root),
                mock.patch("os.open", side_effect=record_open),
                mock.patch("os.fstat", side_effect=interrupt_second_fstat),
            ):
                with self.assertRaises(driver._DriverInterrupted):
                    self._make_task_root()
            self.assertFalse(created["path"].exists())
            self.assertGreaterEqual(len(created["descriptors"]), 2)
            for descriptor in created["descriptors"]:
                with self.assertRaises(OSError):
                    os.fstat(descriptor)
        finally:
            path = created.get("path")
            if path is not None and path.exists():
                shutil.rmtree(path)
            for descriptor in created["descriptors"]:
                try:
                    os.close(descriptor)
                except OSError:
                    pass

    def test_task_root_open_interrupt_preserves_replacement_and_closes_parent_fd(self):
        created = {"descriptors": []}
        real_mkdtemp = tempfile.mkdtemp
        real_open = os.open

        def make_root(*args, **kwargs):
            path = pathlib.Path(real_mkdtemp(*args, **kwargs))
            created["path"] = path
            return os.fspath(path)

        def interrupt_root_open(path, flags, *args, **kwargs):
            candidate = pathlib.Path(path)
            if "path" in created and candidate == created["path"]:
                original = candidate.with_name(f"{candidate.name}-original")
                candidate.rename(original)
                candidate.mkdir(mode=0o700)
                marker = candidate / "replacement-must-survive"
                marker.write_bytes(b"replacement")
                created.update(original=original, marker=marker)
                raise driver._DriverInterrupted
            descriptor = real_open(path, flags, *args, **kwargs)
            created["descriptors"].append(descriptor)
            return descriptor

        try:
            with (
                mock.patch("tempfile.mkdtemp", side_effect=make_root),
                mock.patch("os.open", side_effect=interrupt_root_open),
            ):
                with self.assertRaises(driver._DriverInterrupted):
                    self._make_task_root()
            self.assertEqual(created["marker"].read_bytes(), b"replacement")
            self.assertTrue(created["original"].exists())
            self.assertEqual(len(created["descriptors"]), 1)
            with self.assertRaises(OSError):
                os.fstat(created["descriptors"][0])
        finally:
            for key in ("path", "original"):
                candidate = created.get(key)
                if candidate is not None and candidate.exists():
                    shutil.rmtree(candidate)
            for descriptor in created["descriptors"]:
                try:
                    os.close(descriptor)
                except OSError:
                    pass

    def test_signal_after_mkdtemp_return_is_deferred_until_root_is_owned(self):
        created = {}
        real_mkdtemp = tempfile.mkdtemp

        def interrupt_after_create(*args, **kwargs):
            path = pathlib.Path(real_mkdtemp(*args, **kwargs))
            created["path"] = path
            os.kill(os.getpid(), signal.SIGINT)
            return os.fspath(path)

        with (
            DriverFixture() as fixture,
            mock.patch("tempfile.mkdtemp", side_effect=interrupt_after_create),
        ):
            result = fixture.run()
            self.assertEqual(result.exit_code, driver.DRIVER_PROCESS_ERROR)
            self.assertEqual(result.report["outcome"], "driver-error")
            self.assertFalse(created["path"].exists())

    def test_signal_after_root_open_return_is_deferred_until_fd_is_owned(self):
        created = {}
        real_open = os.open

        def interrupt_after_open(path, flags, *args, **kwargs):
            descriptor = real_open(path, flags, *args, **kwargs)
            candidate = pathlib.Path(path)
            if candidate.name.startswith("pickvia-e2e-"):
                created.update(path=candidate, descriptor=descriptor)
                os.kill(os.getpid(), signal.SIGTERM)
            return descriptor

        with (
            DriverFixture() as fixture,
            mock.patch("os.open", side_effect=interrupt_after_open),
        ):
            result = fixture.run()
            self.assertEqual(result.exit_code, driver.DRIVER_PROCESS_ERROR)
            self.assertEqual(result.report["outcome"], "driver-error")
            self.assertFalse(created["path"].exists())
            with self.assertRaises(OSError):
                os.fstat(created["descriptor"])

    def test_signal_after_owner_registration_cleans_before_caller_store(self):
        observed = {}

        def interrupt_after_register(owner, root):
            owner._register_without_signal_test_hook(root)
            observed["path"] = root.path
            os.kill(os.getpid(), signal.SIGHUP)

        with (
            DriverFixture() as fixture,
            mock.patch.object(
                driver._TaskRootOwner,
                "register",
                autospec=True,
                side_effect=interrupt_after_register,
            ),
        ):
            result = fixture.run()
            self.assertEqual(result.exit_code, driver.DRIVER_PROCESS_ERROR)
            self.assertEqual(result.report["outcome"], "driver-error")
            self.assertFalse(observed["path"].exists())
            current_mask = signal.pthread_sigmask(signal.SIG_BLOCK, set())
            self.assertFalse(current_mask & driver._DEFERRED_SIGNALS)

    def test_signal_mask_block_return_exception_restores_known_previous_mask(self):
        owner = driver._TaskRootOwner()
        real_pthread_sigmask = signal.pthread_sigmask
        previous_mask = real_pthread_sigmask(signal.SIG_BLOCK, set())
        injected = False

        def interrupt_after_native_mask_change(operation, mask):
            nonlocal injected
            result = real_pthread_sigmask(operation, mask)
            if (
                not injected
                and operation == signal.SIG_BLOCK
                and set(mask) == set(driver._DEFERRED_SIGNALS)
            ):
                injected = True
                raise driver._DriverInterrupted
            return result

        try:
            with (
                mock.patch(
                    "signal.pthread_sigmask",
                    side_effect=interrupt_after_native_mask_change,
                ),
                mock.patch("os.open") as opened,
                mock.patch("tempfile.mkdtemp") as made_root,
            ):
                with self.assertRaises(driver._DriverInterrupted):
                    driver._make_task_root(owner)
            current_mask = real_pthread_sigmask(signal.SIG_BLOCK, set())
            for signum in driver._DEFERRED_SIGNALS:
                self.assertEqual(signum in current_mask, signum in previous_mask)
            self.assertIsNone(owner.root)
            opened.assert_not_called()
            made_root.assert_not_called()
        finally:
            real_pthread_sigmask(signal.SIG_SETMASK, previous_mask)

    def test_audit_rejects_recursive_device_boundary(self):
        pinned = self._make_task_root()
        boundary = pinned.path / "boundary"
        boundary.mkdir()
        real_stat = os.stat
        real_fstat = os.fstat

        def cross_device_stat(path, *args, **kwargs):
            metadata = real_stat(path, *args, **kwargs)
            if path == "boundary":
                return self._metadata_on_device(metadata, pinned.identity.device + 1)
            return metadata

        def cross_device_fstat(descriptor):
            metadata = real_fstat(descriptor)
            if descriptor != pinned.descriptor and stat.S_ISDIR(metadata.st_mode):
                return self._metadata_on_device(metadata, pinned.identity.device + 1)
            return metadata

        try:
            with (
                mock.patch("os.stat", side_effect=cross_device_stat),
                mock.patch("os.fstat", side_effect=cross_device_fstat),
            ):
                self.assertFalse(pinned.audit_regular_files(b"forbidden"))
        finally:
            pinned.close()
            shutil.rmtree(pinned.path)

    def test_cleanup_rejects_recursive_device_boundary_without_touching_it(self):
        pinned = self._make_task_root()
        boundary = pinned.path / "boundary"
        boundary.mkdir()
        marker = boundary / "must-survive"
        marker.write_bytes(b"replacement")
        real_stat = os.stat
        real_fstat = os.fstat

        def cross_device_stat(path, *args, **kwargs):
            metadata = real_stat(path, *args, **kwargs)
            if path == "boundary":
                return self._metadata_on_device(metadata, pinned.identity.device + 1)
            return metadata

        def cross_device_fstat(descriptor):
            metadata = real_fstat(descriptor)
            if descriptor != pinned.descriptor and stat.S_ISDIR(metadata.st_mode):
                return self._metadata_on_device(metadata, pinned.identity.device + 1)
            return metadata

        try:
            with (
                mock.patch("os.stat", side_effect=cross_device_stat),
                mock.patch("os.fstat", side_effect=cross_device_fstat),
            ):
                self.assertFalse(pinned.remove())
            self.assertEqual(marker.read_bytes(), b"replacement")
        finally:
            pinned.close()
            if pinned.path.exists():
                shutil.rmtree(pinned.path)

    def test_audit_detects_file_added_after_initial_directory_listing(self):
        pinned = self._make_task_root()
        (pinned.path / "initial").write_bytes(b"safe")
        real_scandir = os.scandir
        calls = 0

        def add_before_rescan(descriptor):
            nonlocal calls
            if descriptor == pinned.descriptor:
                calls += 1
                if calls == 2:
                    (pinned.path / "late").write_bytes(b"late")
            return real_scandir(descriptor)

        try:
            with mock.patch("os.scandir", side_effect=add_before_rescan):
                self.assertFalse(pinned.audit_regular_files(b"forbidden"))
        finally:
            pinned.close()
            shutil.rmtree(pinned.path)

    def test_audit_detects_file_added_after_final_listing_before_return(self):
        pinned = self._make_task_root()
        (pinned.path / "initial").write_bytes(b"safe")
        real_scandir = os.scandir
        root_scans = 0

        class AddAfterIteration:
            def __init__(self, iterator, add_file):
                self.iterator = iterator
                self.add_file = add_file

            def __enter__(self):
                return self

            def __exit__(self, *_args):
                self.iterator.close()
                return False

            def __iter__(self):
                return self

            def __next__(self):
                try:
                    return next(self.iterator)
                except StopIteration:
                    if self.add_file:
                        self.add_file = False
                        (pinned.path / "late").write_bytes(b"late")
                    raise

        def add_after_final_listing(descriptor):
            nonlocal root_scans
            iterator = real_scandir(descriptor)
            if descriptor == pinned.descriptor:
                root_scans += 1
            return AddAfterIteration(iterator, root_scans == 2)

        try:
            with mock.patch("os.scandir", side_effect=add_after_final_listing):
                self.assertFalse(pinned.audit_regular_files(b"forbidden"))
        finally:
            pinned.close()
            shutil.rmtree(pinned.path)

    def test_audit_requires_two_matching_bracketed_tree_passes(self):
        pinned = self._make_task_root()
        (pinned.path / "stable").write_bytes(b"safe")
        real_scandir = os.scandir
        root_scans = 0

        def count_root_scans(descriptor):
            nonlocal root_scans
            if descriptor == pinned.descriptor:
                root_scans += 1
            return real_scandir(descriptor)

        try:
            with mock.patch("os.scandir", side_effect=count_root_scans):
                self.assertTrue(pinned.audit_regular_files(b"forbidden"))
            self.assertGreaterEqual(root_scans, 4)
        finally:
            pinned.close()
            shutil.rmtree(pinned.path)

    def test_audit_enforces_entry_and_repeated_work_budgets(self):
        pinned = self._make_task_root()
        (pinned.path / "one").write_bytes(b"123")
        (pinned.path / "two").write_bytes(b"456")
        try:
            with mock.patch.object(driver, "MAXIMUM_AUDIT_ENTRIES", 1):
                self.assertFalse(pinned.audit_regular_files(b"forbidden"))
            with mock.patch.object(driver, "MAXIMUM_AUDIT_WORK_BYTES", 10):
                self.assertFalse(pinned.audit_regular_files(b"forbidden"))
        finally:
            pinned.close()
            shutil.rmtree(pinned.path)

    def test_audit_enforces_deadline_during_bracketed_passes(self):
        pinned = self._make_task_root()
        (pinned.path / "stable").write_bytes(b"safe")
        clock_calls = 0

        def expired_clock():
            nonlocal clock_calls
            clock_calls += 1
            return 0.0 if clock_calls <= 2 else 3.0

        try:
            with mock.patch("time.monotonic", side_effect=expired_clock):
                self.assertFalse(pinned.audit_regular_files(b"forbidden"))
        finally:
            pinned.close()
            shutil.rmtree(pinned.path)

    def test_audit_enumeration_charges_entry_cap_incrementally(self):
        pinned = self._make_task_root()
        metadata = (pinned.path / ".").stat()

        class ManyEntries:
            def __init__(self):
                self.yielded = 0

            def __enter__(self):
                return self

            def __exit__(self, *_args):
                return False

            def __iter__(self):
                return self

            def __next__(self):
                self.yielded += 1
                return types.SimpleNamespace(name=f"entry-{self.yielded}")

        entries = ManyEntries()
        budget = driver._AuditBudget(time.monotonic() + 1.0)
        audit_pass = driver._AuditPass()
        try:
            with (
                mock.patch("os.scandir", return_value=entries),
                mock.patch("os.stat", return_value=metadata),
                mock.patch.object(driver, "MAXIMUM_AUDIT_ENTRIES", 3),
            ):
                with self.assertRaises(OSError):
                    driver._snapshot_directory_at(
                        pinned.descriptor,
                        pinned.identity.device,
                        budget,
                        audit_pass,
                        count_toward_tree=True,
                    )
            self.assertEqual(entries.yielded, 4)
        finally:
            pinned.close()
            shutil.rmtree(pinned.path)

    def test_audit_enumeration_checks_deadline_per_entry(self):
        pinned = self._make_task_root()
        metadata = (pinned.path / ".").stat()
        clock_calls = 0

        class SlowEntries:
            def __init__(self):
                self.yielded = 0

            def __enter__(self):
                return self

            def __exit__(self, *_args):
                return False

            def __iter__(self):
                return self

            def __next__(self):
                self.yielded += 1
                return types.SimpleNamespace(name=f"entry-{self.yielded}")

        def clock():
            nonlocal clock_calls
            clock_calls += 1
            return 0.0 if clock_calls <= 4 else 3.0

        entries = SlowEntries()
        budget = driver._AuditBudget(2.0)
        audit_pass = driver._AuditPass()
        try:
            with (
                mock.patch("os.scandir", return_value=entries),
                mock.patch("os.stat", return_value=metadata),
                mock.patch("time.monotonic", side_effect=clock),
            ):
                with self.assertRaises(OSError):
                    driver._snapshot_directory_at(
                        pinned.descriptor,
                        pinned.identity.device,
                        budget,
                        audit_pass,
                        count_toward_tree=True,
                    )
            self.assertLessEqual(entries.yielded, 4)
        finally:
            pinned.close()
            shutil.rmtree(pinned.path)

    def test_audit_detects_file_growth_during_content_scan(self):
        pinned = self._make_task_root()
        target = pinned.path / "growing"
        target.write_bytes(b"safe")
        real_fstat = os.fstat
        regular_fstats = 0

        def grow_before_final_fstat(descriptor):
            nonlocal regular_fstats
            metadata = real_fstat(descriptor)
            if stat.S_ISREG(metadata.st_mode):
                regular_fstats += 1
                if regular_fstats == 2:
                    with target.open("ab") as stream:
                        stream.write(b"growth")
                    metadata = real_fstat(descriptor)
            return metadata

        try:
            with mock.patch("os.fstat", side_effect=grow_before_final_fstat):
                self.assertFalse(pinned.audit_regular_files(b"forbidden"))
        finally:
            pinned.close()
            shutil.rmtree(pinned.path)

    def test_audit_enforces_cumulative_regular_file_byte_cap(self):
        pinned = self._make_task_root()
        (pinned.path / "one").write_bytes(b"123")
        (pinned.path / "two").write_bytes(b"456")
        try:
            with mock.patch.object(driver, "MAXIMUM_AUDIT_FILE_BYTES", 5):
                self.assertFalse(pinned.audit_regular_files(b"forbidden"))
        finally:
            pinned.close()
            shutil.rmtree(pinned.path)

    def test_child_cleanup_operation_time_swap_preserves_replacement(self):
        pinned = self._make_task_root()
        (pinned.path / "owned").write_bytes(b"owned")
        real_rename = os.rename
        swapped = {}

        def swap_quarantined_child(source, destination, *args, **kwargs):
            result = real_rename(source, destination, *args, **kwargs)
            if source == "owned" and str(destination).startswith(".pickvia-cleanup-"):
                held = ".pickvia-held-original"
                real_rename(
                    destination,
                    held,
                    src_dir_fd=pinned.descriptor,
                    dst_dir_fd=pinned.descriptor,
                )
                replacement = os.open(
                    destination,
                    os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                    0o600,
                    dir_fd=pinned.descriptor,
                )
                try:
                    os.write(replacement, b"replacement")
                finally:
                    os.close(replacement)
                swapped.update(held=held, quarantine=destination)
            return result

        try:
            with mock.patch("os.rename", side_effect=swap_quarantined_child):
                self.assertFalse(pinned.remove())
            self.assertEqual((pinned.path / "owned").read_bytes(), b"replacement")
            self.assertEqual((pinned.path / swapped["held"]).read_bytes(), b"owned")
        finally:
            pinned.close()
            if pinned.path.exists():
                shutil.rmtree(pinned.path)

    def test_root_cleanup_operation_time_swap_preserves_replacement(self):
        pinned = self._make_task_root()
        swapped = {}

        real_run = subprocess.run

        def replace_after_exclusive_rename(arguments, *args, **kwargs):
            if len(arguments) == 13 and arguments[3] == pinned.path.name:
                quarantine = pathlib.Path("/private/tmp") / arguments[4]
                pinned.path.rename(quarantine)
                pinned.path.mkdir(mode=0o700)
                marker = pinned.path / "replacement-must-survive"
                marker.write_bytes(b"replacement")
                swapped.update(held=quarantine, marker=marker)
                return subprocess.CompletedProcess(arguments, 70)
            return real_run(arguments, *args, **kwargs)

        try:
            with mock.patch.object(
                driver.subprocess, "run", side_effect=replace_after_exclusive_rename
            ):
                self.assertFalse(pinned.remove())
            self.assertEqual(swapped["marker"].read_bytes(), b"replacement")
            self.assertTrue(swapped["held"].exists())
        finally:
            pinned.close()
            if pinned.path.exists():
                shutil.rmtree(pinned.path)
            held = swapped.get("held")
            if held is not None and held.exists():
                shutil.rmtree(held)

    def test_pinned_task_root_rejects_replacement_before_fifo_setup(self):
        pinned = self._make_task_root()
        path, original, marker = self._swap_pinned_root(pinned)
        try:
            with self.assertRaises(OSError):
                pinned.create_fifo("status.fifo")
            self.assertEqual(marker.read_bytes(), b"replacement")
            self.assertFalse((path / "status.fifo").exists())
        finally:
            self._clean_swapped_roots(pinned, path, original)

    def test_pinned_task_root_fifo_open_rejects_symlink_replacement(self):
        pinned = self._make_task_root()
        replacement = pinned.path / "replacement.fifo"
        try:
            pinned.create_fifo("provenance.fifo")
            os.mkfifo(replacement, 0o600)
            (pinned.path / "provenance.fifo").unlink()
            (pinned.path / "provenance.fifo").symlink_to(replacement)

            with self.assertRaises(OSError):
                pinned.open_fifo("provenance.fifo")
        finally:
            pinned.remove()

    def test_pinned_task_root_rejects_replacement_before_environment_handoff(self):
        pinned = self._make_task_root()
        path, original, marker = self._swap_pinned_root(pinned)
        try:
            with self.assertRaises(OSError):
                driver._minimal_child_environment(pinned)
            self.assertEqual(marker.read_bytes(), b"replacement")
        finally:
            self._clean_swapped_roots(pinned, path, original)

    def test_pinned_task_root_rejects_replacement_before_privacy_audit(self):
        pinned = self._make_task_root()
        (pinned.path / "owned").write_bytes(b"owned")
        path, original, marker = self._swap_pinned_root(pinned)
        try:
            self.assertFalse(pinned.audit_regular_files(b"forbidden"))
            self.assertEqual(marker.read_bytes(), b"replacement")
            self.assertEqual((original / "owned").read_bytes(), b"owned")
        finally:
            self._clean_swapped_roots(pinned, path, original)

    def test_pinned_task_root_cleanup_never_deletes_replacement_contents(self):
        pinned = self._make_task_root()
        (pinned.path / "owned").write_bytes(b"owned")
        path, original, marker = self._swap_pinned_root(pinned)
        try:
            self.assertFalse(pinned.remove())
            self.assertEqual(marker.read_bytes(), b"replacement")
            self.assertTrue(path.exists())
            self.assertTrue(original.exists())
            self.assertEqual(list(original.iterdir()), [])
        finally:
            self._clean_swapped_roots(pinned, path, original)

    def test_fixture_cleanup_revalidates_generation_before_signalling_pid_file(self):
        fixture = DriverFixture()
        self.addCleanup(fixture._remove_tree, fixture.fixture_root)
        fixture.e2e_pid = 222
        parent = driver.ProcessIdentity(222, 1, 1, 2, pathlib.Path("/usr/bin/python3"))
        fixture.e2e_identity = parent
        original = driver.ProcessIdentity(333, 222, 10, 20, pathlib.Path("/bin/sleep"))
        replacement = driver.ProcessIdentity(
            333, 999, 30, 40, pathlib.Path("/bin/other")
        )
        with mock.patch.object(
            driver,
            "_darwin_process_identity",
            side_effect=lambda pid: original if pid == 333 else parent,
        ):
            self.assertTrue(fixture._remember_fixture_child(333))
        with (
            mock.patch.object(
                driver, "_darwin_process_identity", return_value=replacement
            ),
            mock.patch("os.kill") as kill,
        ):
            fixture._terminate_remembered_fixture_children()
        kill.assert_not_called()

    def test_fixture_cleanup_rejects_unowned_pid_file_generation(self):
        fixture = DriverFixture()
        self.addCleanup(fixture._remove_tree, fixture.fixture_root)
        fixture.e2e_pid = 222
        fixture.e2e_identity = driver.ProcessIdentity(
            222, 1, 1, 2, pathlib.Path("/usr/bin/python3")
        )
        unrelated = driver.ProcessIdentity(333, 999, 10, 20, pathlib.Path("/bin/sleep"))
        with (
            mock.patch.object(
                driver, "_darwin_process_identity", return_value=unrelated
            ),
            mock.patch("os.kill") as kill,
        ):
            self.assertFalse(fixture._remember_fixture_child(333))
            fixture._terminate_remembered_fixture_children()
        kill.assert_not_called()

    def test_fixture_cleanup_signals_only_unchanged_owned_generation(self):
        fixture = DriverFixture()
        self.addCleanup(fixture._remove_tree, fixture.fixture_root)
        fixture.e2e_pid = 222
        parent = driver.ProcessIdentity(222, 1, 1, 2, pathlib.Path("/usr/bin/python3"))
        fixture.e2e_identity = parent
        owned = driver.ProcessIdentity(333, 222, 10, 20, pathlib.Path("/bin/sleep"))
        with mock.patch.object(
            driver,
            "_darwin_process_identity",
            side_effect=lambda pid: owned if pid == 333 else parent,
        ):
            self.assertTrue(fixture._remember_fixture_child(333))
            with mock.patch("os.kill") as kill:
                fixture._terminate_remembered_fixture_children()
        kill.assert_called_once_with(333, signal.SIGKILL)

    def test_fixture_cleanup_rejects_reused_e2e_parent_pid_generation(self):
        fixture = DriverFixture()
        self.addCleanup(fixture._remove_tree, fixture.fixture_root)
        fixture.e2e_pid = 222
        fixture.e2e_identity = driver.ProcessIdentity(
            222, 1, 10, 20, pathlib.Path("/usr/bin/python3")
        )
        child = driver.ProcessIdentity(333, 222, 30, 40, pathlib.Path("/bin/sleep"))
        reused_parent = driver.ProcessIdentity(
            222, 1, 50, 60, pathlib.Path("/usr/bin/python3")
        )
        with mock.patch.object(
            driver,
            "_darwin_process_identity",
            side_effect=lambda pid: child if pid == 333 else reused_parent,
        ):
            self.assertFalse(fixture._remember_fixture_child(333))

    def test_fixture_cleanup_rejects_child_discovered_only_after_reparent(self):
        fixture = DriverFixture()
        self.addCleanup(fixture._remove_tree, fixture.fixture_root)
        fixture.e2e_pid = 222
        fixture.e2e_identity = driver.ProcessIdentity(
            222, 1, 10, 20, pathlib.Path("/usr/bin/python3")
        )
        reparented = driver.ProcessIdentity(333, 1, 30, 40, pathlib.Path("/bin/sleep"))
        with mock.patch.object(
            driver, "_darwin_process_identity", return_value=reparented
        ):
            self.assertFalse(fixture._remember_fixture_child(333))

    def test_run_reports_cleanup_error_and_preserves_swapped_replacement_root(self):
        with DriverFixture() as fixture:
            swapped = {}

            def replace_before_cleanup(root):
                path = pathlib.Path(root)
                original = path.with_name(f"{path.name}-original")
                path.rename(original)
                path.mkdir(mode=0o700)
                marker = path / "replacement-must-survive"
                marker.write_bytes(b"replacement")
                fixture.task_root = path
                swapped.update(path=path, original=original, marker=marker)

            result = fixture.run(
                dependency_overrides={
                    "before_cleanup": replace_before_cleanup,
                    "task_root_remover": driver._remove_task_root,
                }
            )
            self.assertEqual(result.exit_code, driver.DRIVER_CLEANUP_FAILURE)
            self.assertEqual(result.report["outcome"], "cleanup-error")
            self.assertEqual(swapped["marker"].read_bytes(), b"replacement")
            self.assertEqual(list(swapped["original"].iterdir()), [])
            swapped["original"].rmdir()

    def test_delayed_generation_after_final_sweep_is_observed_but_never_signalled(self):
        records = [{"session": "session_0123456789", "outcome": "target-missing"}]
        with DriverFixture(
            status_records=records,
            delayed_browser_after_final_sweep=True,
        ) as fixture:
            result = fixture.run()
            self.assertEqual(result.exit_code, driver.DRIVER_CLEANUP_FAILURE)
            self.assertEqual(result.report["outcome"], "cleanup-error")
            self.assertEqual(fixture.terminated_browser_pids, [])
            self.assertGreaterEqual(fixture.quiescence_snapshot_count, 2)

    def test_quiescence_preserves_quiet_and_preexisting_browser_baselines(self):
        records = [{"session": "session_0123456789", "outcome": "target-missing"}]
        for preexisting in (frozenset(), frozenset({41, 42})):
            with (
                self.subTest(preexisting=preexisting),
                DriverFixture(
                    status_records=records,
                    preexisting_browser_pids=preexisting,
                ) as fixture,
            ):
                result = fixture.run()
                self.assertEqual(result.exit_code, driver.DRIVER_SELECTION_REJECTED)
                self.assertEqual(fixture.terminated_browser_pids, [])
                self.assertGreaterEqual(fixture.quiescence_snapshot_count, 2)

    def test_repeated_late_generation_without_provenance_is_never_signalled(self):
        records = [{"session": "session_0123456789", "outcome": "target-missing"}]
        with DriverFixture(
            status_records=records,
            delayed_browser_after_final_sweep=True,
            repeated_delayed_browser=True,
        ) as fixture:
            result = fixture.run()
            self.assertEqual(result.exit_code, driver.DRIVER_CLEANUP_FAILURE)
            self.assertEqual(result.report["outcome"], "cleanup-error")
            self.assertEqual(fixture.terminated_browser_pids, [])

    def test_total_timing_reports_real_quiescence_bound(self):
        records = [{"session": "session_0123456789", "outcome": "target-missing"}]
        with DriverFixture(
            status_records=records,
            timeout=1.0,
            real_quiescence_clock=True,
        ) as fixture:
            result = fixture.run()
            self.assertEqual(result.report["browser_quiescence_seconds"], 2.0)
            self.assertGreaterEqual(result.report["total_elapsed_seconds"], 2.0)
            self.assertLessEqual(result.report["total_elapsed_seconds"], 8.0)

    def test_unknown_quiescence_snapshot_fails_closed_without_termination(self):
        records = [{"session": "session_0123456789", "outcome": "target-missing"}]
        with DriverFixture(
            status_records=records,
            snapshot_failures={"quiescence"},
        ) as fixture:
            result = fixture.run()
            self.assertEqual(result.exit_code, driver.DRIVER_CLEANUP_FAILURE)
            self.assertEqual(result.report["outcome"], "cleanup-error")
            self.assertEqual(fixture.terminated_browser_pids, [])

    def test_posttermination_replacement_generation_is_preserved_as_ambiguous(self):
        with DriverFixture(replacement_after_termination=True) as fixture:
            result = fixture.run()
            self.assertEqual(result.exit_code, driver.DRIVER_BROWSER_IDENTITY_AMBIGUOUS)
            self.assertEqual(result.report["outcome"], "identity-ambiguous")
            self.assertEqual(len(fixture.terminated_browser_generations), 1)
            self.assertNotIn(900, fixture.terminated_browser_pids)
            self.assertTrue(fixture.final_sweep_all_children_stopped)
            self.assertFalse(fixture.task_root.exists())

    def test_late_browser_after_process_close_is_observed_but_never_signalled(self):
        records = [{"session": "session_0123456789", "outcome": "target-missing"}]
        with DriverFixture(
            status_records=records, late_browser_after_close=True
        ) as fixture:
            result = fixture.run()
            self.assertEqual(result.exit_code, driver.DRIVER_CLEANUP_FAILURE)
            self.assertEqual(result.report["outcome"], "cleanup-error")
            self.assertEqual(fixture.terminated_browser_pids, [])
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

    def test_final_sweep_observes_reused_baseline_pid_without_signalling_it(self):
        records = [{"session": "session_0123456789", "outcome": "target-missing"}]
        with DriverFixture(
            status_records=records,
            preexisting_browser_pids={700},
            late_browser_after_close=True,
            late_pid_reuses_baseline=True,
        ) as fixture:
            result = fixture.run()
            self.assertEqual(result.exit_code, driver.DRIVER_CLEANUP_FAILURE)
            self.assertEqual(fixture.terminated_browser_pids, [])

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

    def test_unknown_final_sweep_revokes_late_generation_termination_authority(self):
        records = [{"session": "session_0123456789", "outcome": "target-missing"}]
        with DriverFixture(
            status_records=records,
            snapshot_failures={"final-sweep"},
            delayed_browser_after_final_sweep=True,
        ) as fixture:
            result = fixture.run()
            self.assertEqual(result.exit_code, driver.DRIVER_CLEANUP_FAILURE)
            self.assertEqual(result.report["outcome"], "cleanup-error")
            self.assertEqual(fixture.terminated_browser_pids, [])
            self.assertGreaterEqual(fixture.quiescence_snapshot_count, 2)

    def test_late_generation_keeps_quiescence_read_only(self):
        records = [{"session": "session_0123456789", "outcome": "target-missing"}]
        with DriverFixture(
            status_records=records,
            late_browser_after_close=True,
        ) as fixture:
            result = fixture.run()
            self.assertEqual(result.exit_code, driver.DRIVER_CLEANUP_FAILURE)
            self.assertEqual(result.report["outcome"], "cleanup-error")
            self.assertEqual(fixture.terminated_browser_pids, [])
            self.assertGreaterEqual(fixture.quiescence_snapshot_count, 2)

    def test_browser_termination_treats_authoritative_presignal_absence_as_benign(self):
        executable = pathlib.Path("/Applications/Browser.app/Contents/MacOS/Browser")
        identity = driver.ProcessIdentity(123, 1, 2, 3, executable)
        with (
            mock.patch.object(
                driver,
                "_darwin_process_identity",
                side_effect=driver._ProcessDisappeared,
            ),
            mock.patch.object(driver.os, "kill") as kill,
        ):
            self.assertTrue(
                driver._terminate_exact_browser_process(
                    identity, executable, time.monotonic() + 1.0
                )
            )
            kill.assert_not_called()
        with (
            mock.patch.object(
                driver,
                "_darwin_process_identity",
                side_effect=driver._IdentityInspectionError,
            ),
            mock.patch.object(driver.os, "kill") as kill,
        ):
            with self.assertRaises(driver._IdentityInspectionError):
                driver._terminate_exact_browser_process(
                    identity, executable, time.monotonic() + 1.0
                )
            kill.assert_not_called()

    @unittest.skipUnless(sys.platform == "darwin", "requires Darwin process identity")
    def test_browser_termination_allows_bounded_delayed_exact_process_exit(self):
        source = """
import signal
import time

terminating = False

def begin_termination(_signum, _frame):
    global terminating
    terminating = True

signal.signal(signal.SIGTERM, begin_termination)
print("ready", flush=True)
while not terminating:
    time.sleep(0.01)
time.sleep(3.25)
"""
        process = subprocess.Popen(
            [sys.executable, "-c", source],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            self.assertEqual(process.stdout.readline().strip(), "ready")
            identity = driver._darwin_process_identity(process.pid)
            started = time.monotonic()

            self.assertTrue(
                driver._terminate_exact_browser_process(
                    identity,
                    identity.executable,
                    time.monotonic() + driver.BROWSER_CLEANUP_GRACE_SECONDS,
                )
            )

            elapsed = time.monotonic() - started
            self.assertGreater(elapsed, 3.0)
            self.assertLess(elapsed, 5.0)
            self.assertEqual(process.wait(timeout=1.0), 0)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=1.0)
            process.stdout.close()
            process.stderr.close()

    def test_browser_termination_checks_target_generation_at_deadline_boundary(self):
        executable = pathlib.Path("/Applications/Browser.app/Contents/MacOS/Browser")
        identity = driver.ProcessIdentity(123, 1, 2, 3, executable)
        with (
            mock.patch.object(
                driver,
                "_darwin_process_identity",
                side_effect=(identity, identity, driver._ProcessDisappeared),
            ) as inspect,
            mock.patch.object(
                driver.time, "monotonic", side_effect=(0.0, 0.0, 0.5, 1.0)
            ),
            mock.patch.object(driver.time, "sleep"),
            mock.patch.object(driver, "_snapshot_exact_browser_processes") as snapshot,
            mock.patch.object(driver.os, "kill") as kill,
        ):
            self.assertTrue(
                driver._terminate_exact_browser_process(identity, executable, 1.0)
            )
            self.assertEqual(inspect.call_count, 3)
            snapshot.assert_not_called()
            kill.assert_called_once_with(identity.pid, signal.SIGTERM)

    def test_browser_termination_treats_pid_reuse_as_target_generation_absence(self):
        executable = pathlib.Path("/Applications/Browser.app/Contents/MacOS/Browser")
        identity = driver.ProcessIdentity(123, 1, 2, 3, executable)
        replacement = driver.ProcessIdentity(123, 1, 9, 9, executable)
        with (
            mock.patch.object(
                driver,
                "_darwin_process_identity",
                side_effect=(identity, replacement),
            ),
            mock.patch.object(driver.time, "monotonic", return_value=0.0),
            mock.patch.object(driver, "_snapshot_exact_browser_processes") as snapshot,
            mock.patch.object(driver.os, "kill") as kill,
        ):
            self.assertTrue(
                driver._terminate_exact_browser_process(identity, executable, 1.0)
            )
            snapshot.assert_not_called()
            kill.assert_called_once_with(identity.pid, signal.SIGTERM)

    def test_browser_termination_caps_poll_sleep_at_shared_deadline(self):
        executable = pathlib.Path("/Applications/Browser.app/Contents/MacOS/Browser")
        identity = driver.ProcessIdentity(123, 1, 2, 3, executable)
        with (
            mock.patch.object(
                driver,
                "_darwin_process_identity",
                side_effect=(identity, identity, driver._ProcessDisappeared),
            ),
            mock.patch.object(
                driver.time,
                "monotonic",
                side_effect=(0.0, 0.99, 0.995, 1.0),
            ),
            mock.patch.object(driver.time, "sleep") as sleep,
            mock.patch.object(driver.os, "kill"),
        ):
            self.assertTrue(
                driver._terminate_exact_browser_process(identity, executable, 1.0)
            )
            sleep.assert_called_once()
            self.assertAlmostEqual(sleep.call_args.args[0], 0.005)

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
            self.assertEqual(
                helper_argv,
                (str(fixture.helper), str(fixture.e2e_app), str(fixture.e2e_pid)),
            )
            self.assertGreater(int(helper_argv[2]), 0)
            self.assertNotIn(str(fixture.browser_app), helper_argv)

    def test_fake_chain_cannot_select_or_receive_without_helper_delivery_to_e2e(self):
        with DriverFixture(
            helper_delivers_to_app=False,
            timeout=0.25,
            proof_deadline_phase="helper-exited",
        ) as fixture:
            result = fixture.run()
            self.assertEqual(result.exit_code, driver.DRIVER_TIMEOUT)
            self.assertFalse(result.report["token_received"])
            self.assertFalse(result.report["exact_browser_process_identity"])

    def test_selected_status_followed_by_nonzero_helper_is_helper_error(self):
        with DriverFixture(
            spawn_browser=False,
            helper_failure_phase="after-status",
        ) as fixture:
            result = fixture.run()

            self.assertEqual(result.exit_code, driver.DRIVER_HELPER_FAILURE)
            self.assertEqual(result.report["outcome"], "helper-error")
            self.assertTrue((fixture.fixture_root / "status-written").exists())

    def test_complete_route_proof_with_nonzero_helper_never_passes(self):
        with DriverFixture(
            helper_failure_phase="after-receipt",
            proof_deadline_phase="receipt-delivered",
        ) as fixture:
            result = fixture.run()

            self.assertEqual(result.exit_code, driver.DRIVER_HELPER_FAILURE)
            self.assertEqual(result.report["outcome"], "helper-error")
            self.assertIn("observation", fixture.snapshot_phases)
            receiver_output = b"".join(
                contents
                for kind, channel, contents, _overflow in fixture.captured_child_output
                if kind == "receiver" and channel == "stdout"
            )
            self.assertGreaterEqual(receiver_output.count(b"\n"), 2)
            self.assertTrue(result.report["token_received"])
            self.assertTrue(result.report["exact_browser_process_identity"])

    def test_selected_launch_error_with_nonzero_helper_is_helper_error(self):
        class ManualProcesses:
            def append_manual_stdout(self, _process, _chunk):
                pass

        class ManualProcess:
            def __init__(self, stdout=None, exit_codes=(None,)):
                self.stdout = stdout
                self.exit_codes = list(exit_codes)

            def poll(self):
                if len(self.exit_codes) > 1:
                    return self.exit_codes.pop(0)
                return self.exit_codes[0]

        status_read, status_write = os.pipe()
        provenance_read, provenance_write = os.pipe()
        receipt_read, receipt_write = os.pipe()
        receiver_stream = os.fdopen(receipt_read, "rb", buffering=0)
        os.write(
            status_write,
            b'{"outcome":"selected","session":"session_0123456789"}\n'
            b'{"outcome":"launch-error","session":"session_0123456789"}\n',
        )
        try:
            with self.assertRaises(driver._HelperError) as raised:
                driver._wait_for_proof(
                    ManualProcesses(),
                    status_read,
                    provenance_read,
                    ManualProcess(receiver_stream),
                    ManualProcess(exit_codes=(None, None, None, 23)),
                    ManualProcess(),
                    "session_0123456789",
                    "request_0123456789",
                    "com.microsoft.edgemac||normal",
                    "com.microsoft.edgemac",
                    "normal",
                    "process",
                    "TOKEN",
                    pathlib.Path("/Applications/Browser.app"),
                    pathlib.Path("/Applications/Browser.app/Browser"),
                    set(),
                    driver.DriverDependencies(
                        browser_process_snapshot=lambda _executable, _phase: set(),
                    ),
                    time.monotonic() + 1.0,
                )
        finally:
            os.close(status_read)
            os.close(status_write)
            os.close(provenance_read)
            os.close(provenance_write)
            os.close(receipt_write)
            receiver_stream.close()

        self.assertIn(b'"outcome":"launch-error"', raised.exception.status_line)

    def test_selected_without_receipt_and_nonzero_helper_is_not_receipt_timeout(self):
        with DriverFixture(
            delivers_receipt=False,
            helper_failure_phase="after-browser",
        ) as fixture:
            result = fixture.run()

            self.assertEqual(result.exit_code, driver.DRIVER_HELPER_FAILURE)
            self.assertEqual(result.report["outcome"], "helper-error")
            self.assertIn("observation", fixture.snapshot_phases)

    def test_complete_proof_with_hanging_helper_preserves_proof_at_timeout(self):
        with DriverFixture(
            helper_hangs_after_delivery=True,
            timeout=2.0,
            proof_deadline_phase="receipt-delivered",
        ) as fixture:
            result = fixture.run()

            self.assertEqual(result.exit_code, driver.DRIVER_HELPER_FAILURE)
            self.assertEqual(result.report["outcome"], "helper-exit-timeout")
            self.assertTrue(result.report["token_received"])
            self.assertTrue(result.report["exact_browser_process_identity"])

    def test_hanging_helper_precedes_incomplete_receipt_proof_at_deadline(self):
        with DriverFixture(
            delivers_receipt=False,
            helper_hangs_after_delivery=True,
            timeout=2.0,
        ) as fixture:
            result = fixture.run()

            self.assertEqual(result.exit_code, driver.DRIVER_HELPER_FAILURE)
            self.assertEqual(result.report["outcome"], "helper-exit-timeout")
            self.assertFalse(result.report["token_received"])
            self.assertTrue(result.report["exact_browser_process_identity"])
            self.assertTrue(result.status_line)

    def test_exhausted_receipt_descriptor_does_not_busy_spin_at_helper_timeout(self):
        with DriverFixture(
            helper_hangs_after_delivery=True,
            timeout=2.0,
        ) as fixture:
            fixture.run()

            self.assertLess(fixture.clock_calls, 100)

    def test_deadline_boundary_without_settle_never_completes_existing_proof(self):
        class ManualProcesses:
            def append_manual_stdout(self, _process, _chunk):
                pass

        class ManualProcess:
            def __init__(self, stdout=None, exit_code=None):
                self.stdout = stdout
                self.exit_code = exit_code

            def poll(self):
                return self.exit_code

        status_read, status_write = os.pipe()
        provenance_read, provenance_write = os.pipe()
        receipt_read, receipt_write = os.pipe()
        receiver_stream = os.fdopen(receipt_read, "rb", buffering=0)
        helper = ManualProcess()
        receiver = ManualProcess(receiver_stream, 0)
        app = ManualProcess(exit_code=None)
        browser_executable = pathlib.Path("/Applications/Browser.app/Browser")
        browser_identity = driver.ProcessIdentity(
            123,
            1,
            2,
            3,
            browser_executable,
        )
        os.write(
            status_write,
            b'{"outcome":"selected","session":"session_0123456789"}\n',
        )
        os.write(
            receipt_write,
            b'{"remote_address":"127.0.0.1","receipt_time":1,"token":"TOKEN"}\n',
        )
        os.write(
            provenance_write,
            b'{"bundleIdentifier":"com.microsoft.edgemac","mechanism":"process",'
            b'"mode":"normal","outcome":"launch-observed","processIdentifier":123,'
            b'"request":"request_0123456789","session":"session_0123456789",'
            b'"target":"com.microsoft.edgemac||normal"}\n',
        )
        remaining_calls = 0

        def reach_deadline_after_events(_deadline, _monotonic):
            nonlocal remaining_calls
            remaining_calls += 1
            if remaining_calls == 1:
                return 0.05
            helper.exit_code = 0
            raise driver._DeadlineExpired

        dependencies = driver.DriverDependencies(
            monotonic=lambda: 0.0,
            browser_process_snapshot=lambda _executable, _phase: {browser_identity},
            browser_process_identity=lambda _pid: browser_identity,
            browser_binding_checker=lambda _application, _executable, _bundle: None,
            browser_running_code_checker=lambda _pid,
            _application,
            _executable,
            _bundle: None,
        )
        try:
            with mock.patch.object(
                driver,
                "_remaining",
                side_effect=reach_deadline_after_events,
            ):
                with self.assertRaises(driver._ProvenanceProtocolError):
                    driver._wait_for_proof(
                        ManualProcesses(),
                        status_read,
                        provenance_read,
                        receiver,
                        helper,
                        app,
                        "session_0123456789",
                        "request_0123456789",
                        "com.microsoft.edgemac||normal",
                        "com.microsoft.edgemac",
                        "normal",
                        "process",
                        "TOKEN",
                        pathlib.Path("/Applications/Browser.app"),
                        browser_executable,
                        set(),
                        dependencies,
                        1.0,
                    )
        finally:
            os.close(status_read)
            os.close(status_write)
            os.close(provenance_read)
            os.close(provenance_write)
            os.close(receipt_write)
            receiver_stream.close()

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

    def test_optional_profile_grant_manifest_is_fixed_closed_and_path_private(self):
        relative_root = "profiles/edge-e2e"
        with DriverFixture() as fixture:
            result = fixture.run(
                config_overrides={
                    "profile_strategy": "chromium",
                    "profile_relative_root": relative_root,
                }
            )

            self.assertEqual(result.exit_code, driver.DRIVER_SUCCESS)
            manifests = [
                contents
                for name, contents in fixture.regular_file_snapshots
                if name == "profile-grant.json"
            ]
            self.assertEqual(len(manifests), 1)
            self.assertEqual(
                json.loads(manifests[0]),
                {
                    "schemaVersion": 1,
                    "bundleIdentifier": "com.microsoft.edgemac",
                    "strategy": "chromium",
                    "relativeRoot": relative_root,
                },
            )
            encoded_root = relative_root.encode("utf-8")
            self.assertNotIn(encoded_root, result.stdout)
            self.assertNotIn(encoded_root, result.stderr)
            self.assertNotIn(encoded_root, result.status_line)
            for _, argv in fixture.observed_argv:
                self.assertNotIn(relative_root, "\0".join(argv))
            for _, environment in fixture.observed_environment:
                self.assertNotIn(encoded_root, b"\0".join(environment))

    def test_driver_creates_requested_profile_inside_its_pinned_task_root(self):
        created = []

        def create_profile(strategy, application, executable, bundle_identifier, root):
            created.append((strategy, application, executable, bundle_identifier, root))
            root.mkdir(mode=0o700)
            (root / "PickVia E2E").mkdir(mode=0o700)
            (root / "Local State").write_text(
                '{"profile":{"info_cache":{"PickVia E2E":{"name":"PickVia E2E"}}}}',
                encoding="utf-8",
            )
            (root / "Local State").chmod(0o600)

        with DriverFixture() as fixture:
            result = fixture.run(
                config_overrides={
                    "profile_strategy": "chromium",
                    "profile_relative_root": "profiles/edge-e2e",
                    "create_profile": True,
                    "derive_profile_target": True,
                },
                dependency_overrides={"profile_creator": create_profile},
            )

            self.assertEqual(result.exit_code, driver.DRIVER_SUCCESS)
            self.assertEqual(len(created), 1)
            strategy, application, executable, bundle_identifier, root = created[0]
            self.assertEqual(strategy, "chromium")
            self.assertEqual(application, fixture.browser_app)
            self.assertEqual(executable, fixture.browser_executable)
            self.assertEqual(bundle_identifier, "com.microsoft.edgemac")
            self.assertEqual(root.parent.name, "profiles")
            self.assertFalse(root.exists())
            self.assertNotIn(str(root).encode(), result.stdout + result.stderr)

    def test_derived_profile_target_matches_catalog_identity_rules(self):
        chromium_root = pathlib.Path("/private/tmp/task/profiles/chrome")
        firefox_root = pathlib.Path("/private/tmp/task/profiles/firefox")
        self.assertEqual(
            driver._derived_profile_target_id(
                "com.google.Chrome", "chromium", chromium_root, "normal"
            ),
            "com.google.Chrome|PickVia E2E|normal",
        )
        expected_digest = hashlib.sha256(
            str(firefox_root / "PickVia E2E").encode("utf-8")
        ).hexdigest()
        self.assertEqual(
            driver._derived_profile_target_id(
                "org.mozilla.firefox", "firefox", firefox_root, "private"
            ),
            f"org.mozilla.firefox|firefox-profile-v1:{expected_digest}|private",
        )

    def test_driver_report_exposes_only_closed_launch_provenance_outcome(self):
        with DriverFixture() as fixture:
            selected = fixture.run()
            self.assertEqual(selected.report["launch_provenance"], "launch-observed")
        with DriverFixture(
            provenance_records=[
                {
                    "session": "session_0123456789",
                    "request": "$request",
                    "target": "com.microsoft.edgemac||normal",
                    "bundleIdentifier": "com.microsoft.edgemac",
                    "mode": "normal",
                    "mechanism": "process",
                    "outcome": "launch-error",
                }
            ],
            status_records=[
                {"session": "session_0123456789", "outcome": "selected"},
                {"session": "session_0123456789", "outcome": "launch-error"},
            ],
            spawn_browser=False,
            delivers_receipt=False,
        ) as fixture:
            launch_error = fixture.run()
            self.assertEqual(launch_error.report["launch_provenance"], "launch-error")

    def test_profile_grant_controls_must_be_paired_and_relative(self):
        invalid = (
            {"profile_strategy": "chromium"},
            {"profile_relative_root": "profiles/edge-e2e"},
            {
                "profile_strategy": "unsupported",
                "profile_relative_root": "profiles/edge-e2e",
            },
            {"profile_strategy": "chromium", "profile_relative_root": ""},
            {
                "profile_strategy": "chromium",
                "profile_relative_root": "/private/tmp/external",
            },
            {
                "profile_strategy": "chromium",
                "profile_relative_root": "profiles/../../external",
            },
        )
        for overrides in invalid:
            with self.subTest(overrides=overrides), DriverFixture() as fixture:
                result = fixture.run(config_overrides=overrides)
                self.assertEqual(result.exit_code, driver.DRIVER_USAGE)
                self.assertEqual(fixture.launched_kinds, [])

    def test_profile_creation_and_target_derivation_flags_fail_closed(self):
        invalid = (
            {"create_profile": True},
            {"derive_profile_target": True},
            {
                "profile_strategy": "chromium",
                "profile_relative_root": "profiles/edge-e2e",
                "derive_profile_target": True,
            },
        )
        for overrides in invalid:
            with self.subTest(overrides=overrides), DriverFixture() as fixture:
                result = fixture.run(config_overrides=overrides)
                self.assertEqual(result.exit_code, driver.DRIVER_USAGE)
                self.assertEqual(fixture.launched_kinds, [])

    def test_omitted_profile_grant_creates_no_manifest_or_environment_key(self):
        with DriverFixture() as fixture:
            result = fixture.run()
            self.assertEqual(result.exit_code, driver.DRIVER_SUCCESS)
            self.assertNotIn(
                "profile-grant.json",
                [name for name, _ in fixture.regular_file_snapshots],
            )
            for _, environment in fixture.observed_environment:
                self.assertFalse(any(b"PROFILE_GRANT" in item for item in environment))

    def test_e2e_app_uses_exact_task_root_as_fixed_user_home_without_url_leak(self):
        with DriverFixture() as fixture:
            result = fixture.run()
            self.assertEqual(result.exit_code, driver.DRIVER_SUCCESS)
            environment = dict(
                item.decode("utf-8").split("=", 1)
                for kind, items in fixture.observed_environment
                if kind == "e2e-app"
                for item in items
            )
            task_root = str(fixture.task_root)

            self.assertEqual(environment["CFFIXED_USER_HOME"], task_root)
            self.assertNotEqual(environment.get("HOME"), task_root)
            self.assertNotIn(fixture.route, environment["CFFIXED_USER_HOME"])

    def test_every_child_environment_is_minimal_and_excludes_parent_secrets(self):
        sentinel = "must-not-reach-any-child"
        with (
            mock.patch.dict(
                os.environ,
                {
                    "PICKVIA_PARENT_SENTINEL_SECRET": sentinel,
                    "AGENT_RUNTIME_SENTINEL": sentinel,
                },
                clear=False,
            ),
            DriverFixture() as fixture,
        ):
            result = fixture.run()

            self.assertEqual(result.exit_code, driver.DRIVER_SUCCESS)
            environments = {
                kind: dict(item.decode("utf-8").split("=", 1) for item in items)
                for kind, items in fixture.observed_environment
            }
            self.assertEqual(
                set(environments), {"receiver", "e2e-app", "exact-app-helper"}
            )
            task_root = str(fixture.task_root)
            base_keys = {"PATH", "LANG", "LC_CTYPE", "TMPDIR", "CFFIXED_USER_HOME"}
            control_keys = {
                "PICKVIA_E2E_TARGET_ID",
                "PICKVIA_E2E_BUNDLE_ID",
                "PICKVIA_E2E_MODE",
                "PICKVIA_E2E_SESSION_NONCE",
                "PICKVIA_E2E_REQUEST_NONCE",
                "PICKVIA_E2E_SUPPORT_DIR",
                "PICKVIA_E2E_STATUS_FIFO",
                "PICKVIA_E2E_PROVENANCE_FIFO",
            }
            for kind, environment in environments.items():
                self.assertTrue(base_keys.issubset(environment), kind)
                self.assertEqual(environment["CFFIXED_USER_HOME"], task_root, kind)
                self.assertEqual(environment["TMPDIR"], task_root, kind)
                self.assertNotIn("HOME", environment, kind)
                self.assertNotIn("PICKVIA_PARENT_SENTINEL_SECRET", environment, kind)
                self.assertNotIn("AGENT_RUNTIME_SENTINEL", environment, kind)
                self.assertNotIn(sentinel, environment.values(), kind)
                self.assertNotIn(fixture.route, "\0".join(environment.values()), kind)
            self.assertEqual(set(environments["receiver"]), base_keys)
            self.assertEqual(set(environments["exact-app-helper"]), base_keys)
            self.assertEqual(set(environments["e2e-app"]), base_keys | control_keys)

    def test_helper_compiler_receives_only_supplied_minimal_environment(self):
        root = pathlib.Path(
            tempfile.mkdtemp(prefix="pickvia-compiler-env-", dir="/private/tmp")
        )
        source = root / "helper.swift"
        output = root / "helper"
        source.write_text('print("ok")\n', encoding="utf-8")
        expected_environment = {
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "en_US.UTF-8",
            "LC_CTYPE": "UTF-8",
            "TMPDIR": str(root),
            "CFFIXED_USER_HOME": str(root),
        }
        observed = {}

        class CompilerProcess:
            returncode = 0

            def wait(self, timeout):
                return 0

        class CompilerProcesses:
            def start(self, kind, argv, *, environment=None, stdin=None):
                observed["kind"] = kind
                observed["environment"] = dict(environment or {})
                output.write_text("compiled", encoding="utf-8")
                output.chmod(0o700)
                return CompilerProcess()

        try:
            driver._compile_helper(
                CompilerProcesses(),
                source,
                output,
                time.monotonic() + 1,
                time.monotonic,
                environment=expected_environment,
            )
            self.assertEqual(observed["kind"], "helper-compiler")
            self.assertEqual(observed["environment"], expected_environment)
        finally:
            for path in root.iterdir():
                path.unlink()
            root.rmdir()

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
            with (
                self.subTest(channel=channel),
                DriverFixture(
                    leak_channel=channel,
                    probe_kind=channel if channel.startswith("leak-") else "normal",
                ) as fixture,
            ):
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
        with DriverFixture(
            delivers_receipt=False,
            timeout=0.3,
            proof_deadline_phase="helper-and-browser",
        ) as fixture:
            self.assertEqual(fixture.run().exit_code, driver.DRIVER_RECEIPT_TIMEOUT)
        with DriverFixture(
            receipt_without_browser=True,
            spawn_browser=False,
            timeout=1.0,
            proof_deadline_phase="helper-and-receipt",
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

    def test_valid_provenance_accepts_direct_workspace_and_duckduckgo_mechanisms(self):
        for mechanism in ("process", "workspace", "duckduckgo"):
            with (
                self.subTest(mechanism=mechanism),
                DriverFixture(provenance_mechanism=mechanism) as fixture,
            ):
                result = fixture.run()
                self.assertEqual(result.exit_code, driver.DRIVER_SUCCESS)
                self.assertTrue(result.report["exact_browser_process_identity"])

    def test_closed_but_wrong_expected_mechanism_is_provenance_failure(self):
        with DriverFixture(
            provenance_mechanism="workspace",
            expected_mechanism="process",
        ) as fixture:
            result = fixture.run()
            self.assertEqual(result.exit_code, driver.DRIVER_PROVENANCE_FAILURE)
            self.assertEqual(result.report["outcome"], "provenance-error")
            self.assertEqual(fixture.terminated_browser_pids, [])

    def test_provenance_parser_rejects_every_wrong_field_and_duplicate_or_missing_record(
        self,
    ):
        base = {
            "session": "session_0123456789",
            "request": "request_0123456789",
            "target": "com.microsoft.edgemac||normal",
            "bundleIdentifier": "com.microsoft.edgemac",
            "mode": "normal",
            "mechanism": "process",
            "processIdentifier": 123,
            "outcome": "launch-observed",
        }
        expected = dict(
            expected_session="session_0123456789",
            expected_request="request_0123456789",
            expected_target="com.microsoft.edgemac||normal",
            expected_bundle_identifier="com.microsoft.edgemac",
            expected_mode="normal",
            expected_mechanism="process",
        )
        self.assertEqual(
            driver._parse_provenance(
                (json.dumps(base) + "\n").encode("ascii"), **expected
            ).process_identifier,
            123,
        )
        wrong_values = {
            "session": "wrong_session_1234",
            "request": "wrong_request_1234",
            "target": "com.microsoft.edgemac||private",
            "bundleIdentifier": "com.example.Other",
            "mode": "private",
            "mechanism": "workspace",
            "processIdentifier": 0,
            "outcome": "arbitrary",
        }
        for field, value in wrong_values.items():
            with self.subTest(field=field):
                invalid = dict(base)
                invalid[field] = value
                with self.assertRaises(driver._ProvenanceProtocolError):
                    driver._parse_provenance(
                        (json.dumps(invalid) + "\n").encode("ascii"), **expected
                    )
        invalid = dict(base, extra="secret")
        with self.assertRaises(driver._ProvenanceProtocolError):
            driver._parse_provenance(
                (json.dumps(invalid) + "\n").encode("ascii"), **expected
            )
        duplicate_key = (
            json.dumps(base)[:-1] + ',"outcome":"launch-observed"}\n'
        ).encode("ascii")
        with self.assertRaises(driver._ProvenanceProtocolError):
            driver._parse_provenance(duplicate_key, **expected)

        for records in ([], [base, base]):
            with (
                self.subTest(record_count=len(records)),
                DriverFixture(
                    provenance_records=records,
                    timeout=1.0,
                    proof_deadline_phase="complete-proof",
                ) as fixture,
            ):
                result = fixture.run()
                self.assertEqual(result.exit_code, driver.DRIVER_PROVENANCE_FAILURE)
                self.assertEqual(result.report["outcome"], "provenance-error")

    def test_receipt_and_temporal_identity_cannot_upgrade_missing_provenance(self):
        with DriverFixture(
            provenance_records=[],
            timeout=1.0,
            proof_deadline_phase="complete-proof",
        ) as fixture:
            result = fixture.run()
            self.assertEqual(result.exit_code, driver.DRIVER_PROVENANCE_FAILURE)
            self.assertEqual(result.report["outcome"], "provenance-error")
            self.assertTrue(result.report["token_received"])
            self.assertTrue(result.report["exact_browser_process_identity"])
            self.assertEqual(fixture.terminated_browser_pids, [])

    def test_wrong_reported_pid_is_provenance_failure_and_grants_no_cleanup_authority(
        self,
    ):
        record = {
            "session": "session_0123456789",
            "request": "$request",
            "target": "com.microsoft.edgemac||normal",
            "bundleIdentifier": "com.microsoft.edgemac",
            "mode": "normal",
            "mechanism": "process",
            "processIdentifier": 999_999,
            "outcome": "launch-observed",
        }
        with DriverFixture(
            provenance_records=[record],
            proof_deadline_phase="complete-proof",
        ) as fixture:
            result = fixture.run()
            self.assertEqual(result.exit_code, driver.DRIVER_PROVENANCE_FAILURE)
            self.assertEqual(result.report["outcome"], "provenance-error")
            self.assertEqual(fixture.terminated_browser_pids, [])

    def test_provenance_resolution_revalidates_browser_bundle_binding_after_route(self):
        for mutation in ("wrong-bundle", "wrong-executable"):
            with (
                self.subTest(mutation=mutation),
                DriverFixture(browser_binding_mutation=mutation) as fixture,
            ):
                result = fixture.run()
                self.assertEqual(result.exit_code, driver.DRIVER_PROVENANCE_FAILURE)
                self.assertEqual(result.report["outcome"], "provenance-error")
                self.assertEqual(
                    fixture.browser_binding_checks,
                    [
                        (
                            fixture.browser_app,
                            fixture.browser_executable,
                            "com.microsoft.edgemac",
                        ),
                        (
                            fixture.browser_app,
                            fixture.browser_executable,
                            "com.microsoft.edgemac",
                        ),
                    ],
                )
                self.assertEqual(fixture.terminated_browser_pids, [])

    def test_production_browser_binding_requires_bounded_codesign_verification(self):
        with DriverFixture() as fixture:
            success = subprocess.CompletedProcess(
                ["/usr/bin/codesign"], returncode=0, stdout=b"", stderr=b""
            )
            with mock.patch.object(
                driver.subprocess, "run", return_value=success
            ) as run:
                driver._validate_signed_browser_binding(
                    fixture.browser_app,
                    fixture.browser_executable,
                    "com.microsoft.edgemac",
                )
            self.assertEqual(
                run.call_args.args[0],
                [
                    "/usr/bin/codesign",
                    "--verify",
                    "--deep",
                    "--strict",
                    os.fspath(fixture.browser_app),
                ],
            )
            self.assertEqual(
                float(run.call_args.kwargs["timeout"]),
                driver.BROWSER_BINDING_VERIFICATION_TIMEOUT_SECONDS,
            )
            self.assertIs(run.call_args.kwargs["stdin"], subprocess.DEVNULL)
            self.assertIs(run.call_args.kwargs["stdout"], subprocess.DEVNULL)
            self.assertIs(run.call_args.kwargs["stderr"], subprocess.DEVNULL)
            self.assertFalse(run.call_args.kwargs["check"])
            self.assertEqual(
                set(run.call_args.kwargs["env"]),
                {"PATH", "LANG", "LC_CTYPE", "TMPDIR", "CFFIXED_USER_HOME"},
            )

            failures = (
                subprocess.CompletedProcess(["/usr/bin/codesign"], returncode=1),
                subprocess.TimeoutExpired(["/usr/bin/codesign"], 2.0),
                OSError("unavailable"),
            )
            for failure in failures:
                with (
                    self.subTest(failure=type(failure).__name__),
                    mock.patch.object(
                        driver.subprocess,
                        "run",
                        return_value=failure
                        if not isinstance(failure, BaseException)
                        else None,
                        side_effect=failure
                        if isinstance(failure, BaseException)
                        else None,
                    ),
                ):
                    with self.assertRaises(driver._IdentityError):
                        driver._validate_signed_browser_binding(
                            fixture.browser_app,
                            fixture.browser_executable,
                            "com.microsoft.edgemac",
                        )

    def test_provenance_resolution_rejects_signature_mutation_after_preflight(self):
        with DriverFixture() as fixture:
            checks = []

            def check_binding(application, executable, bundle_identifier):
                checks.append((application, executable, bundle_identifier))
                if len(checks) == 2:
                    raise driver._IdentityError
                driver._validate_browser_binding(
                    application, executable, bundle_identifier
                )

            result = fixture.run(
                dependency_overrides={"browser_binding_checker": check_binding}
            )
            self.assertEqual(result.exit_code, driver.DRIVER_PROVENANCE_FAILURE)
            self.assertEqual(result.report["outcome"], "provenance-error")
            self.assertEqual(len(checks), 2)
            self.assertEqual(fixture.terminated_browser_pids, [])

    def test_running_code_attestation_failures_grant_no_cleanup_authority(self):
        failures = (
            "current-path-static-mismatch",
            "guest-path-mismatch",
            "cdhash-mismatch",
            "bundle-mismatch",
            "attestation-timeout",
            "attestation-output-overflow",
        )
        for failure in failures:
            with (
                self.subTest(failure=failure),
                DriverFixture(proof_deadline_phase="complete-proof") as fixture,
            ):

                def reject(_pid, _application, _executable, _bundle):
                    raise driver._IdentityError(failure)

                result = fixture.run(
                    dependency_overrides={
                        "browser_running_code_checker": reject,
                    }
                )
                self.assertEqual(result.exit_code, driver.DRIVER_PROVENANCE_FAILURE)
                self.assertEqual(result.report["outcome"], "provenance-error")
                self.assertTrue(result.report["token_received"])
                self.assertTrue(result.report["exact_browser_process_identity"])
                self.assertEqual(fixture.terminated_browser_pids, [])

    def test_browser_binding_rejects_plist_or_executable_swap_at_nofollow_open(self):
        for relative_path in (
            pathlib.Path("Contents/Info.plist"),
            pathlib.Path("Contents/MacOS/Browser"),
        ):
            with self.subTest(relative_path=relative_path), DriverFixture() as fixture:
                target = fixture.browser_app / relative_path
                held = target.with_name(f"{target.name}.held")
                real_open = os.open
                swapped = False

                def swap_at_open(path, flags, *args, **kwargs):
                    nonlocal swapped
                    if not swapped and pathlib.Path(path) == target:
                        swapped = True
                        target.rename(held)
                        target.symlink_to(held)
                    return real_open(path, flags, *args, **kwargs)

                with mock.patch.object(driver.os, "open", side_effect=swap_at_open):
                    with self.assertRaises(driver._IdentityError):
                        driver._validate_browser_binding(
                            fixture.browser_app,
                            fixture.browser_executable,
                            "com.microsoft.edgemac",
                        )
                self.assertTrue(swapped)

    def test_cached_security_helper_attests_a_safe_signed_process(self):
        helper = driver._pin_browser_code_identity_helper()
        helper_path = helper.path
        helper_digest = helper.executable_digest
        process = subprocess.Popen(
            ["/bin/sleep", "5"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        try:
            self.assertTrue(helper.validate())
            driver._invoke_browser_code_identity_helper(
                helper,
                process.pid,
                pathlib.Path("/bin/sleep"),
                pathlib.Path("/bin/sleep"),
                "com.apple.sleep",
            )
            with self.assertRaises(driver._IdentityError):
                driver._invoke_browser_code_identity_helper(
                    helper,
                    process.pid,
                    pathlib.Path("/usr/bin/true"),
                    pathlib.Path("/usr/bin/true"),
                    "com.apple.true",
                )
        finally:
            helper.close()
            process.terminate()
            process.wait(timeout=2)
        repinned = driver._pin_browser_code_identity_helper()
        try:
            self.assertEqual(repinned.path, helper_path)
            self.assertEqual(repinned.executable_digest, helper_digest)
            self.assertTrue(repinned.validate())
        finally:
            repinned.close()

    def test_security_helper_uses_only_the_fixed_minimal_environment(self):
        class FakeHelper:
            def __init__(self, path):
                self.path = path

            def validate(self):
                return True

        with tempfile.TemporaryDirectory(
            prefix="pickvia-attestation-environment-", dir="/private/tmp"
        ) as root:
            executable = pathlib.Path(root) / "environment-check"
            executable.write_text(
                "#!/bin/sh\nprintf 'OK\\n'\n",
                encoding="ascii",
            )
            executable.chmod(0o700)
            observed = {}
            real_popen = subprocess.Popen

            def record_environment(*args, **kwargs):
                observed.update(kwargs["env"])
                return real_popen(*args, **kwargs)

            with mock.patch.object(
                driver.subprocess, "Popen", side_effect=record_environment
            ):
                driver._invoke_browser_code_identity_helper(
                    FakeHelper(executable),
                    os.getpid(),
                    pathlib.Path("/Applications/Browser.app"),
                    pathlib.Path("/Applications/Browser.app/Contents/MacOS/Browser"),
                    "com.example.Browser",
                )
            self.assertEqual(
                set(observed),
                {
                    "PATH",
                    "LANG",
                    "LC_CTYPE",
                    "TMPDIR",
                    "CFFIXED_USER_HOME",
                    "PYTHONDONTWRITEBYTECODE",
                },
            )

    def test_security_helper_timeout_and_output_overflow_fail_closed(self):
        class FakeHelper:
            def __init__(self, path):
                self.path = path

            def validate(self):
                return True

        with tempfile.TemporaryDirectory(
            prefix="pickvia-attestation-runner-", dir="/private/tmp"
        ) as root:
            root = pathlib.Path(root)
            cases = {
                "timeout": "#!/bin/sh\nexec /bin/sleep 5\n",
                "overflow": "#!/bin/sh\ni=0; while [ $i -lt 200 ]; do printf x; i=$((i + 1)); done\n",
            }
            for name, source in cases.items():
                with self.subTest(name=name):
                    executable = root / name
                    executable.write_text(source, encoding="ascii")
                    executable.chmod(0o700)
                    with mock.patch.object(
                        driver,
                        "BROWSER_CODE_IDENTITY_TIMEOUT_SECONDS",
                        0.05,
                    ):
                        with self.assertRaises(driver._IdentityError):
                            driver._invoke_browser_code_identity_helper(
                                FakeHelper(executable),
                                os.getpid(),
                                pathlib.Path("/Applications/Browser.app"),
                                pathlib.Path(
                                    "/Applications/Browser.app/Contents/MacOS/Browser"
                                ),
                                "com.example.Browser",
                            )

    def test_provenance_generation_change_during_binding_check_grants_no_authority(
        self,
    ):
        with DriverFixture(proof_deadline_phase="complete-proof") as fixture:
            state = {"binding_checks": 0, "generation_changed": False}

            def check_binding(application, executable, bundle_identifier):
                state["binding_checks"] += 1
                driver._validate_browser_binding(
                    application, executable, bundle_identifier
                )
                if state["binding_checks"] == 2:
                    state["generation_changed"] = True

            def resolve(pid):
                return driver.ProcessIdentity(
                    pid,
                    fixture.e2e_pid,
                    3 if state["generation_changed"] else 2,
                    pid,
                    fixture.browser_executable,
                )

            result = fixture.run(
                dependency_overrides={
                    "browser_binding_checker": check_binding,
                    "browser_process_identity": resolve,
                }
            )
            self.assertEqual(result.exit_code, driver.DRIVER_PROVENANCE_FAILURE)
            self.assertEqual(result.report["outcome"], "provenance-error")
            self.assertTrue(result.report["token_received"])
            self.assertIn(b'"outcome":"selected"', result.status_line)
            self.assertTrue(result.report["exact_browser_process_identity"])
            self.assertEqual(fixture.terminated_browser_pids, [])

    def test_slow_binding_check_accepts_only_the_unchanged_pinned_generation(self):
        with DriverFixture() as fixture:
            resolutions = []

            def check_binding(application, executable, bundle_identifier):
                driver._validate_browser_binding(
                    application, executable, bundle_identifier
                )
                if resolutions:
                    time.sleep(0.05)

            def resolve(pid):
                identity = driver.ProcessIdentity(
                    pid,
                    fixture.e2e_pid,
                    2,
                    pid,
                    fixture.browser_executable,
                )
                resolutions.append(identity)
                return identity

            result = fixture.run(
                dependency_overrides={
                    "browser_binding_checker": check_binding,
                    "browser_process_identity": resolve,
                }
            )
            self.assertEqual(result.exit_code, driver.DRIVER_SUCCESS)
            self.assertEqual(len(resolutions), 2)
            self.assertEqual(
                resolutions[0].generation_key, resolutions[1].generation_key
            )
            self.assertEqual(
                fixture.terminated_browser_generations,
                [resolutions[0].generation_key],
            )

    def test_provenance_launch_unproven_is_a_harness_failure(self):
        record = {
            "session": "session_0123456789",
            "request": "$request",
            "target": "com.microsoft.edgemac||normal",
            "bundleIdentifier": "com.microsoft.edgemac",
            "mode": "normal",
            "mechanism": "process",
            "outcome": "launch-unproven",
        }
        with DriverFixture(
            provenance_records=[record],
            spawn_browser=False,
        ) as fixture:
            result = fixture.run()
            self.assertEqual(result.exit_code, driver.DRIVER_PROVENANCE_FAILURE)
            self.assertEqual(result.report["outcome"], "provenance-error")
            self.assertEqual(fixture.terminated_browser_pids, [])

    def test_valid_provenance_launch_error_is_a_product_failure(self):
        record = {
            "session": "session_0123456789",
            "request": "$request",
            "target": "com.microsoft.edgemac||normal",
            "bundleIdentifier": "com.microsoft.edgemac",
            "mode": "normal",
            "mechanism": "process",
            "outcome": "launch-error",
        }
        with DriverFixture(
            provenance_records=[record],
            spawn_browser=False,
            status_records=[
                {"session": "session_0123456789", "outcome": "selected"},
                {"session": "session_0123456789", "outcome": "launch-error"},
            ],
        ) as fixture:
            result = fixture.run()
            self.assertEqual(result.exit_code, driver.DRIVER_SELECTION_REJECTED)
            self.assertEqual(result.report["outcome"], "launch-error")
            self.assertFalse(result.report["token_received"])
            self.assertIn(b'"outcome":"selected"', result.status_line)
            self.assertIn(b'"outcome":"launch-error"', result.status_line)
            self.assertEqual(fixture.terminated_browser_pids, [])

    def test_valid_launch_error_remains_primary_when_status_is_missing(self):
        record = {
            "session": "session_0123456789",
            "request": "$request",
            "target": "com.microsoft.edgemac||normal",
            "bundleIdentifier": "com.microsoft.edgemac",
            "mode": "normal",
            "mechanism": "process",
            "outcome": "launch-error",
        }
        with DriverFixture(
            provenance_records=[record],
            provenance_before_status=True,
            status_records=[],
            spawn_browser=False,
            timeout=2.0,
            proof_deadline_phase="status-written",
        ) as fixture:
            result = fixture.run()
            self.assertEqual(result.exit_code, driver.DRIVER_SELECTION_REJECTED)
            self.assertEqual(result.report["outcome"], "launch-error")
            self.assertEqual(result.status_line, b"")
            self.assertGreaterEqual(
                result.report["total_elapsed_seconds"],
                driver.PROVENANCE_STATUS_GRACE_SECONDS,
            )
            self.assertLess(result.report["total_elapsed_seconds"], 2.0)
            self.assertEqual(fixture.terminated_browser_pids, [])

    def test_provenance_failure_collects_late_status_in_both_orders_and_coalesced(self):
        record = {
            "session": "session_0123456789",
            "request": "$request",
            "target": "com.microsoft.edgemac||normal",
            "bundleIdentifier": "com.microsoft.edgemac",
            "mode": "normal",
            "mechanism": "process",
            "outcome": "launch-error",
        }
        status = [
            {"session": "session_0123456789", "outcome": "selected"},
            {"session": "session_0123456789", "outcome": "launch-error"},
        ]
        cases = (
            dict(provenance_before_status=True, status_delay=0.05),
            dict(provenance_before_status=False, status_delay=0.0),
            dict(provenance_before_status=True, status_delay=0.0),
        )
        for options in cases:
            with (
                self.subTest(options=options),
                DriverFixture(
                    provenance_records=[record],
                    status_records=status,
                    spawn_browser=False,
                    **options,
                ) as fixture,
            ):
                result = fixture.run()
                self.assertEqual(result.exit_code, driver.DRIVER_SELECTION_REJECTED)
                self.assertEqual(result.report["outcome"], "launch-error")
                self.assertIn(b'"outcome":"selected"', result.status_line)
                self.assertIn(b'"outcome":"launch-error"', result.status_line)

    def test_provenance_failure_without_status_is_bounded_and_preserves_precedence(
        self,
    ):
        record = {
            "session": "session_0123456789",
            "request": "$request",
            "target": "com.microsoft.edgemac||normal",
            "bundleIdentifier": "com.microsoft.edgemac",
            "mode": "normal",
            "mechanism": "process",
            "outcome": "launch-unproven",
        }
        with DriverFixture(
            provenance_records=[record],
            provenance_before_status=True,
            status_records=[],
            spawn_browser=False,
            timeout=2.0,
            proof_deadline_phase="status-written",
        ) as fixture:
            result = fixture.run()
            self.assertEqual(result.exit_code, driver.DRIVER_PROVENANCE_FAILURE)
            self.assertEqual(result.report["outcome"], "provenance-error")
            self.assertEqual(result.status_line, b"")
            self.assertGreaterEqual(
                result.report["total_elapsed_seconds"],
                driver.PROVENANCE_STATUS_GRACE_SECONDS,
            )
            self.assertLess(result.report["total_elapsed_seconds"], 2.0)

        with DriverFixture(
            provenance_records=[record],
            provenance_before_status=True,
            status_records=[
                {"session": "session_0123456789", "outcome": "selected"},
                {"session": "session_0123456789", "outcome": "launch-error"},
            ],
            spawn_browser=False,
            helper_failure_phase="after-status",
        ) as fixture:
            result = fixture.run()
            self.assertEqual(result.exit_code, driver.DRIVER_HELPER_FAILURE)
            self.assertEqual(result.report["outcome"], "helper-error")

    def test_unproven_record_preserves_receipt_and_temporal_browser_facts(self):
        record = {
            "session": "session_0123456789",
            "request": "$request",
            "target": "com.microsoft.edgemac||normal",
            "bundleIdentifier": "com.microsoft.edgemac",
            "mode": "normal",
            "mechanism": "process",
            "outcome": "launch-unproven",
        }
        with DriverFixture(
            provenance_records=[record],
            proof_deadline_phase="complete-proof",
        ) as fixture:
            result = fixture.run()
            self.assertEqual(result.exit_code, driver.DRIVER_PROVENANCE_FAILURE)
            self.assertTrue(result.report["token_received"])
            self.assertTrue(result.report["exact_browser_process_identity"])
            self.assertIn(b'"outcome":"selected"', result.status_line)
            self.assertEqual(fixture.terminated_browser_pids, [])

    def test_complete_proof_settles_before_success_and_rejects_delayed_second_record(
        self,
    ):
        with DriverFixture() as fixture:
            result = fixture.run()
            self.assertEqual(result.exit_code, driver.DRIVER_SUCCESS)
            self.assertGreaterEqual(
                result.report["total_elapsed_seconds"],
                driver.PROVENANCE_SETTLE_SECONDS,
            )

        duplicate = {
            "session": "session_0123456789",
            "request": "$request",
            "target": "com.microsoft.edgemac||normal",
            "bundleIdentifier": "com.microsoft.edgemac",
            "mode": "normal",
            "mechanism": "process",
            "processIdentifier": "$browser_pid",
            "outcome": "launch-observed",
        }
        for delay, partial in ((0.05, False), (0.24, True)):
            with (
                self.subTest(delay=delay, partial=partial),
                DriverFixture(
                    provenance_records=[duplicate, duplicate],
                    provenance_second_delay=delay,
                    provenance_second_partial=partial,
                ) as fixture,
            ):
                result = fixture.run()
                self.assertEqual(result.exit_code, driver.DRIVER_PROVENANCE_FAILURE)
                self.assertEqual(result.report["outcome"], "provenance-error")
                self.assertEqual(fixture.terminated_browser_pids, [])

    def test_only_provenance_owned_new_generation_is_signalled(self):
        with DriverFixture() as fixture:
            result = fixture.run()
            self.assertEqual(result.exit_code, driver.DRIVER_SUCCESS)
            self.assertEqual(
                fixture.terminated_browser_pids, [fixture.browser_pids()[0]]
            )

    def test_baseline_provenance_is_preserved_and_owns_nothing(self):
        record = {
            "session": "session_0123456789",
            "request": "$request",
            "target": "com.microsoft.edgemac||normal",
            "bundleIdentifier": "com.microsoft.edgemac",
            "mode": "normal",
            "mechanism": "workspace",
            "processIdentifier": 41,
            "outcome": "launch-observed",
        }
        with DriverFixture(
            preexisting_browser_pids={41},
            provenance_records=[record],
            expected_mechanism="workspace",
            spawn_browser=False,
            receipt_without_browser=True,
        ) as fixture:
            result = fixture.run()
            self.assertEqual(result.exit_code, driver.DRIVER_SUCCESS)
            self.assertTrue(result.report["exact_browser_process_identity"])
            self.assertEqual(fixture.terminated_browser_pids, [])

    def test_temporal_replacement_multiple_late_and_unknown_generations_are_never_signalled(
        self,
    ):
        cases = (
            dict(replacement_after_termination=True),
            dict(multiple_new_browsers=True),
            dict(delayed_browser_after_final_sweep=True),
            dict(snapshot_failures={"final-sweep"}),
        )
        for options in cases:
            with self.subTest(options=options), DriverFixture(**options) as fixture:
                result = fixture.run()
                provenance_pid = fixture.browser_pids()[0]
                self.assertTrue(
                    set(fixture.terminated_browser_pids).issubset({provenance_pid})
                )
                self.assertNotIn(900, fixture.terminated_browser_pids)
                if options.get("multiple_new_browsers"):
                    other = fixture.browser_pids()[1]
                    self.assertNotIn(other, fixture.terminated_browser_pids)
                self.assertNotEqual(result.exit_code, driver.DRIVER_SUCCESS)
            self.assertEqual(
                set(result.report),
                {
                    "session",
                    "sessionHashes",
                    "schemaVersion",
                    "request",
                    "bundleIdentifier",
                    "targetID",
                    "capability",
                    "state",
                    "mode",
                    "mechanism",
                    "e2eAppIdentity",
                    "browserAppIdentity",
                    "outcome",
                    "token_received",
                    "exact_process_identity",
                    "exact_browser_process_identity",
                    "launch_provenance",
                    "total_elapsed_seconds",
                    "route_timeout_seconds",
                    "browser_cleanup_grace_seconds",
                    "browser_quiescence_seconds",
                    "provenance_settle_seconds",
                    "provenance_status_grace_seconds",
                    "cleanup_success",
                    "task_root_finalized",
                    "stateProofs",
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
            with (
                self.subTest(records=records),
                DriverFixture(status_records=records) as fixture,
            ):
                self.assertEqual(fixture.run().exit_code, driver.DRIVER_INVALID_STATUS)

    def test_status_and_receipt_json_are_strict_bounded_and_finite(self):
        valid_status = b'{"session":"session_0123456789","outcome":"selected"}\n'
        valid_receipt = (
            b'{"token":"TOKEN","receipt_time":1.25,"remote_address":"127.0.0.1"}\n'
        )
        self.assertEqual(
            driver._parse_status(valid_status, "session_0123456789"), "selected"
        )
        self.assertTrue(driver._parse_receipt(valid_receipt, "TOKEN"))

        invalid_statuses = (
            b'{"session":"session_0123456789","outcome":"selected",'
            b'"outcome":"selected"}\n',
            b'{"session":"session_0123456789","outcome":NaN}\n',
            valid_status.rstrip(b"\n"),
            valid_status[:-1] + b" " * driver.MAXIMUM_PROTOCOL_LINE_BYTES + b"\n",
        )
        for payload in invalid_statuses:
            with self.subTest(protocol="status", payload=payload[:80]):
                with self.assertRaises(driver._StatusProtocolError):
                    driver._parse_status(payload, "session_0123456789")

        invalid_receipts = (
            b'{"token":"TOKEN","token":"TOKEN","receipt_time":1,'
            b'"remote_address":"127.0.0.1"}\n',
            b'{"token":"TOKEN","receipt_time":NaN,"remote_address":"127.0.0.1"}\n',
            b'{"token":"TOKEN","receipt_time":Infinity,"remote_address":"127.0.0.1"}\n',
            b'{"token":"TOKEN","receipt_time":true,"remote_address":"127.0.0.1"}\n',
            valid_receipt.rstrip(b"\n"),
            valid_receipt[:-1] + b" " * driver.MAXIMUM_PROTOCOL_LINE_BYTES + b"\n",
        )
        for payload in invalid_receipts:
            with self.subTest(protocol="receipt", payload=payload[:80]):
                with self.assertRaises(driver._ReceiptProtocolError):
                    driver._parse_receipt(payload, "TOKEN")

    def test_readiness_json_is_strict_bounded_and_finite(self):
        valid = b'{"port":1234,"tokens":["TOKEN"]}\n'
        self.assertEqual(driver._parse_ready(valid), (1234, "TOKEN"))

        invalid = (
            b'{"port":4321,"port":1234,"tokens":["TOKEN"]}\n',
            b'{"port":1234,"tokens":["wrong"],"tokens":["TOKEN"]}\n',
            b'{"port":NaN,"port":1234,"tokens":["TOKEN"]}\n',
            b'{"port":NaN,"tokens":["TOKEN"]}\n',
            b'{"port":Infinity,"tokens":["TOKEN"]}\n',
            valid.rstrip(b"\n"),
            valid + b"{}\n",
            b'{"port":1234\n',
            valid[:-1] + b" " * driver.MAXIMUM_PROTOCOL_LINE_BYTES + b"\n",
        )
        for payload in invalid:
            with self.subTest(payload=payload[:80]):
                with self.assertRaises(driver._ReadinessError):
                    driver._parse_ready(payload)

    def test_preplan_selected_then_launch_error_without_provenance_is_product_failure(
        self,
    ):
        records = [
            {"session": "session_0123456789", "outcome": "selected"},
            {"session": "session_0123456789", "outcome": "launch-error"},
        ]
        with DriverFixture(status_records=records) as fixture:
            result = fixture.run()
            self.assertEqual(result.exit_code, driver.DRIVER_SELECTION_REJECTED)
            self.assertEqual(result.report["outcome"], "launch-error")
            self.assertFalse(result.report["token_received"])
            self.assertEqual(fixture.terminated_browser_pids, [])

    def test_selected_only_without_provenance_remains_a_harness_failure(self):
        with DriverFixture(provenance_records=[]) as fixture:
            result = fixture.run()
            self.assertEqual(result.exit_code, driver.DRIVER_PROVENANCE_FAILURE)
            self.assertEqual(result.report["outcome"], "provenance-error")
            self.assertTrue(result.report["token_received"])
            self.assertTrue(result.report["exact_browser_process_identity"])
            self.assertEqual(fixture.terminated_browser_pids, [])

    def test_valid_launch_error_provenance_does_not_override_helper_failure(self):
        record = {
            "session": "session_0123456789",
            "request": "$request",
            "target": "com.microsoft.edgemac||normal",
            "bundleIdentifier": "com.microsoft.edgemac",
            "mode": "normal",
            "mechanism": "process",
            "outcome": "launch-error",
        }
        with DriverFixture(
            provenance_records=[record],
            provenance_before_status=True,
            status_records=[
                {"session": "session_0123456789", "outcome": "selected"},
                {"session": "session_0123456789", "outcome": "launch-error"},
            ],
            spawn_browser=False,
            helper_failure_phase="after-status",
        ) as fixture:
            result = fixture.run()
            self.assertEqual(result.exit_code, driver.DRIVER_HELPER_FAILURE)
            self.assertEqual(result.report["outcome"], "helper-error")
            self.assertIn(b'"outcome":"launch-error"', result.status_line)
            self.assertEqual(fixture.terminated_browser_pids, [])

    def test_closed_rejection_is_sanitized_selection_failure(self):
        records = [{"session": "session_0123456789", "outcome": "target-missing"}]
        with DriverFixture(status_records=records) as fixture:
            result = fixture.run()
            self.assertEqual(result.exit_code, driver.DRIVER_SELECTION_REJECTED)
            self.assertEqual(result.report["outcome"], "target-missing")

    def test_closed_rejection_with_launch_provenance_is_a_harness_inconsistency(self):
        provenance = {
            "session": "session_0123456789",
            "request": "$request",
            "target": "com.microsoft.edgemac||normal",
            "bundleIdentifier": "com.microsoft.edgemac",
            "mode": "normal",
            "mechanism": "process",
            "processIdentifier": 123,
            "outcome": "launch-observed",
        }
        termination_attempts = []
        with DriverFixture(
            status_records=[
                {"session": "session_0123456789", "outcome": "target-missing"}
            ],
            provenance_records=[provenance],
            provenance_before_status=True,
            status_delay=0.1,
            spawn_browser=False,
        ) as fixture:
            identity = driver.ProcessIdentity(
                123, fixture.e2e_pid or 1, 2, 123, fixture.browser_executable
            )
            result = fixture.run(
                dependency_overrides={
                    "browser_process_identity": lambda _pid: identity,
                    "browser_process_terminator": (
                        lambda observed,
                        _executable,
                        _deadline: termination_attempts.append(observed) or True
                    ),
                }
            )
            self.assertEqual(result.exit_code, driver.DRIVER_PROVENANCE_FAILURE)
            self.assertEqual(result.report["outcome"], "provenance-error")
            self.assertEqual(fixture.terminated_browser_pids, [])
            self.assertEqual(termination_attempts, [])

    def test_closed_rejection_rejects_coalesced_or_delayed_partial_status(self):
        for delay in (0.0, 0.05):
            with (
                self.subTest(delay=delay),
                DriverFixture(
                    status_records=[
                        {"session": "session_0123456789", "outcome": "target-missing"}
                    ],
                    status_trailing_payload=b'{"session":',
                    status_trailing_delay=delay,
                ) as fixture,
            ):
                result = fixture.run()
                self.assertEqual(result.exit_code, driver.DRIVER_INVALID_STATUS)
                self.assertEqual(result.report["outcome"], "invalid-status")
                self.assertEqual(fixture.terminated_browser_pids, [])

    def test_closed_rejection_rejects_partial_provenance_bytes(self):
        provenance = {
            "session": "session_0123456789",
            "request": "$request",
            "target": "com.microsoft.edgemac||normal",
            "bundleIdentifier": "com.microsoft.edgemac",
            "mode": "normal",
            "mechanism": "process",
            "processIdentifier": 999_999,
            "outcome": "launch-observed",
        }
        with DriverFixture(
            status_records=[
                {"session": "session_0123456789", "outcome": "target-missing"}
            ],
            provenance_records=[provenance],
            provenance_first_partial=True,
            spawn_browser=False,
        ) as fixture:
            result = fixture.run()
            self.assertEqual(result.exit_code, driver.DRIVER_PROVENANCE_FAILURE)
            self.assertEqual(result.report["outcome"], "provenance-error")
            self.assertEqual(fixture.terminated_browser_pids, [])

    def test_invalid_status_after_closed_rejection_revokes_provenance_ownership(self):
        provenance = {
            "session": "session_0123456789",
            "request": "$request",
            "target": "com.microsoft.edgemac||normal",
            "bundleIdentifier": "com.microsoft.edgemac",
            "mode": "normal",
            "mechanism": "process",
            "processIdentifier": 123,
            "outcome": "launch-observed",
        }
        cases = (
            {
                "status_records": [
                    {"session": "session_0123456789", "outcome": "target-missing"},
                    {"session": "session_0123456789", "outcome": "target-missing"},
                ],
            },
            {
                "status_records": [
                    {"session": "session_0123456789", "outcome": "target-missing"}
                ],
                "status_trailing_payload": (
                    b'{"outcome":"target-missing","session":"session_0123456789"}\n'
                ),
                "status_trailing_delay": 0.05,
                "helper_hangs_after_delivery": True,
                "timeout": 0.5,
            },
            {
                "status_records": [
                    {"session": "session_0123456789", "outcome": "target-missing"}
                ],
                "status_trailing_payload": b'{"session":oops}\n',
                "helper_hangs_after_delivery": True,
                "timeout": 0.5,
            },
        )
        for fixture_options in cases:
            termination_attempts = []
            with (
                self.subTest(fixture_options=fixture_options),
                DriverFixture(
                    provenance_records=[provenance],
                    provenance_before_status=True,
                    status_delay=2.0,
                    spawn_browser=False,
                    proof_deadline_phase="status-written",
                    proof_clock_escape=15.0,
                    **fixture_options,
                ) as fixture,
            ):
                identity = driver.ProcessIdentity(
                    123, fixture.e2e_pid or 1, 2, 123, fixture.browser_executable
                )
                result = fixture.run(
                    dependency_overrides={
                        "browser_process_identity": lambda _pid: identity,
                        "browser_process_terminator": (
                            lambda observed,
                            _executable,
                            _deadline: termination_attempts.append(observed) or True
                        ),
                    }
                )
                self.assertEqual(result.exit_code, driver.DRIVER_INVALID_STATUS)
                self.assertEqual(result.report["outcome"], "invalid-status")
                self.assertEqual(termination_attempts, [])

    def test_closed_rejection_helper_failure_keeps_precedence_without_ownership(self):
        provenance = {
            "session": "session_0123456789",
            "request": "$request",
            "target": "com.microsoft.edgemac||normal",
            "bundleIdentifier": "com.microsoft.edgemac",
            "mode": "normal",
            "mechanism": "process",
            "processIdentifier": 123,
            "outcome": "launch-observed",
        }
        termination_attempts = []
        with DriverFixture(
            status_records=[
                {"session": "session_0123456789", "outcome": "target-missing"}
            ],
            provenance_records=[provenance],
            provenance_before_status=True,
            status_delay=0.1,
            spawn_browser=False,
            helper_failure_phase="after-status",
        ) as fixture:
            identity = driver.ProcessIdentity(
                123, fixture.e2e_pid or 1, 2, 123, fixture.browser_executable
            )
            result = fixture.run(
                dependency_overrides={
                    "browser_process_identity": lambda _pid: identity,
                    "browser_process_terminator": (
                        lambda observed,
                        _executable,
                        _deadline: termination_attempts.append(observed) or True
                    ),
                }
            )
            self.assertEqual(result.exit_code, driver.DRIVER_HELPER_FAILURE)
            self.assertEqual(result.report["outcome"], "helper-error")
            self.assertEqual(termination_attempts, [])

    def test_closed_rejection_hanging_helper_timeout_grants_no_ownership(self):
        provenance = {
            "session": "session_0123456789",
            "request": "$request",
            "target": "com.microsoft.edgemac||normal",
            "bundleIdentifier": "com.microsoft.edgemac",
            "mode": "normal",
            "mechanism": "process",
            "processIdentifier": 123,
            "outcome": "launch-observed",
        }
        termination_attempts = []
        with DriverFixture(
            status_records=[
                {"session": "session_0123456789", "outcome": "target-missing"}
            ],
            provenance_records=[provenance],
            provenance_before_status=True,
            status_delay=0.1,
            spawn_browser=False,
            helper_hangs_after_delivery=True,
            timeout=0.5,
            proof_deadline_phase="status-written",
        ) as fixture:
            identity = driver.ProcessIdentity(
                123, fixture.e2e_pid or 1, 2, 123, fixture.browser_executable
            )
            result = fixture.run(
                dependency_overrides={
                    "browser_process_identity": lambda _pid: identity,
                    "browser_process_terminator": (
                        lambda observed,
                        _executable,
                        _deadline: termination_attempts.append(observed) or True
                    ),
                }
            )
            self.assertEqual(result.exit_code, driver.DRIVER_HELPER_FAILURE)
            self.assertEqual(result.report["outcome"], "helper-exit-timeout")
            self.assertIn(b'"outcome":"target-missing"', result.status_line)
            self.assertEqual(termination_attempts, [])

    def test_closed_rejection_revokes_helper_exception_cleanup_authority(self):
        identity = driver.ProcessIdentity(
            123,
            456,
            2,
            123,
            pathlib.Path("/Applications/Browser.app/Browser"),
        )
        owned = frozenset({identity})

        self.assertEqual(
            driver._helper_cleanup_authority(["target-missing"], owned),
            frozenset(),
        )
        self.assertEqual(
            driver._helper_cleanup_authority(["selected"], owned),
            owned,
        )

    def test_closed_rejection_deadline_boundary_helper_error_has_no_owned_generation(
        self,
    ):
        class ManualProcesses:
            def append_manual_stdout(self, _process, _chunk):
                pass

        class ManualProcess:
            def __init__(self, stdout=None):
                self.stdout = stdout
                self.exit_code = None

            def poll(self):
                return self.exit_code

        status_read, status_write = os.pipe()
        provenance_read, provenance_write = os.pipe()
        receipt_read, receipt_write = os.pipe()
        receiver_stream = os.fdopen(receipt_read, "rb", buffering=0)
        helper = ManualProcess()
        app = ManualProcess()
        receiver = ManualProcess(receiver_stream)
        executable = pathlib.Path("/Applications/Browser.app/Browser")
        os.write(
            status_write,
            b'{"outcome":"target-missing","session":"session_0123456789"}\n',
        )
        remaining_calls = 0

        def reach_boundary(_deadline, _monotonic):
            nonlocal remaining_calls
            remaining_calls += 1
            if remaining_calls < 2:
                return 0.1
            helper.exit_code = 23
            raise driver._DeadlineExpired

        dependencies = driver.DriverDependencies(
            browser_process_snapshot=lambda _executable, _phase: set(),
            browser_binding_checker=lambda _application, _executable, _bundle: None,
            browser_running_code_checker=lambda _pid,
            _application,
            _executable,
            _bundle: None,
        )
        try:
            with mock.patch.object(driver, "_remaining", side_effect=reach_boundary):
                with self.assertRaises(driver._HelperError) as raised:
                    driver._wait_for_proof(
                        ManualProcesses(),
                        status_read,
                        provenance_read,
                        receiver,
                        helper,
                        app,
                        "session_0123456789",
                        "request_0123456789",
                        "com.microsoft.edgemac||normal",
                        "com.microsoft.edgemac",
                        "normal",
                        "process",
                        "TOKEN",
                        pathlib.Path("/Applications/Browser.app"),
                        executable,
                        set(),
                        dependencies,
                        time.monotonic() + 1.0,
                    )
            self.assertIn(b'"outcome":"target-missing"', raised.exception.status_line)
            self.assertEqual(raised.exception.owned_browsers, frozenset())
        finally:
            os.close(status_read)
            os.close(status_write)
            os.close(provenance_read)
            os.close(provenance_write)
            os.close(receipt_write)
            receiver_stream.close()

    def test_driver_rejects_adversarial_receipts(self):
        for kind in ("wrong-token", "wrong-remote", "malformed"):
            with self.subTest(kind=kind), DriverFixture(probe_kind=kind) as fixture:
                self.assertEqual(fixture.run().exit_code, driver.DRIVER_INVALID_RECEIPT)

    def test_complete_proof_rejects_second_or_partial_trailing_receipt(self):
        for kind in (
            "duplicate-receipt-coalesced",
            "duplicate-receipt-delayed",
            "partial-trailing-receipt",
        ):
            with self.subTest(kind=kind), DriverFixture(probe_kind=kind) as fixture:
                result = fixture.run()
                self.assertEqual(result.exit_code, driver.DRIVER_INVALID_RECEIPT)
                self.assertEqual(result.report["outcome"], "invalid-receipt")

    def test_complete_proof_rejects_partial_trailing_status_bytes(self):
        with DriverFixture(
            status_trailing_payload=b'{"session":',
            status_trailing_delay=0.24,
        ) as fixture:
            result = fixture.run()
            self.assertEqual(result.exit_code, driver.DRIVER_INVALID_STATUS)
            self.assertEqual(result.report["outcome"], "invalid-status")

    def test_hanging_route_delivery_is_helper_timeout_and_closes_children(self):
        with DriverFixture(
            app_hangs=True,
            timeout=0.25,
            proof_deadline_phase="helper-started",
        ) as fixture:
            result = fixture.run()
            self.assertEqual(result.exit_code, driver.DRIVER_HELPER_FAILURE)
            self.assertEqual(result.report["outcome"], "helper-exit-timeout")
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

    def test_ignored_browser_sigterm_uses_one_shared_cleanup_attempt(self):
        with DriverFixture(browser_survives_termination=True) as fixture:
            result = fixture.run()
            self.assertEqual(result.exit_code, driver.DRIVER_CLEANUP_FAILURE)
            self.assertEqual(result.report["outcome"], "cleanup-error")
            self.assertEqual(len(fixture.terminated_browser_generations), 1)
            self.assertEqual(len(set(fixture.browser_termination_deadlines)), 1)
            self.assertIsNotNone(fixture.browser_termination_deadlines[0])
            self.assertIn("final-sweep", fixture.snapshot_phases)
            self.assertNotIn("final-post-terminate", fixture.snapshot_phases)

    def test_report_distinguishes_route_timeout_from_total_cleanup_elapsed(self):
        with DriverFixture(
            timeout=1.0,
            proof_deadline_phase="complete-proof",
        ) as fixture:
            original = fixture._terminate_browser

            def delayed_termination(identity, executable, deadline=None):
                fixture._sleep_after_proof(1.1)
                return original(identity, executable, deadline)

            result = fixture.run(
                dependency_overrides={
                    "browser_process_terminator": delayed_termination,
                }
            )
            self.assertEqual(result.exit_code, driver.DRIVER_SUCCESS)
            self.assertEqual(result.report["route_timeout_seconds"], 1.0)
            self.assertEqual(
                result.report["browser_cleanup_grace_seconds"],
                5.0,
            )
            self.assertGreater(result.report["total_elapsed_seconds"], 1.0)
            self.assertLessEqual(
                result.report["total_elapsed_seconds"],
                1.0 + driver.BROWSER_CLEANUP_GRACE_SECONDS,
            )

    def test_fixture_proof_clock_captures_cleanup_before_next_sample(self):
        fixture = DriverFixture(
            timeout=1.0,
            proof_deadline_phase="complete-proof",
        )
        self.addCleanup(fixture._remove_tree, fixture.fixture_root)
        with mock.patch.object(fixture, "_proof_phase_is_ready", return_value=False):
            started = fixture._monotonic()
        with mock.patch.object(fixture, "_proof_phase_is_ready", return_value=True):
            fixture._sleep_after_proof(0.02)
            finished = fixture._monotonic()
        self.assertGreaterEqual(finished - started, 0.015)

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
            self.assertEqual(result.report["route_timeout_seconds"], 30.0)
            self.assertGreaterEqual(result.report["total_elapsed_seconds"], 0.0)
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
                expected_mechanism="process",
                session_nonce="session_0123456789",
                route_count=2,
            )
            result = driver.run_driver(config)
            self.assertEqual(result.exit_code, driver.DRIVER_USAGE)
            self.assertEqual(fixture.launched_child_pids, [])

    def test_driver_rejects_nonclosed_expected_mechanism_without_launching(self):
        with DriverFixture() as fixture:
            result = fixture.run(config_overrides={"expected_mechanism": "shell"})
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
            with (
                self.subTest(expected_outcome=expected_outcome),
                make_fixture() as fixture,
            ):
                result = fixture.run(dependency_overrides=overrides)
                self.assertEqual(result.exit_code, expected_code)
                self.assertEqual(result.report["outcome"], expected_outcome)
                self.assertNotIn(
                    fixture.route or "never", result.stdout.decode("ascii")
                )


@unittest.skipIf(driver is None, "PickVia E2E route driver is not implemented")
class ExactAppHelperTests(unittest.TestCase):
    POLICY_HARNESS = r"""
import Foundation

private struct ControlledOpenError: Error {}

private final class CallbackBox: @unchecked Sendable {
  let callback: (RunningApplicationIdentity?, Error?) -> Void

  init(_ callback: @escaping (RunningApplicationIdentity?, Error?) -> Void) {
    self.callback = callback
  }
}

private final class ResultBox: @unchecked Sendable {
  private let lock = NSLock()
  private(set) var attempts = 0
  private(set) var delays = 0
  private(set) var completions: [Bool] = []
  var delayedAction: (() -> Void)?

  func recordAttempt() -> Int {
    lock.lock()
    defer { lock.unlock() }
    attempts += 1
    return attempts
  }

  func recordDelay(action: @escaping () -> Void) {
    lock.lock()
    delays += 1
    delayedAction = action
    lock.unlock()
  }

  func recordCompletion(_ succeeded: Bool) {
    lock.lock()
    completions.append(succeeded)
    lock.unlock()
  }

  func snapshot() -> (Int, Int, [Bool]) {
    lock.lock()
    defer { lock.unlock() }
    return (attempts, delays, completions)
  }
}

enum OpenWithAppPolicyTestMain {
  static func main() {
    let expectedURL = URL(fileURLWithPath: "/private/tmp/PickVia E2E.app")
    let expected = ExpectedRunningApplicationIdentity(
      processIdentifier: 4242,
      bundleIdentifier: "dev.bozhenpeng.PickVia.E2E",
      canonicalBundleURL: expectedURL
    )
    var registrationSnapshots = 0
    var registrationDelays = 0
    let registered = ExactApplicationRegistrationPolicy.wait(
      expected: expected,
      maximumChecks: 4,
      snapshot: {
        registrationSnapshots += 1
        if registrationSnapshots == 4 {
          return [
            RunningApplicationIdentity(
              processIdentifier: 4242,
              bundleIdentifier: "dev.bozhenpeng.PickVia.E2E",
              canonicalBundleURL: expectedURL
            )
          ]
        }
        return [
          RunningApplicationIdentity(
            processIdentifier: registrationSnapshots == 1 ? 3131 : 4242,
            bundleIdentifier: registrationSnapshots == 2
              ? "dev.bozhenpeng.PickVia.Wrong"
              : "dev.bozhenpeng.PickVia.E2E",
            canonicalBundleURL: registrationSnapshots == 3
              ? URL(fileURLWithPath: "/private/tmp/Wrong.app")
              : expectedURL
          )
        ]
      },
      delay: { _ in registrationDelays += 1 }
    )
    precondition(registered)
    precondition(registrationSnapshots == 4)
    precondition(registrationDelays == 3)

    var coldRegistrationSnapshots = 0
    var coldRegistrationDelays = 0
    let coldRegistered = ExactApplicationRegistrationPolicy.wait(
      expected: expected,
      maximumChecks: maximumRegistrationChecks,
      delayInterval: 0,
      snapshot: {
        coldRegistrationSnapshots += 1
        guard coldRegistrationSnapshots == 25 else { return [] }
        return [
          RunningApplicationIdentity(
            processIdentifier: 4242,
            bundleIdentifier: "dev.bozhenpeng.PickVia.E2E",
            canonicalBundleURL: expectedURL
          )
        ]
      },
      delay: { _ in coldRegistrationDelays += 1 }
    )
    precondition(coldRegistered)
    precondition(coldRegistrationSnapshots == 25)
    precondition(coldRegistrationDelays == 24)

    var absentSnapshots = 0
    var absentDelays = 0
    let absent = ExactApplicationRegistrationPolicy.wait(
      expected: expected,
      maximumChecks: 3,
      snapshot: {
        absentSnapshots += 1
        return []
      },
      delay: { _ in absentDelays += 1 }
    )
    precondition(!absent)
    precondition(absentSnapshots == 3)
    precondition(absentDelays == 2)

    let lifetimeResults = ResultBox()
    weak var retainedCoordinator: BoundedOpenCoordinator?
    do {
      let coordinator = BoundedOpenCoordinator(
        expectedApplication: expected,
        maximumAttempts: 2,
        scheduleRetry: { _, action in lifetimeResults.recordDelay(action: action) }
      )
      retainedCoordinator = coordinator
      coordinator.start(
        attempt: { completion in
          _ = lifetimeResults.recordAttempt()
          completion(nil, ControlledOpenError())
        },
        completion: lifetimeResults.recordCompletion
      )
    }
    precondition(retainedCoordinator != nil)
    lifetimeResults.delayedAction?()
    let lifetimeSnapshot = lifetimeResults.snapshot()
    precondition(lifetimeSnapshot.0 == 2)
    precondition(lifetimeSnapshot.1 == 1)
    precondition(lifetimeSnapshot.2 == [false])
    precondition(retainedCoordinator?.failureReason() == .openErrorsExhausted)

    let concurrentResults = ResultBox()
    let concurrentDone = DispatchSemaphore(value: 0)
    let concurrentCoordinator = BoundedOpenCoordinator(
      expectedApplication: expected,
      maximumAttempts: 3,
      scheduleRetry: { _, action in
        concurrentResults.recordDelay(action: action)
        action()
      }
    )
    concurrentCoordinator.start(
      attempt: { completion in
        let attemptNumber = concurrentResults.recordAttempt()
        if attemptNumber == 1 {
          let callbacks = CallbackBox(completion)
          for _ in 0..<24 {
            DispatchQueue.global().async {
              callbacks.callback(nil, ControlledOpenError())
            }
          }
        } else {
          completion(
            RunningApplicationIdentity(
              processIdentifier: 4242,
              bundleIdentifier: "dev.bozhenpeng.PickVia.E2E",
              canonicalBundleURL: expectedURL
            ),
            nil
          )
          completion(nil, ControlledOpenError())
        }
      },
      completion: {
        concurrentResults.recordCompletion($0)
        concurrentDone.signal()
      }
    )
    precondition(concurrentDone.wait(timeout: .now() + 2) == .success)
    Thread.sleep(forTimeInterval: 0.1)
    let concurrentSnapshot = concurrentResults.snapshot()
    precondition(concurrentSnapshot.0 == 2)
    precondition(concurrentSnapshot.1 == 1)
    precondition(concurrentSnapshot.2 == [true])

    let coldOpenResults = ResultBox()
    let coldOpen = BoundedOpenCoordinator(
      expectedApplication: expected,
      maximumAttempts: maximumOpenAttempts,
      retryDelay: 0,
      scheduleRetry: { _, action in
        coldOpenResults.recordDelay(action: action)
        action()
      }
    )
    coldOpen.start(
      attempt: { completion in
        let attemptNumber = coldOpenResults.recordAttempt()
        if attemptNumber < 7 {
          completion(nil, ControlledOpenError())
        } else {
          completion(
            RunningApplicationIdentity(
              processIdentifier: 4242,
              bundleIdentifier: "dev.bozhenpeng.PickVia.E2E",
              canonicalBundleURL: expectedURL
            ),
            nil
          )
        }
      },
      completion: coldOpenResults.recordCompletion
    )
    let coldOpenSnapshot = coldOpenResults.snapshot()
    precondition(coldOpenSnapshot.0 == 7)
    precondition(coldOpenSnapshot.1 == 6)
    precondition(coldOpenSnapshot.2 == [true])
    precondition(coldOpen.failureReason() == nil)

    let wrongReturnResults = ResultBox()
    let wrongReturn = BoundedOpenCoordinator(
      expectedApplication: expected,
      maximumAttempts: 3,
      scheduleRetry: { _, _ in preconditionFailure("identity mismatch retried") }
    )
    wrongReturn.start(
      attempt: { completion in
        _ = wrongReturnResults.recordAttempt()
        completion(
          RunningApplicationIdentity(
            processIdentifier: 9999,
            bundleIdentifier: "dev.bozhenpeng.PickVia.E2E",
            canonicalBundleURL: expectedURL
          ),
          nil
        )
      },
      completion: wrongReturnResults.recordCompletion
    )
    let wrongReturnSnapshot = wrongReturnResults.snapshot()
    precondition(wrongReturnSnapshot.0 == 1)
    precondition(wrongReturnSnapshot.1 == 0)
    precondition(wrongReturnSnapshot.2 == [false])
    precondition(wrongReturn.failureReason() == .identityMismatch)
  }
}

OpenWithAppPolicyTestMain.main()
"""

    @classmethod
    def setUpClass(cls):
        cls.root = pathlib.Path(
            tempfile.mkdtemp(prefix="pickvia-helper-test-", dir="/private/tmp")
        )
        cls.environment = driver._minimal_child_environment(cls.root)
        cls.executable = cls.root / "open_with_app"
        completed = subprocess.run(
            [
                "xcrun",
                "swiftc",
                "-swift-version",
                "6",
                "-warnings-as-errors",
                str(HELPER_SOURCE),
                "-o",
                str(cls.executable),
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=cls.environment,
            timeout=30,
            check=False,
        )
        if completed.returncode != 0:
            raise AssertionError("exact-app helper did not compile")

        cls.policy_source = cls.root / "main.swift"
        helper_source = HELPER_SOURCE.read_text(encoding="utf-8")
        cls.policy_source.write_text(
            helper_source.removeprefix("#!/usr/bin/env swift\n")
            + "\n"
            + cls.POLICY_HARNESS,
            encoding="utf-8",
        )
        cls.policy_executable = cls.root / "open_with_app_policy_tests"

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
            env=self.environment,
            timeout=3,
            check=False,
        )

    def run_policy_subprocess(self, arguments, *, timeout):
        return subprocess.run(
            arguments,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=self.environment,
            timeout=timeout,
            check=False,
        )

    def test_policy_subprocess_runner_uses_only_the_fixed_minimal_environment(self):
        sentinel = "policy-test-parent-secret"
        agent_home_key = "".join(
            chr(value) for value in (67, 79, 68, 69, 88, 95, 72, 79, 77, 69)
        )
        with (
            mock.patch.dict(
                os.environ,
                {
                    "PICKVIA_PARENT_SENTINEL_SECRET": sentinel,
                    agent_home_key: sentinel,
                },
            ),
            mock.patch("subprocess.run") as run,
        ):
            self.run_policy_subprocess(["/usr/bin/true"], timeout=1)

        environment = run.call_args.kwargs["env"]
        self.assertEqual(environment, self.environment)
        self.assertEqual(
            set(environment),
            {"PATH", "LANG", "LC_CTYPE", "TMPDIR", "CFFIXED_USER_HOME"},
        )
        self.assertNotIn(sentinel, environment.values())

    def test_helper_requires_exact_app_and_positive_pid_arguments(self):
        missing = self.run_helper([], b"https://127.0.0.1/token")
        cases = (
            missing,
            self.run_helper(["/Applications/A.app"], b"https://127.0.0.1/token"),
            self.run_helper(
                ["/Applications/A.app", "1", "extra"],
                b"https://127.0.0.1/token",
            ),
            self.run_helper(["/Applications/A.app", "0"], b"https://127.0.0.1/token"),
            self.run_helper(["/Applications/A.app", "-1"], b"https://127.0.0.1/token"),
            self.run_helper(
                ["/Applications/A.app", "not-a-pid"],
                b"https://127.0.0.1/token",
            ),
        )
        for result in cases:
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, b"")
            self.assertEqual(result.stderr, b"invalid arguments\n")

    def test_helper_rejects_non_http_schemes_and_input_above_byte_cap(self):
        cases = (
            (
                ["/Applications/not-an-app", "123"],
                b"https://127.0.0.1/token",
                b"invalid application\n",
            ),
            (
                ["/Applications/A.app", "123"],
                b"file:///private/tmp/secret",
                b"invalid input\n",
            ),
            (
                ["/Applications/A.app", "123"],
                b"ftp://127.0.0.1/token",
                b"invalid input\n",
            ),
            (["/Applications/A.app", "123"], b"x" * 4097, b"invalid input\n"),
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

    def test_helper_registration_and_retry_policies_are_bounded(self):
        compiled = self.run_policy_subprocess(
            [
                "xcrun",
                "swiftc",
                "-swift-version",
                "6",
                "-warnings-as-errors",
                "-DPICKVIA_OPEN_WITH_APP_POLICY_TESTS",
                str(self.policy_source),
                "-o",
                str(self.policy_executable),
            ],
            timeout=30,
        )
        self.assertEqual(compiled.returncode, 0, compiled.stderr.decode("utf-8"))
        completed = self.run_policy_subprocess(
            [str(self.policy_executable)],
            timeout=3,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr.decode("utf-8"))
        self.assertEqual(completed.stdout, b"")
        self.assertEqual(completed.stderr, b"")


if __name__ == "__main__":
    unittest.main()
