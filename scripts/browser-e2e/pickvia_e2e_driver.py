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

MAXIMUM_TIMEOUT_SECONDS = 30.0
MAXIMUM_PROTOCOL_LINE_BYTES = 2_048
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
    target_id: str
    bundle_identifier: str
    mode: str
    session_nonce: str
    timeout: float = 30.0
    route_count: int = 1


def _ignore_process(*args):
    return None


def _ignore_path(*args):
    return None


def _exact_process_identity(process, executable):
    expected = pathlib.Path(executable)
    if sys.platform != "darwin":
        return process.args == [os.fspath(expected)] and process.poll() is None
    try:
        libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        buffer = ctypes.create_string_buffer(4_096)
        byte_count = libproc.proc_pidpath(process.pid, buffer, len(buffer))
        if byte_count <= 0:
            return False
        observed = pathlib.Path(os.fsdecode(buffer.value))
        return observed == expected
    except (OSError, ValueError):
        return False


@dataclasses.dataclass(frozen=True)
class DriverDependencies:
    helper_executable: Optional[pathlib.Path] = None
    helper_source: pathlib.Path = _SCRIPT_DIR / "open_with_app.swift"
    probe_script: pathlib.Path = _SCRIPT_DIR / "localhost_probe.py"
    monotonic: Callable[[], float] = time.monotonic
    process_observer: Callable[
        [str, subprocess.Popen, Sequence[str], Optional[Mapping[str, str]]], None
    ] = _ignore_process
    termination_observer: Callable[[str, int], None] = _ignore_process
    route_observer: Callable[[str], None] = _ignore_path
    before_cleanup: Callable[[pathlib.Path], None] = _ignore_path
    process_identity_checker: Callable[[subprocess.Popen, pathlib.Path], bool] = (
        _exact_process_identity
    )


@dataclasses.dataclass(frozen=True)
class DriverResult:
    exit_code: int
    report: dict
    status_line: bytes = b""
    stdout: bytes = b""
    stderr: bytes = b""


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


class _OwnedProcesses:
    def __init__(self, dependencies):
        self._dependencies = dependencies
        self._children = []

    def start(self, kind, argv, *, environment=None, stdin=None):
        process = subprocess.Popen(
            [os.fspath(value) for value in argv],
            stdin=stdin,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=None if environment is None else dict(environment),
            close_fds=True,
        )
        self._children.append((kind, process))
        self._dependencies.process_observer(kind, process, argv, environment)
        return process

    def close(self):
        for kind, process in reversed(self._children):
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
            finally:
                for stream in (process.stdin, process.stdout, process.stderr):
                    if stream is not None and not stream.closed:
                        stream.close()
                self._dependencies.termination_observer(kind, process.pid)


def _empty_result(exit_code, session="invalid", outcome="driver-error", elapsed=0.0):
    report = {
        "session": session,
        "outcome": outcome,
        "token_received": False,
        "exact_process_identity": False,
        "elapsed_bound_seconds": elapsed,
    }
    stdout = (json.dumps(report, separators=(",", ":"), sort_keys=True) + "\n").encode(
        "ascii"
    )
    return DriverResult(exit_code=exit_code, report=report, stdout=stdout)


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
    if config.route_count != 1:
        return None
    if config.mode not in {"normal", "private"}:
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
    if not _physical_app(e2e_app) or not _physical_app(browser_app):
        return None
    executable = e2e_app / "Contents" / "MacOS" / "PickVia"
    if (
        not executable.is_file()
        or executable.is_symlink()
        or not os.access(executable, os.X_OK)
    ):
        return None
    return timeout, e2e_app, browser_app, executable


