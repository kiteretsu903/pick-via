#!/usr/bin/env python3

import argparse
import ctypes
import dataclasses
import json
import os
import pathlib
import re
import selectors
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import time
from typing import Callable, Mapping, Optional, Sequence


DRIVER_SUCCESS = 0
DRIVER_USAGE = 2
DRIVER_SELECTION_REJECTED = 10
DRIVER_INVALID_STATUS = 11
DRIVER_RECEIPT_TIMEOUT = 12
DRIVER_TIMEOUT = 13
DRIVER_PROCESS_ERROR = 14
DRIVER_INVALID_RECEIPT = 15
DRIVER_PRIVACY_FAILURE = 16
DRIVER_BROWSER_IDENTITY_TIMEOUT = 17

MAXIMUM_TIMEOUT_SECONDS = 30.0
MAXIMUM_PROTOCOL_LINE_BYTES = 2_048
MAXIMUM_CAPTURE_BYTES = 65_536
MAXIMUM_AUDIT_FILE_BYTES = 8 * 1_024 * 1_024
_SESSION_PATTERN = re.compile(r"\A[A-Za-z0-9_-]{16,64}\Z")
_TOKEN_PATTERN = re.compile(r"\A[A-Za-z0-9_-]+\Z")
_CLOSED_OUTCOMES = frozenset(
    {
        "selected",
        "control-missing",
        "control-malformed",
        "target-missing",
        "target-ambiguous",
        "target-disabled",
        "target-unavailable",
        "target-browser-mismatch",
        "target-mode-mismatch",
        "target-shape-mismatch",
        "non-web-request",
        "launch-error",
    }
)
_SCRIPT_DIR = pathlib.Path(__file__).resolve().parent


@dataclasses.dataclass(frozen=True)
class DriverConfig:
    e2e_app: pathlib.Path
    browser_app: pathlib.Path
    expected_browser_executable: pathlib.Path
    target_id: str
    bundle_identifier: str
    mode: str
    session_nonce: str
    timeout: float = 30.0
    route_count: int = 1


@dataclasses.dataclass(frozen=True)
class ProcessIdentity:
    pid: int
    parent_pid: int
    start_seconds: int
    start_microseconds: int
    executable: pathlib.Path

    @property
    def generation_key(self):
        return (
            self.pid,
            self.start_seconds,
            self.start_microseconds,
            self.executable,
        )


def _ignore(*args):
    return None


def _exact_process_identity(process, executable):
    expected = pathlib.Path(executable)
    if sys.platform != "darwin":
        return process.args == [os.fspath(expected)] and process.poll() is None
    identity = _darwin_process_identity(process.pid)
    return identity is not None and identity.executable == expected


class _ProcBSDInfo(ctypes.Structure):
    _fields_ = [
        ("pbi_flags", ctypes.c_uint32),
        ("pbi_status", ctypes.c_uint32),
        ("pbi_xstatus", ctypes.c_uint32),
        ("pbi_pid", ctypes.c_uint32),
        ("pbi_ppid", ctypes.c_uint32),
        ("pbi_uid", ctypes.c_uint32),
        ("pbi_gid", ctypes.c_uint32),
        ("pbi_ruid", ctypes.c_uint32),
        ("pbi_rgid", ctypes.c_uint32),
        ("pbi_svuid", ctypes.c_uint32),
        ("pbi_svgid", ctypes.c_uint32),
        ("rfu_1", ctypes.c_uint32),
        ("pbi_comm", ctypes.c_char * 16),
        ("pbi_name", ctypes.c_char * 32),
        ("pbi_nfiles", ctypes.c_uint32),
        ("pbi_pgid", ctypes.c_uint32),
        ("pbi_pjobc", ctypes.c_uint32),
        ("e_tdev", ctypes.c_uint32),
        ("e_tpgid", ctypes.c_uint32),
        ("pbi_nice", ctypes.c_int32),
        ("pbi_start_tvsec", ctypes.c_uint64),
        ("pbi_start_tvusec", ctypes.c_uint64),
    ]