def _physical_app(path):
    return (
        path.is_absolute()
        and path.suffix.lower() == ".app"
        and path.is_dir()
        and not path.is_symlink()
        and pathlib.Path(os.path.realpath(path)) == path
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
        raise OSError("unsafe task root")
    root.chmod(0o700)
    return root


def _remaining(deadline, monotonic):
    remaining = deadline - monotonic()
    if remaining <= 0:
        raise _DeadlineExpired
    return remaining


def _read_protocol_line(process, deadline, monotonic):
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
        or not 1 <= port <= 65535
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
    if (
        record["session"] != expected_session
        or record["outcome"] not in _CLOSED_OUTCOMES
    ):
        raise _StatusProtocolError
    return record["outcome"]


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
        process.communicate(timeout=_remaining(deadline, monotonic))
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

    if not hasattr(signal, "SIGTERM"):
        return previous
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


def _wait_for_status_and_receipt(
    fifo_descriptor,
    receiver,
    helper,
    app,
    expected_session,
    expected_token,
    deadline,
    monotonic,
):
    receiver_descriptor = receiver.stdout.fileno()
    os.set_blocking(receiver_descriptor, False)
    selector = selectors.DefaultSelector()
    selector.register(fifo_descriptor, selectors.EVENT_READ, "status")
    selector.register(receiver_descriptor, selectors.EVENT_READ, "receipt")
    buffers = {"status": bytearray(), "receipt": bytearray()}
    status_line = b""
    outcome = None
    receipt = False
    try:
        while True:
            if outcome is not None and outcome != "selected":
                return outcome, receipt, status_line
            if outcome == "selected" and receipt:
                return outcome, receipt, status_line
            try:
                wait = min(_remaining(deadline, monotonic), 0.05)
            except _DeadlineExpired:
                if outcome == "selected" and not receipt:
                    raise TimeoutError("receipt")
                raise
            events = selector.select(wait)
            for key, _ in events:
                try:
                    chunk = os.read(key.fd, 512)
                except BlockingIOError:
                    continue
                if not chunk:
                    continue
                buffer = buffers[key.data]
                buffer.extend(chunk)
                if len(buffer) > MAXIMUM_PROTOCOL_LINE_BYTES:
                    if key.data == "status":
                        raise _StatusProtocolError
                    raise _ReceiptProtocolError
                newline = buffer.find(b"\n")
                if newline < 0:
                    continue
                if newline != len(buffer) - 1:
                    if key.data == "status":
                        raise _StatusProtocolError
                    raise _ReceiptProtocolError
                line = bytes(buffer)
                if key.data == "status":
                    if outcome is not None:
                        raise _StatusProtocolError
                    status_line = line
                    outcome = _parse_status(line, expected_session)
                else:
                    if receipt:
                        raise _ReceiptProtocolError
                    receipt = _parse_receipt(line, expected_token)
            if outcome is None and app.poll() is not None and not buffers["status"]:
                raise ChildProcessError
            if helper.poll() not in (None, 0) and not receipt:
                raise ChildProcessError
            if (
                receiver.poll() not in (None, 0)
                and not receipt
                and not buffers["receipt"]
            ):
                raise ChildProcessError
    finally:
        selector.close()


def run_driver(config, dependencies=None):
    dependencies = dependencies or DriverDependencies()
    validated = _validated_config(config)
    if validated is None:
        return _empty_result(DRIVER_USAGE)
    timeout, e2e_app, browser_app, e2e_executable = validated
    started = dependencies.monotonic()
    deadline = started + timeout
    processes = _OwnedProcesses(dependencies)
    task_root = None
    fifo_descriptor = None
    status_line = b""
    outcome = "driver-error"
    received = False
    exact_identity = False
    exit_code = DRIVER_PROCESS_ERROR
    previous_signals = _install_signal_guards()
    try:
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
        )
        ready_line = _read_protocol_line(receiver, deadline, dependencies.monotonic)
        port, token = _parse_ready(ready_line)

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
        exact_identity = dependencies.process_identity_checker(app, e2e_executable)
        if not exact_identity:
            raise ChildProcessError

        route = f"http://127.0.0.1:{port}/{token}"
        dependencies.route_observer(route)

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
        elif not pathlib.Path(helper_executable).is_file() or not os.access(
            helper_executable, os.X_OK
        ):
            raise _ProtocolError

        helper = processes.start(
            "exact-app-helper",
            [helper_executable, browser_app],
            environment=dict(os.environ),
            stdin=subprocess.PIPE,
        )
        helper.stdin.write(route.encode("ascii"))
        helper.stdin.flush()
        helper.stdin.close()

        outcome, received, status_line = _wait_for_status_and_receipt(
            fifo_descriptor,
            receiver,
            helper,
            app,
            config.session_nonce,
            token,
            deadline,
            dependencies.monotonic,
        )
        if outcome == "selected" and received:
            exit_code = DRIVER_SUCCESS
        else:
            exit_code = DRIVER_SELECTION_REJECTED
    except TimeoutError:
        outcome = "receipt-timeout"
        exit_code = DRIVER_RECEIPT_TIMEOUT
    except _DeadlineExpired:
        outcome = "timeout"
        exit_code = DRIVER_TIMEOUT
    except _StatusProtocolError:
        outcome = "invalid-protocol"
        exit_code = DRIVER_INVALID_STATUS
    except _ReceiptProtocolError:
        outcome = "invalid-protocol"
        exit_code = DRIVER_INVALID_RECEIPT
    except _ProtocolError:
        outcome = "invalid-protocol"
        exit_code = DRIVER_INVALID_RECEIPT
    except ChildProcessError:
        outcome = "process-error"
        exit_code = DRIVER_PROCESS_ERROR
    except (_DriverInterrupted, OSError, ValueError):
        outcome = "driver-error"
        exit_code = DRIVER_PROCESS_ERROR
    finally:
        if fifo_descriptor is not None:
            os.close(fifo_descriptor)
        processes.close()
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
        "exact_process_identity": exact_identity,
        "elapsed_bound_seconds": round(elapsed, 6),
    }
    stdout = (json.dumps(report, separators=(",", ":"), sort_keys=True) + "\n").encode(
        "ascii"
    )
    return DriverResult(
        exit_code=exit_code,
        report=report,
        status_line=status_line,
        stdout=stdout,
    )


class _PrivateArgumentParser(argparse.ArgumentParser):
    def error(self, message):
        self.print_usage(sys.stderr)
        self.exit(DRIVER_USAGE, f"{self.prog}: error: invalid arguments\n")


def main(argv=None):
    parser = _PrivateArgumentParser(description="Run one bounded PickVia E2E route.")
    parser.add_argument("--e2e-app", type=pathlib.Path, required=True)
    parser.add_argument("--browser-app", type=pathlib.Path, required=True)
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