def _load_libproc():
    library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    library.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    library.proc_pidpath.restype = ctypes.c_int
    library.proc_pidinfo.argtypes = [
        ctypes.c_int,
        ctypes.c_int,
        ctypes.c_uint64,
        ctypes.c_void_p,
        ctypes.c_int,
    ]
    library.proc_pidinfo.restype = ctypes.c_int
    library.proc_listpids.argtypes = [
        ctypes.c_uint32,
        ctypes.c_uint32,
        ctypes.c_void_p,
        ctypes.c_int,
    ]
    library.proc_listpids.restype = ctypes.c_int
    return library


def _darwin_process_identity(pid, library=None):
    try:
        library = library or _load_libproc()
        path_buffer = ctypes.create_string_buffer(4_096)
        if library.proc_pidpath(pid, path_buffer, len(path_buffer)) <= 0:
            return None
        info = _ProcBSDInfo()
        if library.proc_pidinfo(
            pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info)
        ) != ctypes.sizeof(info):
            return None
        return ProcessIdentity(
            pid=pid,
            parent_pid=int(info.pbi_ppid),
            start_seconds=int(info.pbi_start_tvsec),
            start_microseconds=int(info.pbi_start_tvusec),
            executable=pathlib.Path(os.fsdecode(path_buffer.value)),
        )
    except (OSError, ValueError):
        return None


def _snapshot_exact_browser_processes(executable):
    expected = pathlib.Path(executable)
    if sys.platform != "darwin":
        return frozenset()
    try:
        library = _load_libproc()
        required_bytes = library.proc_listpids(1, 0, None, 0)
        if required_bytes <= 0:
            return frozenset()
        count = required_bytes // ctypes.sizeof(ctypes.c_int) + 128
        pids = (ctypes.c_int * count)()
        used_bytes = library.proc_listpids(1, 0, pids, ctypes.sizeof(pids))
        identities = set()
        for pid in pids[: max(used_bytes, 0) // ctypes.sizeof(ctypes.c_int)]:
            if pid <= 0:
                continue
            identity = _darwin_process_identity(pid, library)
            if identity is not None and identity.executable == expected:
                identities.add(identity)
        return frozenset(identities)
    except (OSError, ValueError):
        return frozenset()


def _terminate_exact_browser_process(identity, executable):
    expected = pathlib.Path(executable)
    current = _snapshot_exact_browser_processes(expected)
    if not any(item.generation_key == identity.generation_key for item in current):
        return False
    try:
        os.kill(identity.pid, signal.SIGTERM)
    except ProcessLookupError:
        return True
    deadline = time.monotonic() + 1.0
    while time.monotonic() < deadline:
        current = _snapshot_exact_browser_processes(expected)
        if not any(item.generation_key == identity.generation_key for item in current):
            return True
        time.sleep(0.02)
    return False


@dataclasses.dataclass(frozen=True)
class DriverDependencies:
    helper_executable: Optional[pathlib.Path] = None
    helper_source: pathlib.Path = _SCRIPT_DIR / "open_with_app.swift"
    probe_script: pathlib.Path = _SCRIPT_DIR / "localhost_probe.py"
    monotonic: Callable[[], float] = time.monotonic
    process_observer: Callable[
        [str, subprocess.Popen, Sequence[str], Optional[Mapping[str, str]]], None
    ] = _ignore
    termination_observer: Callable[[str, int], None] = _ignore
    route_observer: Callable[[str], None] = _ignore
    before_cleanup: Callable[[pathlib.Path], None] = _ignore
    process_identity_checker: Callable[[subprocess.Popen, pathlib.Path], bool] = (
        _exact_process_identity
    )
    browser_process_snapshot: Callable[[pathlib.Path], frozenset] = (
        _snapshot_exact_browser_processes
    )
    browser_process_terminator: Callable[[ProcessIdentity, pathlib.Path], bool] = (
        _terminate_exact_browser_process
    )
    capture_observer: Callable[[str, str, bytes, bool], None] = _ignore


@dataclasses.dataclass(frozen=True)
class DriverResult:
    exit_code: int
    report: dict
    status_line: bytes = b""
    stdout: bytes = b""
    stderr: bytes = b""


@dataclasses.dataclass(frozen=True)
class _WaitResult:
    outcome: str
    token_received: bool
    status_line: bytes
    exact_browser_identity: bool
    owned_browser_identities: frozenset


class _DriverInterrupted(Exception):
    pass


class _ProtocolError(Exception):
    pass


class _StatusProtocolError(_ProtocolError):
    pass


class _ReceiptProtocolError(_ProtocolError):
    pass


class _DeadlineExpired(Exception):
    pass


class _ProofTimeout(Exception):
    def __init__(self, token_received, status_line, browser_identity, owned_browsers):
        super().__init__()
        self.token_received = token_received
        self.status_line = status_line
        self.browser_identity = browser_identity
        self.owned_browsers = frozenset(owned_browsers)


class _ReceiptTimeout(_ProofTimeout):
    pass


class _BrowserIdentityTimeout(_ProofTimeout):
    pass


class _BoundedCapture:
    def __init__(self):
        self._contents = bytearray()
        self._overflow = False
        self._lock = threading.Lock()

    def append(self, chunk):
        with self._lock:
            remaining = MAXIMUM_CAPTURE_BYTES - len(self._contents)
            if remaining > 0:
                self._contents.extend(chunk[:remaining])
            if len(chunk) > remaining:
                self._overflow = True

    def snapshot(self):
        with self._lock:
            return bytes(self._contents), self._overflow


@dataclasses.dataclass
class _OwnedChild:
    kind: str
    process: subprocess.Popen
    captures: dict
    threads: list
    manual_stdout: bool


class _OwnedProcesses:
    def __init__(self, dependencies):
        self._dependencies = dependencies
        self._children = []
        self._closed = False

    def start(self, kind, argv, *, environment=None, stdin=None, manual_stdout=False):
        process = subprocess.Popen(
            [os.fspath(value) for value in argv],
            stdin=stdin,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=None if environment is None else dict(environment),
            close_fds=True,
        )
        captures = {"stdout": _BoundedCapture(), "stderr": _BoundedCapture()}
        child = _OwnedChild(kind, process, captures, [], manual_stdout)
        self._children.append(child)
        if not manual_stdout:
            child.threads.append(self._start_reader(process.stdout, captures["stdout"]))
        child.threads.append(self._start_reader(process.stderr, captures["stderr"]))
        self._dependencies.process_observer(kind, process, argv, environment)
        return process

    def _start_reader(self, stream, capture):
        def drain():
            try:
                while True:
                    chunk = stream.read(4_096)
                    if not chunk:
                        return
                    capture.append(chunk)
            except (OSError, ValueError):
                return

        thread = threading.Thread(target=drain, daemon=True)
        thread.start()
        return thread

    def append_manual_stdout(self, process, chunk):
        self._child(process).captures["stdout"].append(chunk)

    def _child(self, process):
        return next(child for child in self._children if child.process is process)

    def close(self):
        if self._closed:
            return
        self._closed = True
        for child in reversed(self._children):
            process = child.process
            try:
                if process.poll() is None:
                    try:
                        process.terminate()
                        process.wait(timeout=0.5)
                    except (ProcessLookupError, subprocess.TimeoutExpired):
                        if process.poll() is None:
                            try:
                                process.kill()
                            except ProcessLookupError:
                                pass
                            try:
                                process.wait(timeout=0.5)
                            except subprocess.TimeoutExpired:
                                pass
                if child.manual_stdout:
                    self._drain_manual_stream(process.stdout, child.captures["stdout"])
                for thread in child.threads:
                    thread.join(timeout=0.5)
            finally:
                for stream in (process.stdin, process.stdout, process.stderr):
                    if stream is not None and not stream.closed:
                        stream.close()
                for channel, capture in child.captures.items():
                    contents, overflow = capture.snapshot()
                    self._dependencies.capture_observer(
                        child.kind, channel, contents, overflow
                    )
                self._dependencies.termination_observer(child.kind, process.pid)

    def _drain_manual_stream(self, stream, capture):
        try:
            os.set_blocking(stream.fileno(), False)
            while True:
                try:
                    chunk = os.read(stream.fileno(), 4_096)
                except BlockingIOError:
                    return
                if not chunk:
                    return
                capture.append(chunk)
        except (OSError, ValueError):
            return

    def violates_privacy(self, forbidden):
        for child in self._children:
            for capture in child.captures.values():
                contents, overflow = capture.snapshot()
                if overflow or forbidden in contents:
                    return True
        return False


def _empty_result(exit_code):
    report = {
        "session": "invalid",
        "outcome": "driver-error",
        "token_received": False,
        "exact_process_identity": False,
        "exact_browser_process_identity": False,
        "elapsed_bound_seconds": 0.0,
    }
    return DriverResult(
        exit_code=exit_code,
        report=report,
        stdout=_encoded_report(report),
    )


def _encoded_report(report):
    return (json.dumps(report, separators=(",", ":"), sort_keys=True) + "\n").encode(
        "ascii"
    )


def _valid_nonempty(value, maximum_bytes):
    if (
        not isinstance(value, str)
        or not value
        or len(value.encode("utf-8")) > maximum_bytes
    ):
        return False
    return not any(
        ord(character) < 0x20 or ord(character) == 0x7F for character in value
    )


def _validated_config(config):
    if config.route_count != 1 or config.mode not in {"normal", "private"}:
        return None
    if not _valid_nonempty(config.target_id, 512):
        return None
    if not _valid_nonempty(config.bundle_identifier, 255):
        return None
    if _SESSION_PATTERN.fullmatch(config.session_nonce) is None:
        return None
    try:
        timeout = min(float(config.timeout), MAXIMUM_TIMEOUT_SECONDS)
    except (TypeError, ValueError):
        return None
    if timeout <= 0:
        return None

    e2e_app = pathlib.Path(config.e2e_app)
    browser_app = pathlib.Path(config.browser_app)
    browser_executable = pathlib.Path(config.expected_browser_executable)
    if not _physical_app(e2e_app) or not _physical_app(browser_app):
        return None
    e2e_executable = e2e_app / "Contents" / "MacOS" / "PickVia"
    if not _physical_executable(e2e_executable):
        return None
    if not _physical_executable(browser_executable):
        return None
    try:
        browser_executable.relative_to(browser_app / "Contents" / "MacOS")
    except ValueError:
        return None
    return timeout, e2e_app, e2e_executable, browser_executable


def _physical_app(path):
    return (
        path.is_absolute()
        and path.suffix.lower() == ".app"
        and path.is_dir()
        and not path.is_symlink()
        and pathlib.Path(os.path.realpath(path)) == path
    )


def _physical_executable(path):
    return (
        path.is_absolute()
        and path.is_file()
        and not path.is_symlink()
        and pathlib.Path(os.path.realpath(path)) == path
        and os.access(path, os.X_OK)
    )


def _make_task_root():
    root = pathlib.Path(tempfile.mkdtemp(prefix="pickvia-e2e-", dir="/private/tmp"))
    metadata = root.lstat()
    if (
        root.parent != pathlib.Path("/private/tmp")
        or not stat.S_ISDIR(metadata.st_mode)
        or stat.S_ISLNK(metadata.st_mode)
        or metadata.st_uid != os.getuid()
        or pathlib.Path(os.path.realpath(root)) != root
    ):
        shutil.rmtree(root, ignore_errors=True)
        raise OSError("unsafe task root")
    root.chmod(0o700)
    return root


def _remaining(deadline, monotonic):
    remaining = deadline - monotonic()
    if remaining <= 0:
        raise _DeadlineExpired
    return remaining


def _read_protocol_line(processes, process, deadline, monotonic):
    descriptor = process.stdout.fileno()
    os.set_blocking(descriptor, False)
    selector = selectors.DefaultSelector()
    selector.register(descriptor, selectors.EVENT_READ)
    buffer = bytearray()
    try:
        while True:
            events = selector.select(min(_remaining(deadline, monotonic), 0.05))
            if not events:
                if process.poll() is not None:
                    raise _ProtocolError
                continue
            chunk = os.read(descriptor, 512)
            if not chunk:
                raise _ProtocolError
            processes.append_manual_stdout(process, chunk)
            buffer.extend(chunk)
            if len(buffer) > MAXIMUM_PROTOCOL_LINE_BYTES:
                raise _ProtocolError
            newline = buffer.find(b"\n")
            if newline >= 0:
                if newline != len(buffer) - 1:
                    raise _ProtocolError
                return bytes(buffer)
    finally:
        selector.close()


def _parse_ready(line):
    try:
        record = json.loads(line)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise _ProtocolError from error
    if not isinstance(record, dict) or set(record) != {"port", "tokens"}:
        raise _ProtocolError
    port = record["port"]
    tokens = record["tokens"]
    if (
        not isinstance(port, int)
        or isinstance(port, bool)
        or not 1 <= port <= 65_535
        or not isinstance(tokens, list)
        or len(tokens) != 1
        or not isinstance(tokens[0], str)
        or _TOKEN_PATTERN.fullmatch(tokens[0]) is None
    ):
        raise _ProtocolError
    return port, tokens[0]


def _parse_status(line, expected_session):
    try:
        record = json.loads(line)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise _StatusProtocolError from error
    if not isinstance(record, dict) or set(record) != {"session", "outcome"}:
        raise _StatusProtocolError
    session = record["session"]
    outcome = record["outcome"]
    if not isinstance(session, str) or not isinstance(outcome, str):
        raise _StatusProtocolError
    if session != expected_session or outcome not in _CLOSED_OUTCOMES:
        raise _StatusProtocolError
    return outcome


def _parse_receipt(line, expected_token):
    try:
        record = json.loads(line)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise _ReceiptProtocolError from error
    if not isinstance(record, dict) or set(record) != {
        "token",
        "receipt_time",
        "remote_address",
    }:
        raise _ReceiptProtocolError
    if (
        record["token"] != expected_token
        or record["remote_address"] != "127.0.0.1"
        or not isinstance(record["receipt_time"], (int, float))
        or isinstance(record["receipt_time"], bool)
    ):
        raise _ReceiptProtocolError
    return True


def _compile_helper(processes, source, output, deadline, monotonic):
    if not source.is_file() or source.is_symlink():
        raise _ProtocolError
    process = processes.start(
        "helper-compiler",
        ["/usr/bin/xcrun", "swiftc", source, "-o", output],
        stdin=subprocess.DEVNULL,
    )
    try:
        process.wait(timeout=_remaining(deadline, monotonic))
    except subprocess.TimeoutExpired as error:
        raise _DeadlineExpired from error
    if (
        process.returncode != 0
        or not output.is_file()
        or not os.access(output, os.X_OK)
    ):
        raise _ProtocolError


def _install_signal_guards():
    previous = {}

    def interrupt(signum, frame):
        raise _DriverInterrupted

    try:
        for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            previous[signum] = signal.signal(signum, interrupt)
    except ValueError:
        for signum, handler in previous.items():
            signal.signal(signum, handler)
        return {}
    return previous


def _restore_signal_guards(previous):
    for signum, handler in previous.items():
        signal.signal(signum, handler)


def _consume_status_lines(buffer, sequence, expected_session):
    consumed = []
    while True:
        newline = buffer.find(b"\n")
        if newline < 0:
            return consumed
        line = bytes(buffer[: newline + 1])
        del buffer[: newline + 1]
        outcome = _parse_status(line, expected_session)
        if not sequence:
            sequence.append(outcome)
        elif sequence == ["selected"] and outcome == "launch-error":
            sequence.append(outcome)
        else:
            raise _StatusProtocolError
        consumed.append(line)


def _wait_for_proof(
    processes,
    fifo_descriptor,
    receiver,
    helper,
    app,
    expected_session,
    expected_token,
    expected_browser_executable,
    preexisting_browsers,
    dependencies,
    deadline,
):
    receiver_descriptor = receiver.stdout.fileno()
    os.set_blocking(receiver_descriptor, False)
    selector = selectors.DefaultSelector()
    selector.register(fifo_descriptor, selectors.EVENT_READ, "status")
    selector.register(receiver_descriptor, selectors.EVENT_READ, "receipt")
    buffers = {"status": bytearray(), "receipt": bytearray()}
    status_sequence = []
    status_lines = []
    receipt = False
    browser_identity = False
    owned_browsers = set()
    try:
        while True:
            if status_sequence == ["selected", "launch-error"]:
                return _WaitResult(
                    "launch-error",
                    receipt,
                    b"".join(status_lines),
                    browser_identity,
                    frozenset(owned_browsers),
                )
            if status_sequence and status_sequence[0] != "selected":
                return _WaitResult(
                    status_sequence[0],
                    receipt,
                    b"".join(status_lines),
                    browser_identity,
                    frozenset(owned_browsers),
                )
            if status_sequence == ["selected"]:
                current = set(
                    dependencies.browser_process_snapshot(expected_browser_executable)
                )
                browser_identity = bool(current)
                owned_browsers.update(
                    identity
                    for identity in current
                    if identity not in preexisting_browsers
                    and identity.parent_pid == app.pid
                )
                if receipt and browser_identity:
                    return _WaitResult(
                        "selected",
                        True,
                        b"".join(status_lines),
                        True,
                        frozenset(owned_browsers),
                    )
            try:
                wait = min(_remaining(deadline, dependencies.monotonic), 0.05)
            except _DeadlineExpired:
                if status_sequence == ["selected"] and not receipt:
                    raise _ReceiptTimeout(
                        receipt,
                        b"".join(status_lines),
                        browser_identity,
                        owned_browsers,
                    )
                if status_sequence == ["selected"] and not browser_identity:
                    raise _BrowserIdentityTimeout(
                        receipt,
                        b"".join(status_lines),
                        browser_identity,
                        owned_browsers,
                    )
                raise
            for key, _ in selector.select(wait):
                try:
                    chunk = os.read(key.fd, 512)
                except BlockingIOError:
                    continue
                if not chunk:
                    continue
                if key.data == "receipt":
                    processes.append_manual_stdout(receiver, chunk)
                buffer = buffers[key.data]
                buffer.extend(chunk)
                if len(buffer) > MAXIMUM_PROTOCOL_LINE_BYTES:
                    if key.data == "status":
                        raise _StatusProtocolError
                    raise _ReceiptProtocolError
                if key.data == "status":
                    status_lines.extend(
                        _consume_status_lines(buffer, status_sequence, expected_session)
                    )
                else:
                    newline = buffer.find(b"\n")
                    if newline >= 0:
                        line = bytes(buffer[: newline + 1])
                        del buffer[: newline + 1]
                        if receipt:
                            raise _ReceiptProtocolError
                        receipt = _parse_receipt(line, expected_token)
            if not status_sequence and app.poll() is not None and not buffers["status"]:
                raise ChildProcessError
            if helper.poll() not in (None, 0) and not receipt and not status_sequence:
                raise ChildProcessError
            if (
                receiver.poll() not in (None, 0)
                and not receipt
                and not buffers["receipt"]
            ):
                raise ChildProcessError
    finally:
        selector.close()


def _audit_regular_files(root, forbidden):
    for path in root.rglob("*"):
        try:
            metadata = path.lstat()
        except FileNotFoundError:
            continue
        if stat.S_ISLNK(metadata.st_mode):
            return False
        if not stat.S_ISREG(metadata.st_mode):
            continue
        if metadata.st_size > MAXIMUM_AUDIT_FILE_BYTES:
            return False
        previous = b""
        with path.open("rb") as stream:
            while True:
                chunk = stream.read(65_536)
                if not chunk:
                    break
                combined = previous + chunk
                if forbidden in combined:
                    return False
                previous = combined[-max(len(forbidden) - 1, 0) :]
    return True


def run_driver(config, dependencies=None):
    dependencies = dependencies or DriverDependencies()
    validated = _validated_config(config)
    if validated is None:
        return _empty_result(DRIVER_USAGE)
    timeout, e2e_app, e2e_executable, browser_executable = validated
    started = dependencies.monotonic()
    deadline = started + timeout
    processes = _OwnedProcesses(dependencies)
    task_root = None
    fifo_descriptor = None
    route_bytes = None
    status_line = b""
    outcome = "driver-error"
    received = False
    exact_e2e_identity = False
    exact_browser_identity = False
    exit_code = DRIVER_PROCESS_ERROR
    app = None
    preexisting_browsers = set()
    owned_browsers = set()
    cleanup_ok = True
    previous_signals = _install_signal_guards()
    try:
        preexisting_browsers = set(
            dependencies.browser_process_snapshot(browser_executable)
        )
        task_root = _make_task_root()
        fifo = task_root / "status.fifo"
        os.mkfifo(fifo, 0o600)
        os.chmod(fifo, 0o600)
        fifo_descriptor = os.open(
            fifo,
            os.O_RDWR | os.O_NONBLOCK | getattr(os, "O_CLOEXEC", 0),
        )
        receiver = processes.start(
            "receiver",
            [
                sys.executable,
                dependencies.probe_script,
                "--token-count",
                "1",
                "--wait-for-receipts",
                "1",
            ],
            stdin=subprocess.DEVNULL,
            manual_stdout=True,
        )
        ready = _read_protocol_line(
            processes, receiver, deadline, dependencies.monotonic
        )
        port, token = _parse_ready(ready)

        environment = dict(os.environ)
        environment.update(
            {
                "PICKVIA_E2E_TARGET_ID": config.target_id,
                "PICKVIA_E2E_BUNDLE_ID": config.bundle_identifier,
                "PICKVIA_E2E_MODE": config.mode,
                "PICKVIA_E2E_SESSION_NONCE": config.session_nonce,
                "PICKVIA_E2E_SUPPORT_DIR": os.fspath(task_root),
                "PICKVIA_E2E_STATUS_FIFO": os.fspath(fifo),
            }
        )
        app = processes.start(
            "e2e-app",
            [e2e_executable],
            environment=environment,
            stdin=subprocess.DEVNULL,
        )
        exact_e2e_identity = dependencies.process_identity_checker(app, e2e_executable)
        if not exact_e2e_identity:
            raise ChildProcessError

        route_bytes = f"http://127.0.0.1:{port}/{token}".encode("ascii")
        dependencies.route_observer(route_bytes.decode("ascii"))
        helper_executable = dependencies.helper_executable
        if helper_executable is None:
            helper_executable = task_root / "open_with_app"
            _compile_helper(
                processes,
                pathlib.Path(dependencies.helper_source),
                helper_executable,
                deadline,
                dependencies.monotonic,
            )
        elif not _physical_executable(pathlib.Path(helper_executable)):
            raise _ProtocolError

        helper = processes.start(
            "exact-app-helper",
            [helper_executable, e2e_app],
            environment=dict(os.environ),
            stdin=subprocess.PIPE,
        )
        helper.stdin.write(route_bytes)
        helper.stdin.flush()
        helper.stdin.close()

        proof = _wait_for_proof(
            processes,
            fifo_descriptor,
            receiver,
            helper,
            app,
            config.session_nonce,
            token,
            browser_executable,
            preexisting_browsers,
            dependencies,
            deadline,
        )
        outcome = proof.outcome
        received = proof.token_received
        status_line = proof.status_line
        exact_browser_identity = proof.exact_browser_identity
        owned_browsers.update(proof.owned_browser_identities)
        exit_code = (
            DRIVER_SUCCESS if outcome == "selected" else DRIVER_SELECTION_REJECTED
        )
    except _ReceiptTimeout as error:
        outcome = "receipt-timeout"
        received = error.token_received
        status_line = error.status_line
        exact_browser_identity = error.browser_identity
        owned_browsers.update(error.owned_browsers)
        exit_code = DRIVER_RECEIPT_TIMEOUT
    except _BrowserIdentityTimeout as error:
        outcome = "browser-identity-timeout"
        received = error.token_received
        status_line = error.status_line
        exact_browser_identity = error.browser_identity
        owned_browsers.update(error.owned_browsers)
        exit_code = DRIVER_BROWSER_IDENTITY_TIMEOUT
    except _DeadlineExpired:
        outcome = "timeout"
        exit_code = DRIVER_TIMEOUT
    except _StatusProtocolError:
        outcome = "invalid-status"
        exit_code = DRIVER_INVALID_STATUS
    except _ReceiptProtocolError:
        outcome = "invalid-receipt"
        exit_code = DRIVER_INVALID_RECEIPT
    except _ProtocolError:
        outcome = "invalid-receipt"
        exit_code = DRIVER_INVALID_RECEIPT
    except ChildProcessError:
        outcome = "process-error"
        exit_code = DRIVER_PROCESS_ERROR
    except (_DriverInterrupted, OSError, ValueError, TypeError):
        outcome = "driver-error"
        exit_code = DRIVER_PROCESS_ERROR
    finally:
        if app is not None:
            try:
                current = set(dependencies.browser_process_snapshot(browser_executable))
                owned_browsers.update(
                    identity
                    for identity in current
                    if identity not in preexisting_browsers
                    and identity.parent_pid == app.pid
                )
            except (OSError, ValueError, TypeError):
                cleanup_ok = False
        for identity in owned_browsers:
            try:
                cleanup_ok = (
                    dependencies.browser_process_terminator(
                        identity, browser_executable
                    )
                    and cleanup_ok
                )
            except (OSError, ValueError, TypeError):
                cleanup_ok = False
        if fifo_descriptor is not None:
            os.close(fifo_descriptor)
        processes.close()
        if route_bytes is not None:
            if processes.violates_privacy(route_bytes):
                outcome = "privacy-failure"
                exit_code = DRIVER_PRIVACY_FAILURE
            if task_root is not None and not _audit_regular_files(
                task_root, route_bytes
            ):
                outcome = "privacy-failure"
                exit_code = DRIVER_PRIVACY_FAILURE
        if not cleanup_ok and exit_code == DRIVER_SUCCESS:
            outcome = "cleanup-error"
            exit_code = DRIVER_PROCESS_ERROR
        if task_root is not None:
            try:
                dependencies.before_cleanup(task_root)
            finally:
                metadata = task_root.lstat() if task_root.exists() else None
                if metadata is not None and stat.S_ISDIR(metadata.st_mode):
                    shutil.rmtree(task_root)
        _restore_signal_guards(previous_signals)

    elapsed = min(max(dependencies.monotonic() - started, 0.0), timeout)
    report = {
        "session": config.session_nonce,
        "outcome": outcome,
        "token_received": received,
        "exact_process_identity": exact_e2e_identity,
        "exact_browser_process_identity": exact_browser_identity,
        "elapsed_bound_seconds": round(elapsed, 6),
    }
    return DriverResult(
        exit_code=exit_code,
        report=report,
        status_line=status_line,
        stdout=_encoded_report(report),
    )


class _PrivateArgumentParser(argparse.ArgumentParser):
    def error(self, message):
        self.print_usage(sys.stderr)
        self.exit(DRIVER_USAGE, f"{self.prog}: error: invalid arguments\n")


def main(argv=None):
    parser = _PrivateArgumentParser(description="Run one bounded PickVia E2E route.")
    parser.add_argument("--e2e-app", type=pathlib.Path, required=True)
    parser.add_argument("--browser-app", type=pathlib.Path, required=True)
    parser.add_argument(
        "--expected-browser-executable", type=pathlib.Path, required=True
    )
    parser.add_argument("--target-id", required=True)
    parser.add_argument("--bundle-id", required=True)
    parser.add_argument("--mode", choices=("normal", "private"), required=True)
    parser.add_argument("--session", required=True)
    parser.add_argument("--timeout", type=float, default=30.0)
    parser.add_argument("--route-count", type=int, default=1)
    arguments = parser.parse_args(argv)
    result = run_driver(
        DriverConfig(
            e2e_app=arguments.e2e_app,
            browser_app=arguments.browser_app,
            expected_browser_executable=arguments.expected_browser_executable,
            target_id=arguments.target_id,
            bundle_identifier=arguments.bundle_id,
            mode=arguments.mode,
            session_nonce=arguments.session,
            timeout=arguments.timeout,
            route_count=arguments.route_count,
        )
    )
    sys.stdout.buffer.write(result.stdout)
    sys.stdout.buffer.flush()
    return result.exit_code


if __name__ == "__main__":
    raise SystemExit(main())
