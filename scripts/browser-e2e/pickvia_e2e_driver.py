#!/usr/bin/env python3

import argparse
import ctypes
import dataclasses
import errno
import hashlib
import json
import math
import os
import pathlib
import plistlib
import re
import secrets
import selectors
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
DRIVER_READINESS_FAILURE = 18
DRIVER_HELPER_FAILURE = 19
DRIVER_IDENTITY_FAILURE = 20
DRIVER_BROWSER_IDENTITY_AMBIGUOUS = 21
DRIVER_CLEANUP_FAILURE = 22
DRIVER_PROVENANCE_FAILURE = 23

MAXIMUM_TIMEOUT_SECONDS = 30.0
BROWSER_CLEANUP_GRACE_SECONDS = 5.0
BROWSER_QUIESCENCE_SECONDS = 2.0
BROWSER_QUIESCENCE_POLL_SECONDS = 0.1
# One complete provenance proof remains open for this bounded interval so delayed
# duplicate or partial records cannot be mistaken for an exactly-once launch.
PROVENANCE_SETTLE_SECONDS = 0.25
# A launch-error/unproven record may precede AppDelegate's status write. Keep the
# route bounded while collecting that factual status and helper exit.
PROVENANCE_STATUS_GRACE_SECONDS = 1.0
BROWSER_BINDING_VERIFICATION_TIMEOUT_SECONDS = 2.0
MAXIMUM_PROTOCOL_LINE_BYTES = 2_048
MAXIMUM_PROVENANCE_LINE_BYTES = 512
MAXIMUM_CAPTURE_BYTES = 65_536
MAXIMUM_AUDIT_FILE_BYTES = 8 * 1_024 * 1_024
MAXIMUM_AUDIT_ENTRIES = 4_096
MAXIMUM_AUDIT_PASSES = 3
MAXIMUM_AUDIT_SECONDS = 2.0
MAXIMUM_AUDIT_WORK_BYTES = MAXIMUM_AUDIT_FILE_BYTES * MAXIMUM_AUDIT_PASSES
MAXIMUM_AUDIT_WORK_ENTRIES = MAXIMUM_AUDIT_ENTRIES * MAXIMUM_AUDIT_PASSES * 4
EXCLUSIVE_CLEANUP_TIMEOUT_SECONDS = 2.0
EXCLUSIVE_CLEANUP_COMPILE_TIMEOUT_SECONDS = 10.0
MAXIMUM_CLEANUP_SOURCE_BYTES = 256 * 1_024
MAXIMUM_CLEANUP_HELPER_BYTES = 8 * 1_024 * 1_024
BROWSER_CODE_IDENTITY_TIMEOUT_SECONDS = 2.0
BROWSER_CODE_IDENTITY_COMPILE_TIMEOUT_SECONDS = 10.0
MAXIMUM_BROWSER_CODE_IDENTITY_SOURCE_BYTES = 64 * 1_024
MAXIMUM_BROWSER_CODE_IDENTITY_OUTPUT_BYTES = 64
MAXIMUM_CLEANUP_RECORD_BYTES = 4 * 1_024
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
_PROVENANCE_OUTCOMES = frozenset({"launch-observed", "launch-unproven", "launch-error"})
_PROVENANCE_MECHANISMS = frozenset({"process", "workspace", "duckduckgo"})
_PROFILE_STRATEGIES = frozenset({"chromium", "firefox"})
_DEFERRED_SIGNALS = frozenset({signal.SIGINT, signal.SIGTERM, signal.SIGHUP})
_SCRIPT_DIR = pathlib.Path(__file__).resolve().parent


@dataclasses.dataclass(frozen=True)
class DriverConfig:
    e2e_app: pathlib.Path
    browser_app: pathlib.Path
    expected_browser_executable: pathlib.Path
    target_id: str
    bundle_identifier: str
    mode: str
    expected_mechanism: str
    session_nonce: str
    timeout: float = 30.0
    route_count: int = 1
    profile_strategy: Optional[str] = None
    profile_relative_root: Optional[str] = None
    create_profile: bool = False
    derive_profile_target: bool = False
    request_nonce: str = dataclasses.field(
        default_factory=lambda: secrets.token_hex(16)
    )
    capability: str = "normal"
    state: str = "cold"
    e2e_app_identity: str = "0" * 64
    browser_app_identity: str = "0" * 64
    sequence_requests: tuple = ()


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


@dataclasses.dataclass(frozen=True)
class LaunchProvenance:
    outcome: str
    mechanism: str
    process_identifier: Optional[int]


def _ignore(*args):
    return None


def _mkfifo_at(descriptor, name, mode):
    if os.mkfifo in os.supports_dir_fd:
        os.mkfifo(name, mode, dir_fd=descriptor)
        return
    library = ctypes.CDLL(None, use_errno=True)
    library.mkfifoat.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    library.mkfifoat.restype = ctypes.c_int
    encoded = os.fsencode(name)
    ctypes.set_errno(0)
    if library.mkfifoat(descriptor, encoded, mode) != 0:
        error_number = ctypes.get_errno()
        raise OSError(error_number, os.strerror(error_number), name)


def _exact_process_identity(process, executable):
    expected = pathlib.Path(executable)
    if sys.platform != "darwin":
        return process.args == [os.fspath(expected)] and process.poll() is None
    try:
        identity = _darwin_process_identity(process.pid)
    except _ProcessDisappeared:
        return False
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


def _raise_identity_query_failure(pid):
    error_number = ctypes.get_errno()
    if error_number == errno.ESRCH:
        raise _ProcessDisappeared
    if error_number == 0:
        try:
            os.kill(pid, 0)
        except ProcessLookupError as error:
            raise _ProcessDisappeared from error
        except PermissionError:
            pass
        except OSError as error:
            if error.errno == errno.ESRCH:
                raise _ProcessDisappeared from error
            raise _IdentityInspectionError from error
    raise _IdentityInspectionError


def _darwin_process_identity(pid, library=None):
    try:
        library = library or _load_libproc()
        path_buffer = ctypes.create_string_buffer(4_096)
        ctypes.set_errno(0)
        if library.proc_pidpath(pid, path_buffer, len(path_buffer)) <= 0:
            _raise_identity_query_failure(pid)
        info = _ProcBSDInfo()
        ctypes.set_errno(0)
        if library.proc_pidinfo(
            pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info)
        ) != ctypes.sizeof(info):
            _raise_identity_query_failure(pid)
        return ProcessIdentity(
            pid=pid,
            parent_pid=int(info.pbi_ppid),
            start_seconds=int(info.pbi_start_tvsec),
            start_microseconds=int(info.pbi_start_tvusec),
            executable=pathlib.Path(os.fsdecode(path_buffer.value)),
        )
    except (_ProcessDisappeared, _IdentityInspectionError):
        raise
    except (OSError, ValueError, TypeError) as error:
        raise _IdentityInspectionError from error


def _snapshot_exact_browser_processes(executable, library=None):
    expected = pathlib.Path(executable)
    if sys.platform != "darwin":
        raise _IdentityInspectionError
    try:
        library = library or _load_libproc()
        proc_uid_only = 4
        required_bytes = library.proc_listpids(proc_uid_only, os.getuid(), None, 0)
        if required_bytes <= 0:
            raise _IdentityInspectionError
        count = required_bytes // ctypes.sizeof(ctypes.c_int) + 128
        pids = (ctypes.c_int * count)()
        used_bytes = library.proc_listpids(
            proc_uid_only, os.getuid(), pids, ctypes.sizeof(pids)
        )
        if (
            used_bytes <= 0
            or used_bytes >= ctypes.sizeof(pids)
            or used_bytes % ctypes.sizeof(ctypes.c_int) != 0
        ):
            raise _IdentityInspectionError
        identities = set()
        for pid in pids[: used_bytes // ctypes.sizeof(ctypes.c_int)]:
            if pid <= 0:
                continue
            try:
                identity = _darwin_process_identity(pid, library)
            except _ProcessDisappeared:
                continue
            if identity.executable == expected:
                identities.add(identity)
        return frozenset(identities)
    except _IdentityInspectionError:
        raise
    except (OSError, ValueError, TypeError) as error:
        raise _IdentityInspectionError from error


def _target_generation_is_live(identity, executable):
    expected = pathlib.Path(executable)
    try:
        current = _darwin_process_identity(identity.pid)
    except _ProcessDisappeared:
        return False
    return (
        current.executable == expected
        and current.generation_key == identity.generation_key
    )


def _terminate_exact_browser_process(identity, executable, cleanup_deadline):
    expected = pathlib.Path(executable)
    if not _target_generation_is_live(identity, expected):
        return True
    if time.monotonic() >= cleanup_deadline:
        return False
    try:
        os.kill(identity.pid, signal.SIGTERM)
    except ProcessLookupError:
        return True
    while time.monotonic() < cleanup_deadline:
        if not _target_generation_is_live(identity, expected):
            return True
        remaining = cleanup_deadline - time.monotonic()
        if remaining > 0:
            time.sleep(min(0.02, remaining))
    return not _target_generation_is_live(identity, expected)


@dataclasses.dataclass(frozen=True)
class _DirectoryIdentity:
    device: int
    inode: int
    owner: int
    mode: int

    @classmethod
    def from_stat(cls, metadata):
        return cls(
            device=metadata.st_dev,
            inode=metadata.st_ino,
            owner=metadata.st_uid,
            mode=stat.S_IMODE(metadata.st_mode),
        )


@dataclasses.dataclass(frozen=True)
class _EntryIdentity:
    device: int
    inode: int
    owner: int
    mode: int
    size: int
    modified_ns: int
    changed_ns: int

    @classmethod
    def from_stat(cls, metadata):
        return cls(
            device=metadata.st_dev,
            inode=metadata.st_ino,
            owner=metadata.st_uid,
            mode=metadata.st_mode,
            size=metadata.st_size,
            modified_ns=metadata.st_mtime_ns,
            changed_ns=metadata.st_ctime_ns,
        )


@dataclasses.dataclass(frozen=True)
class _DeletionIdentity:
    device: int
    inode: int
    owner: int
    mode: int
    size: int

    @classmethod
    def from_stat(cls, metadata):
        return cls(
            device=metadata.st_dev,
            inode=metadata.st_ino,
            owner=metadata.st_uid,
            mode=metadata.st_mode,
            size=metadata.st_size,
        )


class _PinnedTaskRoot:
    def __init__(
        self,
        path,
        descriptor,
        identity,
        parent_descriptor,
        parent_identity,
    ):
        self.path = pathlib.Path(path)
        self.descriptor = descriptor
        self.identity = identity
        self.parent_descriptor = parent_descriptor
        self.parent_identity = parent_identity
        self._closed = False

    def _descriptor_matches(self):
        if self._closed:
            return False
        metadata = os.fstat(self.descriptor)
        return (
            stat.S_ISDIR(metadata.st_mode)
            and _DirectoryIdentity.from_stat(metadata) == self.identity
        )

    def require_current(self):
        try:
            metadata = self.path.lstat()
            if (
                not self._descriptor_matches()
                or _DirectoryIdentity.from_stat(os.fstat(self.parent_descriptor))
                != self.parent_identity
                or self.path.parent != pathlib.Path("/private/tmp")
                or not self.path.name.startswith("pickvia-e2e-")
                or not stat.S_ISDIR(metadata.st_mode)
                or stat.S_ISLNK(metadata.st_mode)
                or _DirectoryIdentity.from_stat(metadata) != self.identity
                or pathlib.Path(os.path.realpath(self.path)) != self.path
            ):
                raise OSError("task root identity changed")
        except (FileNotFoundError, NotADirectoryError) as error:
            raise OSError("task root identity changed") from error
        return self.path

    def child_path(self, name):
        if not isinstance(name, str) or not name or "/" in name or name in {".", ".."}:
            raise ValueError("invalid task-root child")
        return self.require_current() / name

    def create_fifo(self, name):
        self.require_current()
        _mkfifo_at(self.descriptor, name, 0o600)
        os.chmod(name, 0o600, dir_fd=self.descriptor, follow_symlinks=False)

    def open_fifo(self, name):
        self.require_current()
        if not isinstance(name, str) or not name or "/" in name or name in {".", ".."}:
            raise ValueError("invalid task-root child")
        inspected = os.stat(name, dir_fd=self.descriptor, follow_symlinks=False)
        if not self._is_owned_fifo(inspected):
            raise OSError("task-root FIFO is invalid")
        descriptor = os.open(
            name,
            os.O_RDWR
            | os.O_NONBLOCK
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=self.descriptor,
        )
        try:
            opened = os.fstat(descriptor)
            if (
                not self._is_owned_fifo(opened)
                or opened.st_dev != inspected.st_dev
                or opened.st_ino != inspected.st_ino
            ):
                raise OSError("task-root FIFO identity changed")
            return descriptor
        except BaseException:
            os.close(descriptor)
            raise

    def write_regular_file(self, name, contents):
        path = self.child_path(name)
        if (
            not isinstance(contents, bytes)
            or len(contents) > MAXIMUM_PROTOCOL_LINE_BYTES
        ):
            raise ValueError("invalid task-root file contents")
        descriptor = os.open(
            name,
            os.O_WRONLY
            | os.O_CREAT
            | os.O_EXCL
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0),
            0o600,
            dir_fd=self.descriptor,
        )
        try:
            _write_all(descriptor, contents)
            os.fchmod(descriptor, 0o600)
            os.fsync(descriptor)
            opened = os.fstat(descriptor)
            named = os.stat(name, dir_fd=self.descriptor, follow_symlinks=False)
            if (
                not stat.S_ISREG(opened.st_mode)
                or _EntryIdentity.from_stat(opened) != _EntryIdentity.from_stat(named)
                or opened.st_uid != os.getuid()
                or opened.st_dev != self.identity.device
                or stat.S_IMODE(opened.st_mode) != 0o600
                or opened.st_nlink != 1
                or opened.st_size != len(contents)
                or path.parent != self.require_current()
            ):
                raise OSError("task-root file identity changed")
        finally:
            os.close(descriptor)

    def _is_owned_fifo(self, metadata):
        return (
            stat.S_ISFIFO(metadata.st_mode)
            and metadata.st_uid == os.getuid()
            and metadata.st_dev == self.identity.device
            and stat.S_IMODE(metadata.st_mode) == 0o600
            and metadata.st_nlink == 1
        )

    def audit_regular_files(self, forbidden):
        try:
            self.require_current()
            budget = _AuditBudget(time.monotonic() + MAXIMUM_AUDIT_SECONDS)
            previous = None
            for _ in range(MAXIMUM_AUDIT_PASSES):
                current = _audit_regular_files_at(
                    self.descriptor,
                    forbidden,
                    self.identity.device,
                    budget,
                    _AuditPass(),
                )
                if current is None or current is False:
                    return False
                if previous == current:
                    return True
                previous = current
            return False
        except OSError:
            return False

    def remove(self):
        contents_removed = False
        path_is_current = False
        try:
            path_is_current = self.require_current() == self.path
        except OSError:
            path_is_current = False
        try:
            contents_removed = _remove_directory_contents_at(
                self.descriptor, self.identity.device
            )
            if not contents_removed or not path_is_current:
                return False
            self.require_current()
            return _finalize_empty_task_root_exclusively(self)
        except (OSError, subprocess.SubprocessError):
            return False
        finally:
            self.close()

    def close(self):
        if self._closed:
            return
        self._closed = True
        try:
            os.close(self.descriptor)
        except OSError:
            pass
        try:
            os.close(self.parent_descriptor)
        except OSError:
            pass


class _TaskRootOwner:
    def __init__(self):
        self.root = None

    def _register_without_signal_test_hook(self, root):
        if self.root is not None:
            raise RuntimeError("task root already registered")
        self.root = root

    def register(self, root):
        self._register_without_signal_test_hook(root)

    def cleanup(self):
        if self.root is None:
            return True
        root = self.root
        try:
            removed = root.remove()
            if removed and self.root is root:
                self.root = None
            return removed
        finally:
            root.close()


class _PinnedCleanupHelper:
    def __init__(
        self,
        path,
        directory_descriptor,
        executable_descriptor,
        directory_identity,
        executable_identity,
        executable_digest,
    ):
        self.path = pathlib.Path(path)
        self.directory_descriptor = directory_descriptor
        self.executable_descriptor = executable_descriptor
        self.directory_identity = directory_identity
        self.executable_identity = executable_identity
        self.executable_digest = executable_digest

    def validate(self):
        try:
            directory_metadata = os.fstat(self.directory_descriptor)
            executable_metadata = os.fstat(self.executable_descriptor)
            named_metadata = os.stat(
                self.path.name,
                dir_fd=self.directory_descriptor,
                follow_symlinks=False,
            )
            digest, stable_metadata = _hash_pinned_regular_file(
                self.executable_descriptor, MAXIMUM_CLEANUP_HELPER_BYTES
            )
            return (
                stat.S_ISDIR(directory_metadata.st_mode)
                and _DirectoryIdentity.from_stat(directory_metadata)
                == self.directory_identity
                and _DirectoryIdentity.from_stat(self.path.parent.lstat())
                == self.directory_identity
                and pathlib.Path(os.path.realpath(self.path.parent)) == self.path.parent
                and stat.S_ISREG(executable_metadata.st_mode)
                and stat.S_IMODE(executable_metadata.st_mode) == 0o700
                and executable_metadata.st_nlink == 1
                and executable_metadata.st_uid == os.getuid()
                and _DeletionIdentity.from_stat(executable_metadata)
                == self.executable_identity
                and _DeletionIdentity.from_stat(stable_metadata)
                == self.executable_identity
                and _DeletionIdentity.from_stat(named_metadata)
                == self.executable_identity
                and digest == self.executable_digest
            )
        except OSError:
            return False

    def close(self):
        for descriptor in (self.executable_descriptor, self.directory_descriptor):
            try:
                os.close(descriptor)
            except OSError:
                pass


def _exclusive_cleanup_environment(cache_path):
    return {
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "LANG": "en_US.UTF-8",
        "LC_CTYPE": "UTF-8",
        "TMPDIR": os.fspath(cache_path),
        "CFFIXED_USER_HOME": os.fspath(cache_path),
        "PYTHONDONTWRITEBYTECODE": "1",
    }


def _exclusive_cleanup_identity_arguments(metadata):
    return [
        str(metadata.st_dev),
        str(metadata.st_ino),
        str(metadata.st_uid),
        str(metadata.st_mode),
    ]


def _hash_pinned_regular_file(descriptor, maximum_bytes):
    before = os.fstat(descriptor)
    if (
        not stat.S_ISREG(before.st_mode)
        or before.st_size < 1
        or before.st_size > maximum_bytes
    ):
        raise OSError("pinned regular file is invalid")
    os.lseek(descriptor, 0, os.SEEK_SET)
    digest = hashlib.sha256()
    bytes_read = 0
    while bytes_read < before.st_size:
        chunk = os.read(descriptor, min(65_536, before.st_size - bytes_read))
        if not chunk:
            break
        bytes_read += len(chunk)
        digest.update(chunk)
    after = os.fstat(descriptor)
    os.lseek(descriptor, 0, os.SEEK_SET)
    if bytes_read != before.st_size or _EntryIdentity.from_stat(
        before
    ) != _EntryIdentity.from_stat(after):
        raise OSError("pinned regular file changed during hash")
    return digest.hexdigest(), after


def _stable_source_digest(source, maximum_bytes):
    descriptor = os.open(
        source,
        os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0),
    )
    try:
        before = os.fstat(descriptor)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_size < 1
            or before.st_size > maximum_bytes
        ):
            raise OSError("exclusive cleanup source is invalid")
        contents = bytearray()
        while len(contents) < before.st_size:
            chunk = os.read(descriptor, min(65_536, before.st_size - len(contents)))
            if not chunk:
                break
            contents.extend(chunk)
        after = os.fstat(descriptor)
        named = source.lstat()
        if (
            len(contents) != before.st_size
            or _EntryIdentity.from_stat(before) != _EntryIdentity.from_stat(after)
            or _EntryIdentity.from_stat(after) != _EntryIdentity.from_stat(named)
        ):
            raise OSError("exclusive cleanup source changed during read")
        return hashlib.sha256(contents).hexdigest()
    finally:
        os.close(descriptor)


def _stable_cleanup_source_digest():
    return _stable_source_digest(
        _SCRIPT_DIR / "exclusive_cleanup.c", MAXIMUM_CLEANUP_SOURCE_BYTES
    )


def _stable_browser_code_identity_source_digest():
    return _stable_source_digest(
        _SCRIPT_DIR / "browser_code_identity.swift",
        MAXIMUM_BROWSER_CODE_IDENTITY_SOURCE_BYTES,
    )


def _cleanup_cache_repository():
    return _SCRIPT_DIR.parents[1]


def _open_owned_cache_directory():
    repository = pathlib.Path(_cleanup_cache_repository())
    repository_descriptor = os.open(
        repository,
        os.O_RDONLY
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_CLOEXEC", 0),
    )
    build_descriptor = -1
    cache_descriptor = -1
    try:
        repository_metadata = os.fstat(repository_descriptor)
        if not stat.S_ISDIR(repository_metadata.st_mode):
            raise OSError("repository cache parent is invalid")
        try:
            os.mkdir(".build-e2e", mode=0o700, dir_fd=repository_descriptor)
        except FileExistsError:
            pass
        build_descriptor = os.open(
            ".build-e2e",
            os.O_RDONLY
            | getattr(os, "O_DIRECTORY", 0)
            | getattr(os, "O_NOFOLLOW", 0)
            | getattr(os, "O_CLOEXEC", 0),
            dir_fd=repository_descriptor,
        )
        build_metadata = os.fstat(build_descriptor)
        if (
            not stat.S_ISDIR(build_metadata.st_mode)
            or build_metadata.st_uid != os.getuid()
            or build_metadata.st_dev != repository_metadata.st_dev
            or stat.S_IMODE(build_metadata.st_mode) & 0o022
        ):
            raise OSError("build cache is not owned and private")
        try:
            os.mkdir("browser-e2e-tools", mode=0o700, dir_fd=build_descriptor)
        except FileExistsError:
            pass
        cache_descriptor = os.open(
            "browser-e2e-tools",
            os.O_RDONLY
            | getattr(os, "O_DIRECTORY", 0)
            | getattr(os, "O_NOFOLLOW", 0)
            | getattr(os, "O_CLOEXEC", 0),
            dir_fd=build_descriptor,
        )
        cache_metadata = os.fstat(cache_descriptor)
        if (
            not stat.S_ISDIR(cache_metadata.st_mode)
            or cache_metadata.st_uid != os.getuid()
            or cache_metadata.st_dev != repository_metadata.st_dev
            or stat.S_IMODE(cache_metadata.st_mode) != 0o700
        ):
            raise OSError("exclusive cleanup cache is invalid")
        descriptor = cache_descriptor
        cache_descriptor = -1
        return repository / ".build-e2e" / "browser-e2e-tools", descriptor
    finally:
        for descriptor in (
            cache_descriptor,
            build_descriptor,
            repository_descriptor,
        ):
            if descriptor >= 0:
                os.close(descriptor)


def _read_cleanup_record(directory_descriptor, source_digest):
    descriptor = os.open(
        "record.json",
        os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0),
        dir_fd=directory_descriptor,
    )
    try:
        metadata = os.fstat(descriptor)
        named = os.stat(
            "record.json", dir_fd=directory_descriptor, follow_symlinks=False
        )
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_size < 1
            or metadata.st_size > MAXIMUM_CLEANUP_RECORD_BYTES
            or metadata.st_uid != os.getuid()
            or metadata.st_nlink != 1
            or _DeletionIdentity.from_stat(metadata)
            != _DeletionIdentity.from_stat(named)
        ):
            raise OSError("cleanup cache record is invalid")
        payload = bytearray()
        while len(payload) < metadata.st_size:
            chunk = os.read(descriptor, metadata.st_size - len(payload))
            if not chunk:
                break
            payload.extend(chunk)
        after = os.fstat(descriptor)
        if len(payload) != metadata.st_size or _EntryIdentity.from_stat(
            metadata
        ) != _EntryIdentity.from_stat(after):
            raise OSError("cleanup cache record changed during read")
        record = json.loads(payload)
        expected_keys = {
            "schema",
            "source_sha256",
            "executable_sha256",
            "device",
            "inode",
            "owner",
            "mode",
            "size",
        }
        if (
            not isinstance(record, dict)
            or set(record) != expected_keys
            or record["schema"] != 1
            or record["source_sha256"] != source_digest
            or not isinstance(record["executable_sha256"], str)
            or len(record["executable_sha256"]) != 64
            or any(
                not isinstance(record[key], int)
                for key in ("device", "inode", "owner", "mode", "size")
            )
        ):
            raise OSError("cleanup cache record contents are invalid")
        return record
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise OSError("cleanup cache record could not be decoded") from error
    finally:
        os.close(descriptor)


def _pin_cleanup_helper(cache_path, cache_descriptor, record_name, source_digest):
    record_descriptor = os.open(
        record_name,
        os.O_RDONLY
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_CLOEXEC", 0),
        dir_fd=cache_descriptor,
    )
    executable_descriptor = -1
    try:
        cache_metadata = os.fstat(cache_descriptor)
        record_metadata = os.fstat(record_descriptor)
        named_record = os.stat(
            record_name, dir_fd=cache_descriptor, follow_symlinks=False
        )
        if (
            not stat.S_ISDIR(cache_metadata.st_mode)
            or cache_metadata.st_uid != os.getuid()
            or stat.S_IMODE(cache_metadata.st_mode) != 0o700
            or not stat.S_ISDIR(record_metadata.st_mode)
            or record_metadata.st_uid != os.getuid()
            or stat.S_IMODE(record_metadata.st_mode) != 0o700
            or _DirectoryIdentity.from_stat(record_metadata)
            != _DirectoryIdentity.from_stat(named_record)
        ):
            raise OSError("cached cleanup record directory is invalid")
        record = _read_cleanup_record(record_descriptor, source_digest)
        executable_descriptor = os.open(
            "helper",
            os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0),
            dir_fd=record_descriptor,
        )
        executable_metadata = os.fstat(executable_descriptor)
        named_executable = os.stat(
            "helper", dir_fd=record_descriptor, follow_symlinks=False
        )
        expected_identity = _DeletionIdentity(
            device=record["device"],
            inode=record["inode"],
            owner=record["owner"],
            mode=record["mode"],
            size=record["size"],
        )
        digest, stable_metadata = _hash_pinned_regular_file(
            executable_descriptor, MAXIMUM_CLEANUP_HELPER_BYTES
        )
        if (
            executable_metadata.st_uid != os.getuid()
            or executable_metadata.st_dev != record_metadata.st_dev
            or stat.S_IMODE(executable_metadata.st_mode) != 0o700
            or executable_metadata.st_nlink != 1
            or _DeletionIdentity.from_stat(executable_metadata) != expected_identity
            or _DeletionIdentity.from_stat(stable_metadata) != expected_identity
            or _DeletionIdentity.from_stat(named_executable) != expected_identity
            or digest != record["executable_sha256"]
        ):
            raise OSError("cached cleanup helper provenance is invalid")
        pinned = _PinnedCleanupHelper(
            cache_path / record_name / "helper",
            record_descriptor,
            executable_descriptor,
            _DirectoryIdentity.from_stat(record_metadata),
            expected_identity,
            record["executable_sha256"],
        )
        record_descriptor = -1
        executable_descriptor = -1
        if not pinned.validate():
            pinned.close()
            raise OSError("cached cleanup helper changed while pinning")
        return pinned
    finally:
        if executable_descriptor >= 0:
            os.close(executable_descriptor)
        if record_descriptor >= 0:
            os.close(record_descriptor)
        if cache_descriptor >= 0:
            os.close(cache_descriptor)


def _rename_at_exclusive(descriptor, source, destination):
    library = ctypes.CDLL(None, use_errno=True)
    library.renameatx_np.argtypes = [
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_uint,
    ]
    library.renameatx_np.restype = ctypes.c_int
    ctypes.set_errno(0)
    if (
        library.renameatx_np(
            descriptor,
            os.fsencode(source),
            descriptor,
            os.fsencode(destination),
            0x00000004,
        )
        != 0
    ):
        error_number = ctypes.get_errno()
        raise OSError(error_number, os.strerror(error_number), destination)


def _write_all(descriptor, contents):
    offset = 0
    while offset < len(contents):
        written = os.write(descriptor, contents[offset:])
        if written <= 0:
            raise OSError("short cleanup cache record write")
        offset += written


def _discard_owned_staging(
    cache_descriptor, staging_name, staging_descriptor, staging_identity, entries
):
    try:
        named = os.stat(staging_name, dir_fd=cache_descriptor, follow_symlinks=False)
        if (
            _DirectoryIdentity.from_stat(os.fstat(staging_descriptor))
            != staging_identity
            or _DirectoryIdentity.from_stat(named) != staging_identity
            or set(os.listdir(staging_descriptor)) != set(entries)
        ):
            return False
        for name, expected in entries.items():
            current = os.stat(name, dir_fd=staging_descriptor, follow_symlinks=False)
            if _DeletionIdentity.from_stat(current) != expected:
                return False
        for name in entries:
            os.unlink(name, dir_fd=staging_descriptor)
        if os.listdir(staging_descriptor):
            return False
        current = os.stat(staging_name, dir_fd=cache_descriptor, follow_symlinks=False)
        if _DirectoryIdentity.from_stat(current) != staging_identity:
            return False
        os.rmdir(staging_name, dir_fd=cache_descriptor)
        return True
    except OSError:
        return False


def _publish_cached_helper(
    cache_path,
    cache_descriptor,
    source,
    source_digest,
    record_name,
    staging_prefix,
    compiler_options,
    linker_options,
    compile_timeout,
    maximum_source_bytes,
):
    staging_name = f".{staging_prefix}-staging-{secrets.token_hex(16)}"
    os.mkdir(staging_name, mode=0o700, dir_fd=cache_descriptor)
    staging_descriptor = os.open(
        staging_name,
        os.O_RDONLY
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_CLOEXEC", 0),
        dir_fd=cache_descriptor,
    )
    staging_identity = _DirectoryIdentity.from_stat(os.fstat(staging_descriptor))
    entries = {}
    try:
        completed = subprocess.run(
            [
                "/usr/bin/xcrun",
                *compiler_options,
                os.fspath(source),
                *linker_options,
                "-o",
                os.fspath(cache_path / staging_name / "helper"),
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env=_exclusive_cleanup_environment(cache_path / staging_name),
            close_fds=True,
            timeout=compile_timeout,
            check=False,
        )
        if (
            completed.returncode != 0
            or _stable_source_digest(source, maximum_source_bytes) != source_digest
        ):
            raise OSError("cached helper compilation failed")
        helper_descriptor = os.open(
            "helper",
            os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0),
            dir_fd=staging_descriptor,
        )
        try:
            os.fchmod(helper_descriptor, 0o700)
            os.fsync(helper_descriptor)
            executable_digest, helper_metadata = _hash_pinned_regular_file(
                helper_descriptor, MAXIMUM_CLEANUP_HELPER_BYTES
            )
            named_helper = os.stat(
                "helper", dir_fd=staging_descriptor, follow_symlinks=False
            )
            helper_identity = _DeletionIdentity.from_stat(helper_metadata)
            if (
                helper_metadata.st_nlink != 1
                or helper_metadata.st_uid != os.getuid()
                or helper_identity != _DeletionIdentity.from_stat(named_helper)
            ):
                raise OSError("compiled cached helper identity is invalid")
            entries["helper"] = helper_identity
        finally:
            os.close(helper_descriptor)
        record = {
            "schema": 1,
            "source_sha256": source_digest,
            "executable_sha256": executable_digest,
            "device": helper_metadata.st_dev,
            "inode": helper_metadata.st_ino,
            "owner": helper_metadata.st_uid,
            "mode": helper_metadata.st_mode,
            "size": helper_metadata.st_size,
        }
        record_contents = json.dumps(
            record, sort_keys=True, separators=(",", ":")
        ).encode("ascii")
        record_descriptor = os.open(
            "record.json",
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0),
            0o600,
            dir_fd=staging_descriptor,
        )
        try:
            _write_all(record_descriptor, record_contents)
            os.fsync(record_descriptor)
            entries["record.json"] = _DeletionIdentity.from_stat(
                os.fstat(record_descriptor)
            )
        finally:
            os.close(record_descriptor)
        os.fsync(staging_descriptor)
        try:
            _rename_at_exclusive(cache_descriptor, staging_name, record_name)
            os.fsync(cache_descriptor)
            return
        except OSError as error:
            if error.errno != errno.EEXIST:
                raise
            if not _discard_owned_staging(
                cache_descriptor,
                staging_name,
                staging_descriptor,
                staging_identity,
                entries,
            ):
                raise OSError("concurrent helper staging could not be preserved")
    finally:
        os.close(staging_descriptor)


def _publish_cleanup_helper(cache_path, cache_descriptor, source_digest, record_name):
    _publish_cached_helper(
        cache_path,
        cache_descriptor,
        _SCRIPT_DIR / "exclusive_cleanup.c",
        source_digest,
        record_name,
        "exclusive-cleanup",
        ("clang", "-std=c17", "-Wall", "-Wextra", "-Werror"),
        (),
        EXCLUSIVE_CLEANUP_COMPILE_TIMEOUT_SECONDS,
        MAXIMUM_CLEANUP_SOURCE_BYTES,
    )


def _publish_browser_code_identity_helper(
    cache_path, cache_descriptor, source_digest, record_name
):
    _publish_cached_helper(
        cache_path,
        cache_descriptor,
        _SCRIPT_DIR / "browser_code_identity.swift",
        source_digest,
        record_name,
        "browser-code-identity",
        ("swiftc", "-swift-version", "6", "-warnings-as-errors"),
        ("-framework", "Security"),
        BROWSER_CODE_IDENTITY_COMPILE_TIMEOUT_SECONDS,
        MAXIMUM_BROWSER_CODE_IDENTITY_SOURCE_BYTES,
    )


def _pin_exclusive_cleanup_helper():
    source_digest = _stable_cleanup_source_digest()
    cache_path, cache_descriptor = _open_owned_cache_directory()
    record_name = f"exclusive-cleanup-record-{source_digest}"
    try:
        try:
            os.stat(record_name, dir_fd=cache_descriptor, follow_symlinks=False)
        except FileNotFoundError:
            _publish_cleanup_helper(
                cache_path, cache_descriptor, source_digest, record_name
            )
        descriptor = cache_descriptor
        cache_descriptor = -1
        return _pin_cleanup_helper(cache_path, descriptor, record_name, source_digest)
    finally:
        if cache_descriptor >= 0:
            os.close(cache_descriptor)


def _pin_browser_code_identity_helper():
    source_digest = _stable_browser_code_identity_source_digest()
    cache_path, cache_descriptor = _open_owned_cache_directory()
    record_name = f"browser-code-identity-record-{source_digest}"
    try:
        try:
            os.stat(record_name, dir_fd=cache_descriptor, follow_symlinks=False)
        except FileNotFoundError:
            _publish_browser_code_identity_helper(
                cache_path, cache_descriptor, source_digest, record_name
            )
        descriptor = cache_descriptor
        cache_descriptor = -1
        return _pin_cleanup_helper(cache_path, descriptor, record_name, source_digest)
    finally:
        if cache_descriptor >= 0:
            os.close(cache_descriptor)


def _empty_task_root_fingerprint(task_root, budget):
    task_root.require_current()
    budget.check_deadline()
    before = _EntryIdentity.from_stat(os.fstat(task_root.descriptor))
    entries = _snapshot_directory_at(
        task_root.descriptor,
        task_root.identity.device,
        budget,
        _AuditPass(),
        count_toward_tree=True,
    )
    after = _EntryIdentity.from_stat(os.fstat(task_root.descriptor))
    task_root.require_current()
    budget.check_deadline()
    if entries or before != after:
        return None
    return before


def _stable_empty_task_root(task_root):
    budget = _AuditBudget(time.monotonic() + MAXIMUM_AUDIT_SECONDS)
    first = _empty_task_root_fingerprint(task_root, budget)
    if first is None:
        return False
    second = _empty_task_root_fingerprint(task_root, budget)
    return second is not None and second == first


def _name_is_absent_at(descriptor, name):
    try:
        os.stat(name, dir_fd=descriptor, follow_symlinks=False)
        return False
    except FileNotFoundError:
        return True
    except OSError:
        return False


def _invoke_exclusive_cleanup_helper(task_root, helper):
    root_metadata = os.fstat(task_root.descriptor)
    parent_metadata = os.fstat(task_root.parent_descriptor)
    quarantine = f".pickvia-finalize-{secrets.token_hex(16)}"
    arguments = [
        os.fspath(helper.path),
        str(task_root.parent_descriptor),
        str(task_root.descriptor),
        task_root.path.name,
        quarantine,
        *_exclusive_cleanup_identity_arguments(root_metadata),
        *_exclusive_cleanup_identity_arguments(parent_metadata),
    ]
    if not helper.validate():
        return False
    completed = subprocess.run(
        arguments,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        env=_exclusive_cleanup_environment(helper.path.parent),
        close_fds=True,
        pass_fds=(task_root.parent_descriptor, task_root.descriptor),
        timeout=EXCLUSIVE_CLEANUP_TIMEOUT_SECONDS,
        check=False,
    )
    if completed.returncode != 0:
        return False
    try:
        current_root = os.fstat(task_root.descriptor)
        current_parent = os.fstat(task_root.parent_descriptor)
        return (
            _DirectoryIdentity.from_stat(current_root)
            == _DirectoryIdentity.from_stat(root_metadata)
            and _DirectoryIdentity.from_stat(current_parent)
            == _DirectoryIdentity.from_stat(parent_metadata)
            and _name_is_absent_at(task_root.parent_descriptor, task_root.path.name)
            and _name_is_absent_at(task_root.parent_descriptor, quarantine)
            and os.listdir(task_root.descriptor) == []
        )
    except OSError:
        return False


def _finalize_empty_task_root_exclusively(task_root):
    if not isinstance(task_root, _PinnedTaskRoot):
        return False
    helper = _pin_exclusive_cleanup_helper()
    try:
        if not _stable_empty_task_root(task_root):
            return False
        return _invoke_exclusive_cleanup_helper(task_root, helper)
    finally:
        helper.close()


def _invoke_browser_code_identity_helper(
    helper,
    process_identifier,
    expected_code_path,
    expected_executable,
    expected_bundle_identifier,
):
    if (
        not isinstance(process_identifier, int)
        or isinstance(process_identifier, bool)
        or process_identifier <= 0
        or not helper.validate()
    ):
        raise _IdentityError
    process = None
    selector = selectors.DefaultSelector()
    buffers = {"stdout": bytearray(), "stderr": bytearray()}
    try:
        process = subprocess.Popen(
            [
                os.fspath(helper.path),
                str(process_identifier),
                os.fspath(expected_code_path),
                os.fspath(expected_executable),
                expected_bundle_identifier,
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=_exclusive_cleanup_environment(helper.path.parent),
            close_fds=True,
        )
        for name, stream in (("stdout", process.stdout), ("stderr", process.stderr)):
            os.set_blocking(stream.fileno(), False)
            selector.register(stream.fileno(), selectors.EVENT_READ, name)
        deadline = time.monotonic() + BROWSER_CODE_IDENTITY_TIMEOUT_SECONDS
        while selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise _IdentityError
            for key, _ in selector.select(min(remaining, 0.05)):
                try:
                    chunk = os.read(
                        key.fd, MAXIMUM_BROWSER_CODE_IDENTITY_OUTPUT_BYTES + 1
                    )
                except BlockingIOError:
                    continue
                if not chunk:
                    selector.unregister(key.fd)
                    continue
                buffers[key.data].extend(chunk)
                if len(buffers[key.data]) > MAXIMUM_BROWSER_CODE_IDENTITY_OUTPUT_BYTES:
                    raise _IdentityError
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise _IdentityError
        process.wait(timeout=remaining)
        if (
            process.returncode != 0
            or bytes(buffers["stdout"]) != b"OK\n"
            or buffers["stderr"]
            or not helper.validate()
        ):
            raise _IdentityError
    except (OSError, subprocess.SubprocessError) as error:
        raise _IdentityError from error
    finally:
        selector.close()
        if process is not None:
            if process.poll() is None:
                process.kill()
            try:
                process.wait(timeout=1.0)
            except subprocess.TimeoutExpired:
                pass
            for stream in (process.stdout, process.stderr):
                if stream is not None:
                    stream.close()


def _validate_running_browser_code(
    process_identifier,
    expected_code_path,
    expected_executable,
    expected_bundle_identifier,
):
    helper = _pin_browser_code_identity_helper()
    try:
        _invoke_browser_code_identity_helper(
            helper,
            process_identifier,
            expected_code_path,
            expected_executable,
            expected_bundle_identifier,
        )
    finally:
        helper.close()


def _restore_quarantine(descriptor, quarantine, original):
    try:
        os.stat(original, dir_fd=descriptor, follow_symlinks=False)
        return False
    except FileNotFoundError:
        pass
    try:
        os.rename(
            quarantine,
            original,
            src_dir_fd=descriptor,
            dst_dir_fd=descriptor,
        )
        return True
    except OSError:
        return False


def _quarantine_entry(descriptor, name, expected):
    quarantine = f".pickvia-cleanup-{secrets.token_hex(16)}"
    try:
        os.stat(quarantine, dir_fd=descriptor, follow_symlinks=False)
        return None
    except FileNotFoundError:
        pass
    try:
        os.rename(
            name,
            quarantine,
            src_dir_fd=descriptor,
            dst_dir_fd=descriptor,
        )
        observed = os.stat(
            quarantine,
            dir_fd=descriptor,
            follow_symlinks=False,
        )
        if type(expected).from_stat(observed) != expected:
            _restore_quarantine(descriptor, quarantine, name)
            return None
        return quarantine
    except OSError:
        return None


def _remove_directory_contents_at(descriptor, root_device):
    success = True
    for name in os.listdir(descriptor):
        try:
            metadata = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
            expected = _DeletionIdentity.from_stat(metadata)
            if stat.S_ISDIR(metadata.st_mode):
                if metadata.st_dev != root_device:
                    success = False
                    continue
                child = os.open(
                    name,
                    os.O_RDONLY
                    | getattr(os, "O_DIRECTORY", 0)
                    | getattr(os, "O_NOFOLLOW", 0)
                    | getattr(os, "O_CLOEXEC", 0),
                    dir_fd=descriptor,
                )
                try:
                    opened = os.fstat(child)
                    if (
                        _DeletionIdentity.from_stat(opened) != expected
                        or opened.st_dev != root_device
                    ):
                        success = False
                        continue
                    quarantine = _quarantine_entry(
                        descriptor,
                        name,
                        _DirectoryIdentity.from_stat(metadata),
                    )
                    if quarantine is None:
                        success = False
                        continue
                    if not _remove_directory_contents_at(child, root_device):
                        success = False
                        continue
                finally:
                    os.close(child)
                current = os.stat(quarantine, dir_fd=descriptor, follow_symlinks=False)
                if (
                    current.st_dev != metadata.st_dev
                    or current.st_ino != metadata.st_ino
                ):
                    success = False
                    continue
                os.rmdir(quarantine, dir_fd=descriptor)
            else:
                quarantine = _quarantine_entry(descriptor, name, expected)
                if quarantine is None:
                    success = False
                    continue
                current = os.stat(quarantine, dir_fd=descriptor, follow_symlinks=False)
                if _DeletionIdentity.from_stat(current) != expected:
                    _restore_quarantine(descriptor, quarantine, name)
                    success = False
                    continue
                os.unlink(quarantine, dir_fd=descriptor)
        except OSError:
            success = False
    return success and not os.listdir(descriptor)


def _remove_task_root(root):
    if not isinstance(root, _PinnedTaskRoot):
        return False
    return root.remove()


def _close_fifo(descriptor):
    try:
        os.close(descriptor)
        return True
    except OSError:
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
    browser_process_snapshot: Callable[[pathlib.Path, str], frozenset] = (
        lambda executable, _phase: _snapshot_exact_browser_processes(executable)
    )
    browser_process_identity: Callable[[int], ProcessIdentity] = (
        lambda pid: _darwin_process_identity(pid)
    )
    browser_binding_checker: Callable[[pathlib.Path, pathlib.Path, str], None] = (
        lambda application,
        executable,
        bundle_identifier: _validate_signed_browser_binding(
            application, executable, bundle_identifier
        )
    )
    browser_running_code_checker: Callable[
        [int, pathlib.Path, pathlib.Path, str], None
    ] = (
        lambda pid,
        application,
        executable,
        bundle_identifier: _validate_running_browser_code(
            pid, application, executable, bundle_identifier
        )
    )
    browser_process_terminator: Callable[
        [ProcessIdentity, pathlib.Path, float], bool
    ] = _terminate_exact_browser_process
    quiescence_monotonic: Callable[[], float] = time.monotonic
    quiescence_sleep: Callable[[float], None] = time.sleep
    capture_observer: Callable[[str, str, bytes, bool], None] = _ignore
    task_root_remover: Callable[[_PinnedTaskRoot], bool] = _remove_task_root
    fifo_closer: Callable[[int], bool] = _close_fifo
    profile_creator: Callable[
        [str, pathlib.Path, pathlib.Path, str, pathlib.Path], None
    ] = lambda strategy, application, executable, bundle_identifier, root: (
        _create_synthetic_profile(
            strategy,
            application,
            executable,
            bundle_identifier,
            root,
        )
    )


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
    launch_provenance: str


class _DriverInterrupted(Exception):
    pass


class _ProtocolError(Exception):
    pass


class _ReadinessError(_ProtocolError):
    pass


class _HelperError(_ProtocolError):
    def __init__(
        self,
        token_received=False,
        status_line=b"",
        browser_identity=False,
        owned_browsers=(),
    ):
        super().__init__()
        self.token_received = token_received
        self.status_line = status_line
        self.browser_identity = browser_identity
        self.owned_browsers = frozenset(owned_browsers)


class _IdentityError(Exception):
    pass


class _IdentityInspectionError(_IdentityError):
    pass


class _ProcessDisappeared(Exception):
    pass


class _IdentityAmbiguous(Exception):
    def __init__(self, token_received=False, status_line=b""):
        super().__init__()
        self.token_received = token_received
        self.status_line = status_line


class _StateSequenceError(Exception):
    pass


def _run_three_state_controller(
    *, requests, route, snapshot, attest, terminate, monotonic, sleep
):
    def exactly_generation(values, expected):
        values = tuple(values)
        return len(values) == 1 and values[0].generation_key == expected.generation_key

    if (
        not isinstance(requests, tuple)
        or len(requests) != 3
        or len(set(requests)) != 3
        or any(_SESSION_PATTERN.fullmatch(request) is None for request in requests)
    ):
        raise _StateSequenceError
    try:
        if snapshot("baseline"):
            raise _StateSequenceError

        cold = route("cold", requests[0])
        cold_snapshot = frozenset(snapshot("cold"))
        if not exactly_generation(cold_snapshot, cold) or not attest(cold):
            raise _StateSequenceError

        running = route("running", requests[1])
        running_snapshot = frozenset(snapshot("running"))
        if (
            running.generation_key != cold.generation_key
            or not exactly_generation(running_snapshot, cold)
            or not attest(cold)
        ):
            raise _StateSequenceError

        if not attest(cold):
            raise _StateSequenceError
        if terminate(cold) is not True:
            raise _StateSequenceError
        absence_deadline = monotonic() + BROWSER_QUIESCENCE_SECONDS
        while True:
            if snapshot("reopen-absence"):
                raise _StateSequenceError
            now = monotonic()
            if now >= absence_deadline:
                break
            sleep(min(BROWSER_QUIESCENCE_POLL_SECONDS, absence_deadline - now))

        reopened = route("reopen", requests[2])
        reopened_snapshot = frozenset(snapshot("reopen"))
        if (
            reopened.generation_key == cold.generation_key
            or not exactly_generation(reopened_snapshot, reopened)
            or not attest(reopened)
        ):
            raise _StateSequenceError
        return cold, running, reopened
    except _StateSequenceError:
        raise
    except Exception as error:
        raise _StateSequenceError from error


class _StatusProtocolError(_ProtocolError):
    def __init__(
        self,
        token_received=False,
        status_line=b"",
        browser_identity=False,
        owned_browsers=(),
    ):
        super().__init__()
        self.token_received = token_received
        self.status_line = status_line
        self.browser_identity = browser_identity
        self.owned_browsers = frozenset(owned_browsers)


class _ReceiptProtocolError(_ProtocolError):
    def __init__(
        self,
        token_received=False,
        status_line=b"",
        browser_identity=False,
        owned_browsers=(),
    ):
        super().__init__()
        self.token_received = token_received
        self.status_line = status_line
        self.browser_identity = browser_identity
        self.owned_browsers = frozenset(owned_browsers)


class _ProvenanceProtocolError(_ProtocolError):
    def __init__(
        self,
        token_received=False,
        status_line=b"",
        browser_identity=False,
    ):
        super().__init__()
        self.token_received = token_received
        self.status_line = status_line
        self.browser_identity = browser_identity


class _DeadlineExpired(Exception):
    pass


class _ProofTimeout(Exception):
    def __init__(
        self,
        token_received,
        status_line,
        browser_identity,
        owned_browsers,
        launch_provenance="none",
    ):
        super().__init__()
        self.token_received = token_received
        self.status_line = status_line
        self.browser_identity = browser_identity
        self.owned_browsers = frozenset(owned_browsers)
        self.launch_provenance = launch_provenance


class _ReceiptTimeout(_ProofTimeout):
    pass


class _BrowserIdentityTimeout(_ProofTimeout):
    pass


class _HelperExitTimeout(_ProofTimeout):
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
        self._stopped_pids = set()

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
        descriptor = stream.fileno()

        def drain():
            try:
                while True:
                    chunk = os.read(descriptor, 4_096)
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

    def stop(self, process):
        if process.poll() is not None:
            return True
        try:
            os.kill(process.pid, signal.SIGSTOP)
            self._stopped_pids.add(process.pid)
            return True
        except (OSError, ProcessLookupError):
            return False

    def close(self):
        if self._closed:
            return True
        self._closed = True
        cleanup_ok = True
        for child in reversed(self._children):
            process = child.process
            try:
                if process.poll() is None:
                    try:
                        process.terminate()
                        if process.pid in self._stopped_pids:
                            os.kill(process.pid, signal.SIGCONT)
                        process.wait(timeout=0.5)
                    except (ProcessLookupError, subprocess.TimeoutExpired):
                        cleanup_ok = False
                        if process.poll() is None:
                            try:
                                process.kill()
                            except ProcessLookupError:
                                pass
                            try:
                                process.wait(timeout=0.5)
                            except subprocess.TimeoutExpired:
                                cleanup_ok = False
                if process.poll() is None:
                    cleanup_ok = False
                if child.manual_stdout:
                    self._drain_manual_stream(process.stdout, child.captures["stdout"])
                for thread in child.threads:
                    thread.join(timeout=0.5)
                    if thread.is_alive():
                        cleanup_ok = False
            finally:
                for stream in (process.stdin, process.stdout, process.stderr):
                    if stream is not None and not stream.closed:
                        try:
                            stream.close()
                        except OSError:
                            cleanup_ok = False
                for thread in child.threads:
                    thread.join(timeout=0.1)
                    if thread.is_alive():
                        cleanup_ok = False
                for channel, capture in child.captures.items():
                    contents, overflow = capture.snapshot()
                    try:
                        self._dependencies.capture_observer(
                            child.kind, channel, contents, overflow
                        )
                    except Exception:
                        cleanup_ok = False
                try:
                    self._dependencies.termination_observer(child.kind, process.pid)
                except Exception:
                    cleanup_ok = False
        return cleanup_ok

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
        "schemaVersion": 1,
        "request": "invalid",
        "bundleIdentifier": "invalid",
        "targetID": "invalid",
        "capability": "invalid",
        "state": "invalid",
        "mode": "invalid",
        "mechanism": "invalid",
        "e2eAppIdentity": "invalid",
        "browserAppIdentity": "invalid",
        "outcome": "driver-error",
        "token_received": False,
        "exact_process_identity": False,
        "exact_browser_process_identity": False,
        "launch_provenance": "none",
        "total_elapsed_seconds": 0.0,
        "route_timeout_seconds": 0.0,
        "browser_cleanup_grace_seconds": 0.0,
        "browser_quiescence_seconds": 0.0,
        "provenance_settle_seconds": PROVENANCE_SETTLE_SECONDS,
        "provenance_status_grace_seconds": PROVENANCE_STATUS_GRACE_SECONDS,
        "cleanup_success": False,
        "task_root_finalized": False,
        "stateProofs": [],
    }
    return DriverResult(
        exit_code=exit_code,
        report=report,
        stdout=_encoded_report(report),
    )


def _failure_result(config, exit_code, outcome):
    session = getattr(config, "session_nonce", "invalid")
    if not isinstance(session, str) or _SESSION_PATTERN.fullmatch(session) is None:
        session = "invalid"
    report = {
        "schemaVersion": 1,
        "session": session,
        "request": getattr(config, "request_nonce", "invalid"),
        "bundleIdentifier": getattr(config, "bundle_identifier", "invalid"),
        "targetID": getattr(config, "target_id", "invalid"),
        "capability": getattr(config, "capability", "invalid"),
        "state": getattr(config, "state", "invalid"),
        "mode": getattr(config, "mode", "invalid"),
        "mechanism": getattr(config, "expected_mechanism", "invalid"),
        "e2eAppIdentity": getattr(config, "e2e_app_identity", "invalid"),
        "browserAppIdentity": getattr(config, "browser_app_identity", "invalid"),
        "outcome": outcome,
        "token_received": False,
        "exact_process_identity": False,
        "exact_browser_process_identity": False,
        "launch_provenance": "none",
        "total_elapsed_seconds": 0.0,
        "route_timeout_seconds": 0.0,
        "browser_cleanup_grace_seconds": 0.0,
        "browser_quiescence_seconds": 0.0,
        "provenance_settle_seconds": PROVENANCE_SETTLE_SECONDS,
        "provenance_status_grace_seconds": PROVENANCE_STATUS_GRACE_SECONDS,
        "cleanup_success": False,
        "task_root_finalized": False,
        "stateProofs": [],
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


def _validated_config(config, browser_binding_checker):
    if (
        config.mode not in {"normal", "private"}
        or config.expected_mechanism not in _PROVENANCE_MECHANISMS
    ):
        return None
    if not _valid_nonempty(config.target_id, 512):
        return None
    if not _valid_nonempty(config.bundle_identifier, 255):
        return None
    if _SESSION_PATTERN.fullmatch(config.session_nonce) is None:
        return None
    if _SESSION_PATTERN.fullmatch(config.request_nonce) is None:
        return None
    if config.capability not in {"normal", "private", "profile", "profile-private"}:
        return None
    if config.state not in {"cold", "running", "reopen", "sequence"}:
        return None
    if config.state == "sequence":
        if (
            config.route_count != 3
            or not isinstance(config.sequence_requests, tuple)
            or len(config.sequence_requests) != 3
            or len(set(config.sequence_requests)) != 3
            or any(
                _SESSION_PATTERN.fullmatch(request) is None
                for request in config.sequence_requests
            )
        ):
            return None
    elif config.route_count != 1 or config.sequence_requests:
        return None
    if not all(
        isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value)
        for value in (config.e2e_app_identity, config.browser_app_identity)
    ):
        return None
    if not _valid_profile_grant_config(config):
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
    if not _physical_app(e2e_app):
        return None
    e2e_executable = e2e_app / "Contents" / "MacOS" / "PickVia"
    if not _physical_executable(e2e_executable):
        return None
    browser_binding_checker(
        browser_app,
        browser_executable,
        config.bundle_identifier,
    )
    return timeout, e2e_app, e2e_executable, browser_executable


def _valid_profile_grant_config(config):
    strategy = config.profile_strategy
    relative_root = config.profile_relative_root
    if strategy is None and relative_root is None:
        return not config.create_profile and not config.derive_profile_target
    if strategy not in _PROFILE_STRATEGIES or not _valid_nonempty(relative_root, 1_024):
        return False
    if relative_root.startswith("/"):
        return False
    pure = pathlib.PurePosixPath(relative_root)
    valid_relative_root = (
        pure.as_posix() == relative_root
        and pure.parts
        and pure.parts != (".",)
        and all(part not in {"", ".", ".."} for part in pure.parts)
    )
    if not valid_relative_root:
        return False
    if config.derive_profile_target and not config.create_profile:
        return False
    if config.create_profile:
        return (
            pure.parts[0] == "profiles"
            and len(pure.parts) == 2
            and config.target_id == f"{config.bundle_identifier}||{config.mode}"
        )
    return not config.derive_profile_target


def _derived_profile_target_id(bundle_identifier, strategy, root, mode):
    if strategy == "chromium":
        identity = "PickVia E2E"
    elif strategy == "firefox":
        profile_path = pathlib.Path(root) / "PickVia E2E"
        digest = hashlib.sha256(os.fspath(profile_path).encode("utf-8")).hexdigest()
        identity = f"firefox-profile-v1:{digest}"
    else:
        raise ValueError("invalid profile strategy")
    return f"{bundle_identifier}|{identity}|{mode}"


def _prepare_profile_parent(task_root):
    task_root.require_current()
    try:
        os.mkdir("profiles", mode=0o700, dir_fd=task_root.descriptor)
    except FileExistsError:
        pass
    metadata = os.stat("profiles", dir_fd=task_root.descriptor, follow_symlinks=False)
    parent = task_root.child_path("profiles")
    if (
        not stat.S_ISDIR(metadata.st_mode)
        or stat.S_ISLNK(metadata.st_mode)
        or metadata.st_uid != os.getuid()
        or metadata.st_dev != task_root.identity.device
        or stat.S_IMODE(metadata.st_mode) != 0o700
        or pathlib.Path(os.path.realpath(parent)) != parent
    ):
        raise OSError("invalid profile parent")
    return parent


def _profile_root_for_creation(task_root, relative_root):
    pure = pathlib.PurePosixPath(relative_root)
    if len(pure.parts) != 2 or pure.parts[0] != "profiles":
        raise OSError("invalid profile root")
    parent = _prepare_profile_parent(task_root)
    root = parent / pure.parts[1]
    if root.exists() or root.is_symlink():
        raise OSError("profile root already exists")
    return root


def _create_synthetic_profile(
    strategy, application, executable, bundle_identifier, root
):
    try:
        import create_synthetic_profile as creator

        arguments = argparse.Namespace(
            application=os.fspath(application),
            executable=os.fspath(executable),
            bundle_identifier=bundle_identifier,
            strategy=strategy,
            root=os.fspath(root),
        )
        creator.create_synthetic_profile(arguments)
    except Exception as error:
        raise OSError("synthetic profile creation failed") from error


def _profile_grant_manifest(config):
    if config.profile_strategy is None:
        return None
    return (
        json.dumps(
            {
                "schemaVersion": 1,
                "bundleIdentifier": config.bundle_identifier,
                "strategy": config.profile_strategy,
                "relativeRoot": config.profile_relative_root,
            },
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
        + b"\n"
    )


def _validate_browser_binding(browser_app, browser_executable, bundle_identifier):
    if not _physical_app(browser_app):
        raise _IdentityError
    info_plist = browser_app / "Contents" / "Info.plist"
    plist_descriptor = -1
    executable_descriptor = -1
    try:
        plist_descriptor, plist_identity = _open_stable_regular_file(
            info_plist, maximum_bytes=1_048_576
        )
        plist_metadata = os.fstat(plist_descriptor)
        contents = bytearray()
        while len(contents) < plist_metadata.st_size:
            chunk = os.read(
                plist_descriptor,
                min(65_536, plist_metadata.st_size - len(contents)),
            )
            if not chunk:
                break
            contents.extend(chunk)
        if len(contents) != plist_metadata.st_size:
            raise _IdentityError
        _require_stable_open_file(info_plist, plist_descriptor, plist_identity)
        document = plistlib.loads(bytes(contents))

        executable_descriptor, executable_identity = _open_stable_regular_file(
            browser_executable, require_executable=True
        )
        _require_stable_open_file(
            browser_executable, executable_descriptor, executable_identity
        )
    except (OSError, plistlib.InvalidFileException) as error:
        raise _IdentityError from error
    finally:
        for descriptor in (plist_descriptor, executable_descriptor):
            if descriptor >= 0:
                os.close(descriptor)
    if not isinstance(document, dict):
        raise _IdentityError
    observed_bundle = document.get("CFBundleIdentifier")
    executable_name = document.get("CFBundleExecutable")
    if (
        not isinstance(observed_bundle, str)
        or observed_bundle != bundle_identifier
        or not isinstance(executable_name, str)
        or not executable_name
        or executable_name in {".", ".."}
        or "/" in executable_name
        or "\x00" in executable_name
    ):
        raise _IdentityError
    canonical_executable = browser_app / "Contents" / "MacOS" / executable_name
    if canonical_executable != browser_executable:
        raise _IdentityError


def _open_stable_regular_file(path, *, maximum_bytes=None, require_executable=False):
    if (
        not path.is_absolute()
        or pathlib.Path(os.path.realpath(path)) != path
        or (require_executable and not os.access(path, os.X_OK))
    ):
        raise _IdentityError
    named = os.stat(path, follow_symlinks=False)
    descriptor = os.open(
        path,
        os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0),
    )
    try:
        opened = os.fstat(descriptor)
        identity = _EntryIdentity.from_stat(opened)
        if (
            not stat.S_ISREG(opened.st_mode)
            or stat.S_ISLNK(named.st_mode)
            or _EntryIdentity.from_stat(named) != identity
            or (maximum_bytes is not None and opened.st_size > maximum_bytes)
            or (require_executable and opened.st_mode & 0o111 == 0)
        ):
            raise _IdentityError
        return descriptor, identity
    except BaseException:
        os.close(descriptor)
        raise


def _require_stable_open_file(path, descriptor, expected_identity):
    opened = os.fstat(descriptor)
    named = os.stat(path, follow_symlinks=False)
    if (
        _EntryIdentity.from_stat(opened) != expected_identity
        or _EntryIdentity.from_stat(named) != expected_identity
        or stat.S_ISLNK(named.st_mode)
    ):
        raise _IdentityError


def _validate_signed_browser_binding(
    browser_app, browser_executable, bundle_identifier
):
    _validate_browser_binding(browser_app, browser_executable, bundle_identifier)
    try:
        completed = subprocess.run(
            [
                "/usr/bin/codesign",
                "--verify",
                "--deep",
                "--strict",
                os.fspath(browser_app),
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env=_minimal_child_environment(pathlib.Path("/private/tmp")),
            timeout=BROWSER_BINDING_VERIFICATION_TIMEOUT_SECONDS,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise _IdentityError from error
    if completed.returncode != 0:
        raise _IdentityError


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


def _make_task_root_while_signals_blocked(owner):
    parent = pathlib.Path("/private/tmp")
    parent_descriptor = None
    root = None
    descriptor = None
    initial_identity = None
    pinned = None
    try:
        parent_descriptor = os.open(
            parent,
            os.O_RDONLY
            | getattr(os, "O_DIRECTORY", 0)
            | getattr(os, "O_NOFOLLOW", 0)
            | getattr(os, "O_CLOEXEC", 0),
        )
        parent_identity = _DirectoryIdentity.from_stat(os.fstat(parent_descriptor))
        root = pathlib.Path(tempfile.mkdtemp(prefix="pickvia-e2e-", dir="/private/tmp"))
        metadata = root.lstat()
        initial_identity = _DirectoryIdentity.from_stat(metadata)
        if (
            root.parent != parent
            or not root.name.startswith("pickvia-e2e-")
            or not stat.S_ISDIR(metadata.st_mode)
            or stat.S_ISLNK(metadata.st_mode)
            or metadata.st_uid != os.getuid()
            or pathlib.Path(os.path.realpath(root)) != root
        ):
            raise OSError("unsafe task root")
        descriptor = os.open(
            root,
            os.O_RDONLY
            | getattr(os, "O_DIRECTORY", 0)
            | getattr(os, "O_NOFOLLOW", 0)
            | getattr(os, "O_CLOEXEC", 0),
        )
        opened = os.fstat(descriptor)
        if (
            not stat.S_ISDIR(opened.st_mode)
            or _DirectoryIdentity.from_stat(opened) != initial_identity
        ):
            raise OSError("unsafe task root")
        pinned = _PinnedTaskRoot(
            root,
            descriptor,
            _DirectoryIdentity.from_stat(opened),
            parent_descriptor,
            parent_identity,
        )
        os.fchmod(descriptor, 0o700)
        pinned.identity = _DirectoryIdentity.from_stat(os.fstat(descriptor))
        pinned.require_current()
        owner.register(pinned)
        return pinned
    except BaseException:
        if pinned is not None:
            try:
                pinned.identity = _DirectoryIdentity.from_stat(
                    os.fstat(pinned.descriptor)
                )
            except OSError:
                pass
            try:
                pinned.remove()
            except BaseException:
                pinned.close()
        elif descriptor is not None:
            try:
                recovered = os.fstat(descriptor)
                if (
                    initial_identity is not None
                    and _DirectoryIdentity.from_stat(recovered) == initial_identity
                    and parent_descriptor is not None
                ):
                    recovery_root = _PinnedTaskRoot(
                        root,
                        descriptor,
                        initial_identity,
                        parent_descriptor,
                        parent_identity,
                    )
                    recovery_root.remove()
                    descriptor = None
                    parent_descriptor = None
            except BaseException:
                pass
            finally:
                if descriptor is not None:
                    try:
                        os.close(descriptor)
                    except OSError:
                        pass
                if parent_descriptor is not None:
                    try:
                        os.close(parent_descriptor)
                    except OSError:
                        pass
        elif root is not None and initial_identity is not None:
            try:
                if _DirectoryIdentity.from_stat(root.lstat()) == initial_identity:
                    os.rmdir(root)
            except OSError:
                pass
            if parent_descriptor is not None:
                os.close(parent_descriptor)
        elif parent_descriptor is not None:
            if root is not None:
                try:
                    os.rmdir(root)
                except OSError:
                    pass
            os.close(parent_descriptor)
        raise


def _make_task_root(owner):
    if not isinstance(owner, _TaskRootOwner):
        raise TypeError("task root owner is required")
    previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, set())
    pending_interrupt = False
    try:
        signal.pthread_sigmask(signal.SIG_BLOCK, _DEFERRED_SIGNALS)
        root = _make_task_root_while_signals_blocked(owner)
        pending_interrupt = bool(signal.sigpending() & _DEFERRED_SIGNALS)
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
    if pending_interrupt:
        raise _DriverInterrupted
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
            try:
                wait = min(_remaining(deadline, monotonic), 0.05)
            except _DeadlineExpired as error:
                raise _ReadinessError from error
            events = selector.select(wait)
            if not events:
                if process.poll() is not None:
                    raise _ReadinessError
                continue
            chunk = os.read(descriptor, 512)
            if not chunk:
                raise _ReadinessError
            processes.append_manual_stdout(process, chunk)
            buffer.extend(chunk)
            if len(buffer) > MAXIMUM_PROTOCOL_LINE_BYTES:
                raise _ReadinessError
            newline = buffer.find(b"\n")
            if newline >= 0:
                if newline != len(buffer) - 1:
                    raise _ReadinessError
                return bytes(buffer)
    finally:
        selector.close()


def _parse_ready(line):
    record = _strict_json_document(line, _ReadinessError, MAXIMUM_PROTOCOL_LINE_BYTES)
    if not isinstance(record, dict) or set(record) != {"port", "tokens"}:
        raise _ReadinessError
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
        raise _ReadinessError
    return port, tokens[0]


def _parse_status(line, expected_session):
    record = _strict_json_document(
        line, _StatusProtocolError, MAXIMUM_PROTOCOL_LINE_BYTES
    )
    if not isinstance(record, dict) or set(record) != {"session", "outcome"}:
        raise _StatusProtocolError
    session = record["session"]
    outcome = record["outcome"]
    if not isinstance(session, str) or not isinstance(outcome, str):
        raise _StatusProtocolError
    if session != expected_session or outcome not in _CLOSED_OUTCOMES:
        raise _StatusProtocolError
    return outcome


def _parse_provenance(
    line,
    *,
    expected_session,
    expected_request,
    expected_target,
    expected_bundle_identifier,
    expected_mode,
    expected_mechanism,
):
    record = _strict_json_document(
        line, _ProvenanceProtocolError, MAXIMUM_PROVENANCE_LINE_BYTES
    )
    if not isinstance(record, dict):
        raise _ProvenanceProtocolError
    outcome = record.get("outcome")
    expected_keys = {
        "session",
        "request",
        "target",
        "bundleIdentifier",
        "mode",
        "mechanism",
        "outcome",
    }
    if outcome == "launch-observed":
        expected_keys.add("processIdentifier")
    if set(record) != expected_keys:
        raise _ProvenanceProtocolError
    if (
        record.get("session") != expected_session
        or record.get("request") != expected_request
        or record.get("target") != expected_target
        or record.get("bundleIdentifier") != expected_bundle_identifier
        or record.get("mode") != expected_mode
        or outcome not in _PROVENANCE_OUTCOMES
        or record.get("mechanism") != expected_mechanism
    ):
        raise _ProvenanceProtocolError
    process_identifier = record.get("processIdentifier")
    if outcome == "launch-observed":
        if (
            not isinstance(process_identifier, int)
            or isinstance(process_identifier, bool)
            or process_identifier <= 0
            or process_identifier > 2_147_483_647
        ):
            raise _ProvenanceProtocolError
    elif process_identifier is not None:
        raise _ProvenanceProtocolError
    return LaunchProvenance(
        outcome=outcome,
        mechanism=record["mechanism"],
        process_identifier=process_identifier,
    )


def _strict_json_document(line, protocol_error, maximum_bytes):
    if (
        not isinstance(line, bytes)
        or not line.endswith(b"\n")
        or len(line) > maximum_bytes
    ):
        raise protocol_error

    def strict_object(pairs):
        record = {}
        for key, value in pairs:
            if key in record:
                raise protocol_error
            record[key] = value
        return record

    def reject_constant(_value):
        raise protocol_error

    try:
        return json.loads(
            line,
            object_pairs_hook=strict_object,
            parse_constant=reject_constant,
        )
    except protocol_error:
        raise
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise protocol_error from error


def _parse_receipt(line, expected_token):
    record = _strict_json_document(
        line, _ReceiptProtocolError, MAXIMUM_PROTOCOL_LINE_BYTES
    )
    if not isinstance(record, dict) or set(record) != {
        "token",
        "receipt_time",
        "remote_address",
    }:
        raise _ReceiptProtocolError
    if (
        record["token"] != expected_token
        or record["remote_address"] != "127.0.0.1"
        or type(record["receipt_time"]) not in {int, float}
        or (
            isinstance(record["receipt_time"], float)
            and not math.isfinite(record["receipt_time"])
        )
    ):
        raise _ReceiptProtocolError
    return True


def _minimal_child_environment(task_root):
    root_path = (
        task_root.require_current()
        if isinstance(task_root, _PinnedTaskRoot)
        else pathlib.Path(task_root)
    )
    root = os.fspath(root_path)
    return {
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "LANG": "en_US.UTF-8",
        "LC_CTYPE": "UTF-8",
        "TMPDIR": root,
        "CFFIXED_USER_HOME": root,
    }


def _compile_helper(processes, source, output, deadline, monotonic, *, environment):
    if not source.is_file() or source.is_symlink():
        raise _HelperError
    process = processes.start(
        "helper-compiler",
        ["/usr/bin/xcrun", "swiftc", source, "-o", output],
        environment=environment,
        stdin=subprocess.DEVNULL,
    )
    try:
        process.wait(timeout=_remaining(deadline, monotonic))
    except subprocess.TimeoutExpired as error:
        raise _HelperError from error
    if (
        process.returncode != 0
        or not output.is_file()
        or not os.access(output, os.X_OK)
    ):
        raise _HelperError


class _SignalGuard:
    def __init__(self):
        self._previous = {}
        self._cleaning = False
        self.received_during_cleanup = []

    def install(self):
        try:
            for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
                self._previous[signum] = signal.signal(signum, self._handle)
        except ValueError:
            self.restore()
        return self

    def begin_cleanup(self):
        self._cleaning = True

    def _handle(self, signum, frame):
        if self._cleaning:
            self.received_during_cleanup.append(signum)
            return
        raise _DriverInterrupted

    def restore(self):
        for signum, handler in self._previous.items():
            signal.signal(signum, handler)
        self._previous.clear()


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


def _reject_trailing_proof_bytes(buffers):
    if buffers["status"]:
        raise _StatusProtocolError
    if buffers["receipt"]:
        raise _ReceiptProtocolError
    if buffers["provenance"]:
        raise _ProvenanceProtocolError


def _generation_map(identities):
    return {identity.generation_key: identity for identity in identities}


def _authoritative_browser_snapshot(dependencies, executable, phase):
    try:
        return set(dependencies.browser_process_snapshot(executable, phase))
    except _IdentityInspectionError:
        raise
    except Exception as error:
        raise _IdentityInspectionError from error


def _observe_browser_generations(current, preexisting, seen_new):
    current_by_generation = _generation_map(current)
    preexisting_generations = set(_generation_map(preexisting))
    for generation, identity in current_by_generation.items():
        if generation not in preexisting_generations:
            seen_new[generation] = identity
    if len(seen_new) > 1:
        raise _IdentityAmbiguous
    existing_is_live = any(
        generation in preexisting_generations for generation in current_by_generation
    )
    exact_identity = existing_is_live or len(seen_new) == 1
    return exact_identity, frozenset(seen_new.values())


def _accumulate_browser_generations(current, preexisting, accumulated):
    seen_new = _generation_map(accumulated)
    baseline_generations = set(_generation_map(preexisting))
    current_new = frozenset(
        identity
        for identity in current
        if identity.generation_key not in baseline_generations
    )
    try:
        _, swept_owned = _observe_browser_generations(
            current,
            preexisting,
            seen_new,
        )
    except _IdentityAmbiguous:
        accumulated.update(seen_new.values())
        raise
    accumulated.update(swept_owned)
    return current_new


def _observe_browser_quiescence(
    dependencies,
    executable,
    preexisting,
    accumulated,
):
    quiescence_deadline = (
        dependencies.quiescence_monotonic() + BROWSER_QUIESCENCE_SECONDS
    )
    late_generation_seen = False
    while True:
        current = _authoritative_browser_snapshot(
            dependencies,
            executable,
            "quiescence",
        )
        current_new = _accumulate_browser_generations(
            current,
            preexisting,
            accumulated,
        )
        if current_new:
            late_generation_seen = True

        now = dependencies.quiescence_monotonic()
        if now >= quiescence_deadline:
            return late_generation_seen
        dependencies.quiescence_sleep(
            min(BROWSER_QUIESCENCE_POLL_SECONDS, quiescence_deadline - now)
        )


def _helper_cleanup_authority(status_sequence, provenance_owned):
    if status_sequence and status_sequence[0] != "selected":
        return frozenset()
    return provenance_owned


def _wait_for_proof(
    processes,
    fifo_descriptor,
    provenance_descriptor,
    receiver,
    helper,
    app,
    expected_session,
    expected_request,
    expected_target,
    expected_bundle_identifier,
    expected_mode,
    expected_mechanism,
    expected_token,
    expected_browser_app,
    expected_browser_executable,
    preexisting_browsers,
    dependencies,
    deadline,
):
    receiver_descriptor = receiver.stdout.fileno()
    os.set_blocking(receiver_descriptor, False)
    selector = selectors.DefaultSelector()
    selector.register(fifo_descriptor, selectors.EVENT_READ, "status")
    selector.register(provenance_descriptor, selectors.EVENT_READ, "provenance")
    selector.register(receiver_descriptor, selectors.EVENT_READ, "receipt")
    buffers = {"status": bytearray(), "provenance": bytearray(), "receipt": bytearray()}
    status_sequence = []
    status_lines = []
    receipt = False
    browser_identity = False
    seen_new_browsers = {}
    provenance = None
    provenance_identity = None
    provenance_owned = frozenset()
    provenance_failure = False
    provenance_failure_deadline = None
    product_launch_error_deadline = None
    provenance_settle_deadline = None
    try:
        while True:
            helper_exit_code = helper.poll()
            if helper_exit_code not in (None, 0):
                raise _HelperError(
                    receipt,
                    b"".join(status_lines),
                    browser_identity,
                    _helper_cleanup_authority(status_sequence, provenance_owned),
                )
            now = dependencies.monotonic()
            if provenance_failure:
                if (
                    status_sequence == ["selected", "launch-error"]
                    and helper_exit_code == 0
                ):
                    if provenance_settle_deadline is None:
                        provenance_settle_deadline = now + PROVENANCE_SETTLE_SECONDS
                        provenance_failure_deadline = None
                    if now >= provenance_settle_deadline:
                        raise _ProvenanceProtocolError(
                            receipt,
                            b"".join(status_lines),
                            browser_identity,
                        )
                elif (
                    provenance_failure_deadline is not None
                    and now >= provenance_failure_deadline
                ):
                    raise _ProvenanceProtocolError(
                        receipt,
                        b"".join(status_lines),
                        browser_identity,
                    )
            elif (
                status_sequence == ["selected", "launch-error"]
                and helper_exit_code == 0
            ):
                if provenance is not None and provenance.outcome != "launch-error":
                    raise _ProvenanceProtocolError(
                        receipt,
                        b"".join(status_lines),
                        browser_identity,
                    )
                if provenance_settle_deadline is None:
                    provenance_settle_deadline = now + PROVENANCE_SETTLE_SECONDS
                if now >= provenance_settle_deadline:
                    _reject_trailing_proof_bytes(buffers)
                    return _WaitResult(
                        "launch-error",
                        receipt,
                        b"".join(status_lines),
                        browser_identity,
                        provenance_owned,
                        provenance.outcome if provenance is not None else "none",
                    )
            elif (
                provenance is not None
                and provenance.outcome == "launch-error"
                and product_launch_error_deadline is not None
                and now >= product_launch_error_deadline
                and helper_exit_code == 0
            ):
                _reject_trailing_proof_bytes(buffers)
                return _WaitResult(
                    "launch-error",
                    receipt,
                    b"".join(status_lines),
                    browser_identity,
                    provenance_owned,
                    provenance.outcome if provenance is not None else "none",
                )
            if (
                status_sequence
                and status_sequence[0] != "selected"
                and helper_exit_code == 0
            ):
                if provenance is not None or provenance_owned:
                    provenance_owned = frozenset()
                    raise _ProvenanceProtocolError(
                        receipt,
                        b"".join(status_lines),
                        browser_identity,
                    )
                if provenance_settle_deadline is None:
                    provenance_settle_deadline = now + PROVENANCE_SETTLE_SECONDS
                if now >= provenance_settle_deadline:
                    _reject_trailing_proof_bytes(buffers)
                    return _WaitResult(
                        status_sequence[0],
                        receipt,
                        b"".join(status_lines),
                        browser_identity,
                        frozenset(),
                        "none",
                    )
            if status_sequence == ["selected"]:
                try:
                    current = _authoritative_browser_snapshot(
                        dependencies,
                        expected_browser_executable,
                        "observation",
                    )
                    temporal_identity, _ = _observe_browser_generations(
                        current,
                        preexisting_browsers,
                        seen_new_browsers,
                    )
                    browser_identity = browser_identity or temporal_identity
                except _IdentityAmbiguous as error:
                    error.token_received = receipt
                    error.status_line = b"".join(status_lines)
                    raise
                if (
                    receipt
                    and browser_identity
                    and provenance is not None
                    and helper_exit_code == 0
                    and not provenance_failure
                ):
                    if provenance_settle_deadline is None:
                        provenance_settle_deadline = now + PROVENANCE_SETTLE_SECONDS
                    if now >= provenance_settle_deadline:
                        _reject_trailing_proof_bytes(buffers)
                        return _WaitResult(
                            "selected",
                            True,
                            b"".join(status_lines),
                            True,
                            provenance_owned,
                            provenance.outcome,
                        )
            try:
                active_deadline = deadline
                if provenance_failure_deadline is not None:
                    active_deadline = min(active_deadline, provenance_failure_deadline)
                if provenance_settle_deadline is not None:
                    active_deadline = min(active_deadline, provenance_settle_deadline)
                if product_launch_error_deadline is not None:
                    active_deadline = min(
                        active_deadline, product_launch_error_deadline
                    )
                wait = min(_remaining(active_deadline, dependencies.monotonic), 0.05)
            except _DeadlineExpired:
                helper_exit_code = helper.poll()
                if helper_exit_code not in (None, 0):
                    raise _HelperError(
                        receipt,
                        b"".join(status_lines),
                        browser_identity,
                        _helper_cleanup_authority(status_sequence, provenance_owned),
                    )
                if helper_exit_code is None:
                    raise _HelperExitTimeout(
                        receipt,
                        b"".join(status_lines),
                        browser_identity,
                        _helper_cleanup_authority(status_sequence, provenance_owned),
                    )
                if provenance_failure:
                    raise _ProvenanceProtocolError(
                        receipt,
                        b"".join(status_lines),
                        browser_identity,
                    )
                if (
                    provenance is not None
                    and provenance.outcome == "launch-error"
                    and product_launch_error_deadline is not None
                    and dependencies.monotonic() >= product_launch_error_deadline
                ):
                    _reject_trailing_proof_bytes(buffers)
                    return _WaitResult(
                        "launch-error",
                        receipt,
                        b"".join(status_lines),
                        browser_identity,
                        provenance_owned,
                        provenance.outcome,
                    )
                if (
                    provenance is not None
                    and provenance_settle_deadline is None
                    and (
                        status_sequence == ["selected", "launch-error"]
                        or (
                            status_sequence == ["selected"]
                            and receipt
                            and browser_identity
                        )
                    )
                ):
                    raise _ProvenanceProtocolError(
                        receipt,
                        b"".join(status_lines),
                        browser_identity,
                    )
                if (
                    provenance_settle_deadline is not None
                    and dependencies.monotonic() < provenance_settle_deadline
                ):
                    raise _ProvenanceProtocolError(
                        receipt,
                        b"".join(status_lines),
                        browser_identity,
                    )
                if status_sequence == ["selected", "launch-error"]:
                    raise _ProvenanceProtocolError(
                        receipt,
                        b"".join(status_lines),
                        browser_identity,
                    )
                if status_sequence and status_sequence[0] != "selected":
                    if provenance is not None or provenance_owned:
                        provenance_owned = frozenset()
                        raise _ProvenanceProtocolError(
                            receipt,
                            b"".join(status_lines),
                            browser_identity,
                        )
                    _reject_trailing_proof_bytes(buffers)
                    return _WaitResult(
                        status_sequence[0],
                        receipt,
                        b"".join(status_lines),
                        browser_identity,
                        frozenset(),
                        "none",
                    )
                if status_sequence == ["selected"] and not receipt:
                    raise _ReceiptTimeout(
                        receipt,
                        b"".join(status_lines),
                        browser_identity,
                        provenance_owned,
                        provenance.outcome if provenance is not None else "none",
                    )
                if status_sequence == ["selected"] and not browser_identity:
                    raise _BrowserIdentityTimeout(
                        receipt,
                        b"".join(status_lines),
                        browser_identity,
                        provenance_owned,
                        provenance.outcome if provenance is not None else "none",
                    )
                if (
                    status_sequence == ["selected"]
                    and receipt
                    and browser_identity
                    and provenance is None
                ):
                    raise _ProvenanceProtocolError(
                        receipt,
                        b"".join(status_lines),
                        browser_identity,
                    )
                if status_sequence == ["selected"] and receipt and browser_identity:
                    _reject_trailing_proof_bytes(buffers)
                    return _WaitResult(
                        "selected",
                        True,
                        b"".join(status_lines),
                        True,
                        provenance_owned,
                        provenance.outcome,
                    )
                raise
            for key, _ in selector.select(wait):
                try:
                    chunk = os.read(key.fd, 512)
                except BlockingIOError:
                    continue
                if not chunk:
                    selector.unregister(key.fd)
                    continue
                if key.data == "receipt":
                    processes.append_manual_stdout(receiver, chunk)
                buffer = buffers[key.data]
                if key.data == "provenance" and provenance is not None:
                    raise _ProvenanceProtocolError(
                        receipt,
                        b"".join(status_lines),
                        browser_identity,
                    )
                buffer.extend(chunk)
                maximum = (
                    MAXIMUM_PROVENANCE_LINE_BYTES
                    if key.data == "provenance"
                    else MAXIMUM_PROTOCOL_LINE_BYTES
                )
                if len(buffer) > maximum:
                    if key.data == "status":
                        raise _StatusProtocolError
                    if key.data == "provenance":
                        raise _ProvenanceProtocolError(
                            receipt,
                            b"".join(status_lines),
                            browser_identity,
                        )
                    raise _ReceiptProtocolError
                if key.data == "status":
                    status_lines.extend(
                        _consume_status_lines(buffer, status_sequence, expected_session)
                    )
                elif key.data == "provenance":
                    newline = buffer.find(b"\n")
                    if newline >= 0:
                        line = bytes(buffer[: newline + 1])
                        del buffer[: newline + 1]
                        if provenance is not None or buffer:
                            raise _ProvenanceProtocolError(
                                receipt,
                                b"".join(status_lines),
                                browser_identity,
                            )
                        try:
                            provenance = _parse_provenance(
                                line,
                                expected_session=expected_session,
                                expected_request=expected_request,
                                expected_target=expected_target,
                                expected_bundle_identifier=expected_bundle_identifier,
                                expected_mode=expected_mode,
                                expected_mechanism=expected_mechanism,
                            )
                            if status_sequence and status_sequence[0] != "selected":
                                raise _ProvenanceProtocolError
                            if provenance.outcome == "launch-unproven":
                                provenance_failure = True
                                provenance_failure_deadline = (
                                    dependencies.monotonic()
                                    + PROVENANCE_STATUS_GRACE_SECONDS
                                )
                            elif provenance.outcome == "launch-error":
                                product_launch_error_deadline = (
                                    dependencies.monotonic()
                                    + PROVENANCE_STATUS_GRACE_SECONDS
                                )
                            elif provenance.outcome == "launch-observed":
                                try:
                                    pinned_provenance_identity = (
                                        dependencies.browser_process_identity(
                                            provenance.process_identifier
                                        )
                                    )
                                    if (
                                        pinned_provenance_identity.pid
                                        != provenance.process_identifier
                                        or pinned_provenance_identity.executable
                                        != pathlib.Path(expected_browser_executable)
                                    ):
                                        raise _ProvenanceProtocolError
                                    dependencies.browser_binding_checker(
                                        pathlib.Path(expected_browser_app),
                                        pathlib.Path(expected_browser_executable),
                                        expected_bundle_identifier,
                                    )
                                    dependencies.browser_running_code_checker(
                                        provenance.process_identifier,
                                        pathlib.Path(expected_browser_app),
                                        pathlib.Path(expected_browser_executable),
                                        expected_bundle_identifier,
                                    )
                                    confirmed_provenance_identity = (
                                        dependencies.browser_process_identity(
                                            provenance.process_identifier
                                        )
                                    )
                                    if (
                                        confirmed_provenance_identity.pid
                                        != provenance.process_identifier
                                        or confirmed_provenance_identity.executable
                                        != pathlib.Path(expected_browser_executable)
                                        or confirmed_provenance_identity.generation_key
                                        != pinned_provenance_identity.generation_key
                                    ):
                                        raise _ProvenanceProtocolError
                                except (
                                    _ProvenanceProtocolError,
                                    _ProcessDisappeared,
                                    _IdentityInspectionError,
                                    _IdentityError,
                                    OSError,
                                    ValueError,
                                    TypeError,
                                ):
                                    provenance_failure = True
                                    provenance_failure_deadline = (
                                        dependencies.monotonic()
                                        + PROVENANCE_STATUS_GRACE_SECONDS
                                    )
                                    provenance_identity = None
                                    provenance_owned = frozenset()
                                else:
                                    provenance_identity = pinned_provenance_identity
                                    browser_identity = True
                                    baseline_generations = set(
                                        _generation_map(preexisting_browsers)
                                    )
                                    if (
                                        provenance_identity.generation_key
                                        not in baseline_generations
                                    ):
                                        provenance_owned = frozenset(
                                            {provenance_identity}
                                        )
                        except _ProvenanceProtocolError as error:
                            error.token_received = receipt
                            error.status_line = b"".join(status_lines)
                            error.browser_identity = browser_identity
                            raise
                        except (
                            _ProcessDisappeared,
                            _IdentityInspectionError,
                            _IdentityError,
                            OSError,
                            ValueError,
                            TypeError,
                        ) as error:
                            raise _ProvenanceProtocolError(
                                receipt,
                                b"".join(status_lines),
                                browser_identity,
                            ) from error
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
                raise _HelperError
            if (
                receiver.poll() not in (None, 0)
                and not receipt
                and not buffers["receipt"]
            ):
                raise ChildProcessError
    except (_StatusProtocolError, _ReceiptProtocolError) as error:
        error.token_received = receipt
        error.status_line = b"".join(status_lines)
        error.browser_identity = browser_identity
        error.owned_browsers = _helper_cleanup_authority(
            status_sequence, provenance_owned
        )
        raise
    finally:
        selector.close()


@dataclasses.dataclass
class _AuditBudget:
    deadline: float
    work_bytes: int = 0
    work_entries: int = 0

    def check_deadline(self):
        if time.monotonic() > self.deadline:
            raise OSError("privacy audit deadline exceeded")

    def spend_entries(self, count, audit_pass, *, count_toward_tree):
        self.check_deadline()
        if count_toward_tree:
            audit_pass.entries_seen += count
        self.work_entries += count
        if (
            audit_pass.entries_seen > MAXIMUM_AUDIT_ENTRIES
            or self.work_entries > MAXIMUM_AUDIT_WORK_ENTRIES
        ):
            raise OSError("privacy audit entry budget exceeded")

    def spend_file(self, size, audit_pass):
        self.check_deadline()
        audit_pass.bytes_seen += size
        if audit_pass.bytes_seen > MAXIMUM_AUDIT_FILE_BYTES:
            raise OSError("privacy audit tree byte cap exceeded")

    def spend_work_bytes(self, count):
        self.check_deadline()
        self.work_bytes += count
        if self.work_bytes > MAXIMUM_AUDIT_WORK_BYTES:
            raise OSError("privacy audit work byte budget exceeded")


@dataclasses.dataclass
class _AuditPass:
    bytes_seen: int = 0
    entries_seen: int = 0


def _snapshot_directory_at(
    descriptor,
    root_device,
    budget,
    audit_pass,
    *,
    count_toward_tree,
):
    budget.check_deadline()
    entries = {}
    with os.scandir(descriptor) as iterator:
        for entry in iterator:
            budget.spend_entries(
                1,
                audit_pass,
                count_toward_tree=count_toward_tree,
            )
            name = entry.name
            metadata = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
            if stat.S_ISDIR(metadata.st_mode) and metadata.st_dev != root_device:
                raise OSError("task root crosses a device boundary")
            entries[name] = _EntryIdentity.from_stat(metadata)
    return entries


def _audit_regular_files_at(
    descriptor,
    forbidden,
    root_device,
    budget,
    audit_pass,
):
    budget.check_deadline()
    directory_before = _EntryIdentity.from_stat(os.fstat(descriptor))
    initial = _snapshot_directory_at(
        descriptor,
        root_device,
        budget,
        audit_pass,
        count_toward_tree=True,
    )
    fingerprints = []
    for name, expected in initial.items():
        budget.check_deadline()
        metadata = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
        if _EntryIdentity.from_stat(metadata) != expected:
            return None
        if stat.S_ISLNK(metadata.st_mode):
            return False
        if stat.S_ISDIR(metadata.st_mode):
            child = os.open(
                name,
                os.O_RDONLY
                | getattr(os, "O_DIRECTORY", 0)
                | getattr(os, "O_NOFOLLOW", 0)
                | getattr(os, "O_CLOEXEC", 0),
                dir_fd=descriptor,
            )
            try:
                opened = os.fstat(child)
                if _EntryIdentity.from_stat(opened) != expected:
                    return None
                if opened.st_dev != root_device:
                    return False
                child_fingerprint = _audit_regular_files_at(
                    child,
                    forbidden,
                    root_device,
                    budget,
                    audit_pass,
                )
                if child_fingerprint is None or child_fingerprint is False:
                    return child_fingerprint
            finally:
                os.close(child)
            fingerprints.append((name, expected, child_fingerprint))
            continue
        if not stat.S_ISREG(metadata.st_mode):
            fingerprints.append((name, expected, None))
            continue
        if metadata.st_size > MAXIMUM_AUDIT_FILE_BYTES:
            return False
        budget.spend_file(metadata.st_size, audit_pass)
        file_descriptor = os.open(
            name,
            os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0),
            dir_fd=descriptor,
        )
        try:
            opened = os.fstat(file_descriptor)
            if (
                not stat.S_ISREG(opened.st_mode)
                or _EntryIdentity.from_stat(opened) != expected
                or opened.st_size > MAXIMUM_AUDIT_FILE_BYTES
            ):
                return False
            previous = b""
            bytes_read = 0
            while True:
                chunk = os.read(file_descriptor, 65_536)
                if not chunk:
                    break
                bytes_read += len(chunk)
                budget.spend_work_bytes(len(chunk))
                if bytes_read > metadata.st_size:
                    return False
                combined = previous + chunk
                if forbidden in combined:
                    return False
                previous = combined[-max(len(forbidden) - 1, 0) :]
            final_opened = os.fstat(file_descriptor)
            if (
                bytes_read != metadata.st_size
                or _EntryIdentity.from_stat(final_opened) != expected
            ):
                return False
        finally:
            os.close(file_descriptor)
        fingerprints.append((name, expected, None))
    final = _snapshot_directory_at(
        descriptor,
        root_device,
        budget,
        audit_pass,
        count_toward_tree=False,
    )
    budget.check_deadline()
    directory_after = _EntryIdentity.from_stat(os.fstat(descriptor))
    if final != initial or directory_after != directory_before:
        return None
    return (directory_before, tuple(sorted(fingerprints, key=lambda item: item[0])))


def run_driver(config, dependencies=None):
    dependencies = dependencies or DriverDependencies()
    try:
        validated = _validated_config(config, dependencies.browser_binding_checker)
    except _IdentityError:
        return _failure_result(config, DRIVER_IDENTITY_FAILURE, "identity-error")
    if validated is None:
        return _empty_result(DRIVER_USAGE)
    timeout, e2e_app, e2e_executable, browser_executable = validated
    started = dependencies.monotonic()
    processes = _OwnedProcesses(dependencies)
    task_root = None
    task_root_owner = _TaskRootOwner()
    fifo_descriptor = None
    provenance_descriptor = None
    route_payloads = []
    state_proofs = []
    status_line = b""
    outcome = "driver-error"
    received = False
    exact_e2e_identity = False
    exact_browser_identity = False
    launch_provenance = "none"
    exit_code = DRIVER_PROCESS_ERROR
    app = None
    preexisting_browsers = set()
    owned_browsers = set()
    observed_browsers = set()
    browser_termination_attempts = set()
    cleanup_ok = True
    identity_ambiguous = False
    identity_inspection_failed = False
    baseline_authoritative = False
    route_delivery_attempted = False
    task_root_finalized = False
    signal_guard = _SignalGuard().install()
    target_id = config.target_id
    try:
        preexisting_browsers = _authoritative_browser_snapshot(
            dependencies, browser_executable, "baseline"
        )
        baseline_authoritative = True
        task_root = _make_task_root(task_root_owner)
        if config.create_profile:
            profile_root = _profile_root_for_creation(
                task_root, config.profile_relative_root
            )
            task_root.require_current()
            dependencies.profile_creator(
                config.profile_strategy,
                pathlib.Path(config.browser_app),
                browser_executable,
                config.bundle_identifier,
                profile_root,
            )
            task_root.require_current()
            if not profile_root.is_dir() or profile_root.is_symlink():
                raise _IdentityError
            if config.derive_profile_target:
                target_id = _derived_profile_target_id(
                    config.bundle_identifier,
                    config.profile_strategy,
                    profile_root,
                    config.mode,
                )
        profile_grant_manifest = _profile_grant_manifest(config)
        if profile_grant_manifest is not None:
            task_root.write_regular_file("profile-grant.json", profile_grant_manifest)
        base_environment = _minimal_child_environment(task_root)
        helper_executable = dependencies.helper_executable
        if helper_executable is None:
            helper_executable = task_root.child_path("open_with_app")
            task_root.require_current()
            _compile_helper(
                processes,
                pathlib.Path(dependencies.helper_source),
                helper_executable,
                dependencies.monotonic() + timeout,
                dependencies.monotonic,
                environment=base_environment,
            )
        elif not _physical_executable(pathlib.Path(helper_executable)):
            raise _HelperError

        def perform_route(state, request_nonce):
            nonlocal app, cleanup_ok, exact_e2e_identity
            nonlocal fifo_descriptor, provenance_descriptor, route_delivery_attempted
            route_started = dependencies.monotonic()
            route_deadline = dependencies.monotonic() + timeout
            fifo_suffix = f"-{state}" if config.state == "sequence" else ""
            fifo_name = f"status{fifo_suffix}.fifo"
            provenance_name = f"provenance{fifo_suffix}.fifo"
            task_root.create_fifo(fifo_name)
            task_root.create_fifo(provenance_name)
            fifo = task_root.child_path(fifo_name)
            provenance_fifo = task_root.child_path(provenance_name)
            fifo_descriptor = task_root.open_fifo(fifo_name)
            provenance_descriptor = task_root.open_fifo(provenance_name)
            task_root.require_current()
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
                environment=base_environment,
                stdin=subprocess.DEVNULL,
                manual_stdout=True,
            )
            ready = _read_protocol_line(
                processes, receiver, route_deadline, dependencies.monotonic
            )
            port, token = _parse_ready(ready)
            app_environment = dict(base_environment)
            app_environment.update(
                {
                    "PICKVIA_E2E_TARGET_ID": target_id,
                    "PICKVIA_E2E_BUNDLE_ID": config.bundle_identifier,
                    "PICKVIA_E2E_MODE": config.mode,
                    "PICKVIA_E2E_SESSION_NONCE": config.session_nonce,
                    "PICKVIA_E2E_REQUEST_NONCE": request_nonce,
                    "PICKVIA_E2E_SUPPORT_DIR": os.fspath(task_root.require_current()),
                    "PICKVIA_E2E_STATUS_FIFO": os.fspath(fifo),
                    "PICKVIA_E2E_PROVENANCE_FIFO": os.fspath(provenance_fifo),
                }
            )
            task_root.require_current()
            app = processes.start(
                "e2e-app",
                [e2e_executable],
                environment=app_environment,
                stdin=subprocess.DEVNULL,
            )
            exact_e2e_identity = dependencies.process_identity_checker(
                app, e2e_executable
            )
            if not exact_e2e_identity:
                raise _IdentityError
            current_route = f"http://127.0.0.1:{port}/{token}".encode("ascii")
            route_payloads.append(current_route)
            dependencies.route_observer(current_route.decode("ascii"))
            task_root.require_current()
            helper = processes.start(
                "exact-app-helper",
                [helper_executable, e2e_app, str(app.pid)],
                environment=base_environment,
                stdin=subprocess.PIPE,
            )
            route_delivery_attempted = True
            try:
                helper.stdin.write(current_route)
                helper.stdin.flush()
                helper.stdin.close()
            except OSError as error:
                raise _HelperError from error
            proof = _wait_for_proof(
                processes,
                fifo_descriptor,
                provenance_descriptor,
                receiver,
                helper,
                app,
                config.session_nonce,
                request_nonce,
                target_id,
                config.bundle_identifier,
                config.mode,
                config.expected_mechanism,
                token,
                pathlib.Path(config.browser_app),
                browser_executable,
                preexisting_browsers,
                dependencies,
                route_deadline,
            )
            cleanup_ok = dependencies.fifo_closer(fifo_descriptor) and cleanup_ok
            fifo_descriptor = None
            cleanup_ok = dependencies.fifo_closer(provenance_descriptor) and cleanup_ok
            provenance_descriptor = None
            if config.state == "sequence":
                if not processes.stop(app):
                    raise _StateSequenceError
                app = None
            state_proofs.append(
                [
                    state,
                    request_nonce,
                    proof,
                    None,
                    max(dependencies.monotonic() - route_started, 0.0),
                ]
            )
            if config.state != "sequence":
                owned_browsers.update(proof.owned_browser_identities)
                return (
                    next(iter(proof.owned_browser_identities))
                    if len(proof.owned_browser_identities) == 1
                    else None
                )
            if (
                proof.outcome != "selected"
                or not proof.token_received
                or not proof.exact_browser_identity
                or proof.launch_provenance != "launch-observed"
                or len(proof.owned_browser_identities) != 1
            ):
                raise _StateSequenceError
            identity = next(iter(proof.owned_browser_identities))
            state_proofs[-1][3] = identity
            owned_browsers.add(identity)
            return identity

        if config.state == "sequence":
            if preexisting_browsers:
                raise _StateSequenceError

            def sequence_snapshot(phase):
                return _authoritative_browser_snapshot(
                    dependencies, browser_executable, f"sequence-{phase}"
                )

            def sequence_attest(identity):
                before = dependencies.browser_process_identity(identity.pid)
                if before.generation_key != identity.generation_key:
                    return False
                dependencies.browser_binding_checker(
                    pathlib.Path(config.browser_app),
                    browser_executable,
                    config.bundle_identifier,
                )
                dependencies.browser_running_code_checker(
                    identity.pid,
                    pathlib.Path(config.browser_app),
                    browser_executable,
                    config.bundle_identifier,
                )
                after = dependencies.browser_process_identity(identity.pid)
                return after.generation_key == identity.generation_key

            def sequence_terminate(identity):
                browser_termination_attempts.add(identity.generation_key)
                return dependencies.browser_process_terminator(
                    identity,
                    browser_executable,
                    time.monotonic() + BROWSER_CLEANUP_GRACE_SECONDS,
                )

            _run_three_state_controller(
                requests=config.sequence_requests,
                route=perform_route,
                snapshot=sequence_snapshot,
                attest=sequence_attest,
                terminate=sequence_terminate,
                monotonic=dependencies.quiescence_monotonic,
                sleep=dependencies.quiescence_sleep,
            )
            final_proof = state_proofs[-1][2]
        else:
            perform_route(config.state, config.request_nonce)
            final_proof = state_proofs[-1][2]
        outcome = final_proof.outcome
        received = final_proof.token_received
        status_line = final_proof.status_line
        exact_browser_identity = final_proof.exact_browser_identity
        launch_provenance = final_proof.launch_provenance
        exit_code = (
            DRIVER_SUCCESS if outcome == "selected" else DRIVER_SELECTION_REJECTED
        )
    except _ReceiptTimeout as error:
        outcome = "receipt-timeout"
        received = error.token_received
        status_line = error.status_line
        exact_browser_identity = error.browser_identity
        owned_browsers.update(error.owned_browsers)
        launch_provenance = error.launch_provenance
        exit_code = DRIVER_RECEIPT_TIMEOUT
    except _BrowserIdentityTimeout as error:
        outcome = "browser-identity-timeout"
        received = error.token_received
        status_line = error.status_line
        exact_browser_identity = error.browser_identity
        owned_browsers.update(error.owned_browsers)
        launch_provenance = error.launch_provenance
        exit_code = DRIVER_BROWSER_IDENTITY_TIMEOUT
    except _HelperExitTimeout as error:
        outcome = "helper-exit-timeout"
        received = error.token_received
        status_line = error.status_line
        exact_browser_identity = error.browser_identity
        owned_browsers.update(error.owned_browsers)
        launch_provenance = error.launch_provenance
        exit_code = DRIVER_HELPER_FAILURE
    except _StateSequenceError:
        if (
            state_proofs
            and state_proofs[-1][2].outcome == "launch-error"
            and state_proofs[-1][2].launch_provenance in {"none", "launch-error"}
        ):
            outcome = "launch-error"
            launch_provenance = state_proofs[-1][2].launch_provenance
            exit_code = DRIVER_SELECTION_REJECTED
        else:
            outcome = "state-sequence-error"
            exit_code = DRIVER_BROWSER_IDENTITY_AMBIGUOUS
        exact_browser_identity = False
    except _IdentityAmbiguous as error:
        outcome = "identity-ambiguous"
        received = error.token_received
        status_line = error.status_line
        exact_browser_identity = False
        owned_browsers.clear()
        identity_ambiguous = True
        exit_code = DRIVER_BROWSER_IDENTITY_AMBIGUOUS
    except _IdentityInspectionError:
        outcome = "identity-inspection-error"
        exact_browser_identity = False
        owned_browsers.clear()
        identity_inspection_failed = True
        exit_code = DRIVER_IDENTITY_FAILURE
    except _DeadlineExpired:
        outcome = "timeout"
        exit_code = DRIVER_TIMEOUT
    except _StatusProtocolError as error:
        outcome = "invalid-status"
        received = error.token_received
        status_line = error.status_line
        exact_browser_identity = error.browser_identity
        owned_browsers.update(error.owned_browsers)
        exit_code = DRIVER_INVALID_STATUS
    except _ReceiptProtocolError as error:
        outcome = "invalid-receipt"
        received = error.token_received
        status_line = error.status_line
        exact_browser_identity = error.browser_identity
        owned_browsers.update(error.owned_browsers)
        exit_code = DRIVER_INVALID_RECEIPT
    except _ProvenanceProtocolError as error:
        outcome = "provenance-error"
        launch_provenance = "invalid"
        received = error.token_received
        status_line = error.status_line
        exact_browser_identity = error.browser_identity
        owned_browsers.clear()
        exit_code = DRIVER_PROVENANCE_FAILURE
    except _ReadinessError:
        outcome = "readiness-error"
        exit_code = DRIVER_READINESS_FAILURE
    except _HelperError as error:
        outcome = "helper-error"
        received = error.token_received
        status_line = error.status_line
        exact_browser_identity = error.browser_identity
        owned_browsers.update(error.owned_browsers)
        exit_code = DRIVER_HELPER_FAILURE
    except _IdentityError:
        outcome = "identity-error"
        exit_code = DRIVER_IDENTITY_FAILURE
    except _ProtocolError:
        outcome = "process-error"
        exit_code = DRIVER_PROCESS_ERROR
    except ChildProcessError:
        outcome = "process-error"
        exit_code = DRIVER_PROCESS_ERROR
    except (_DriverInterrupted, OSError, ValueError, TypeError):
        outcome = "driver-error"
        exit_code = DRIVER_PROCESS_ERROR
    finally:
        signal_guard.begin_cleanup()
        if task_root is None:
            task_root = task_root_owner.root
        browser_cleanup_deadline = time.monotonic() + BROWSER_CLEANUP_GRACE_SECONDS
        browser_cleanup_safe = not identity_inspection_failed
        if app is not None:
            cleanup_ok = processes.stop(app) and cleanup_ok
            if browser_cleanup_safe:
                try:
                    current = _authoritative_browser_snapshot(
                        dependencies,
                        browser_executable,
                        "cleanup-sweep",
                    )
                    _accumulate_browser_generations(
                        current,
                        preexisting_browsers,
                        observed_browsers,
                    )
                except _IdentityAmbiguous:
                    identity_ambiguous = True
                except (_IdentityInspectionError, OSError, ValueError, TypeError):
                    cleanup_ok = False
                    browser_cleanup_safe = False
        for identity in list(owned_browsers):
            if not browser_cleanup_safe or identity_ambiguous:
                break
            try:
                current = _authoritative_browser_snapshot(
                    dependencies,
                    browser_executable,
                    "pre-terminate",
                )
                _accumulate_browser_generations(
                    current,
                    preexisting_browsers,
                    observed_browsers,
                )
                is_same_generation = any(
                    candidate.generation_key == identity.generation_key
                    for candidate in current
                )
                if not is_same_generation:
                    continue
                if identity.generation_key in browser_termination_attempts:
                    cleanup_ok = False
                    continue
                browser_termination_attempts.add(identity.generation_key)
                terminated = dependencies.browser_process_terminator(
                    identity,
                    browser_executable,
                    browser_cleanup_deadline,
                )
                current = _authoritative_browser_snapshot(
                    dependencies,
                    browser_executable,
                    "post-terminate",
                )
                _accumulate_browser_generations(
                    current,
                    preexisting_browsers,
                    observed_browsers,
                )
                survived = any(
                    candidate.generation_key == identity.generation_key
                    for candidate in current
                )
                cleanup_ok = terminated and not survived and cleanup_ok
            except _IdentityAmbiguous:
                identity_ambiguous = True
            except (_IdentityInspectionError, OSError, ValueError, TypeError):
                cleanup_ok = False
                browser_cleanup_safe = False
        if fifo_descriptor is not None:
            try:
                cleanup_ok = dependencies.fifo_closer(fifo_descriptor) and cleanup_ok
            except Exception:
                cleanup_ok = False
        if provenance_descriptor is not None:
            try:
                cleanup_ok = (
                    dependencies.fifo_closer(provenance_descriptor) and cleanup_ok
                )
            except Exception:
                cleanup_ok = False
        try:
            cleanup_ok = processes.close() and cleanup_ok
        except Exception:
            cleanup_ok = False
        if baseline_authoritative and route_delivery_attempted:
            try:
                final_current = _authoritative_browser_snapshot(
                    dependencies,
                    browser_executable,
                    "final-sweep",
                )
                final_new = _accumulate_browser_generations(
                    final_current,
                    preexisting_browsers,
                    observed_browsers,
                )
                if final_new:
                    cleanup_ok = False
            except _IdentityAmbiguous:
                identity_ambiguous = True
            except (_IdentityInspectionError, OSError, ValueError, TypeError):
                cleanup_ok = False
                browser_cleanup_safe = False
            try:
                late_generation_seen = _observe_browser_quiescence(
                    dependencies,
                    browser_executable,
                    preexisting_browsers,
                    observed_browsers,
                )
                if late_generation_seen:
                    cleanup_ok = False
            except _IdentityAmbiguous:
                identity_ambiguous = True
            except (_IdentityInspectionError, OSError, ValueError, TypeError):
                cleanup_ok = False
                browser_cleanup_safe = False
        for route_bytes in route_payloads:
            try:
                output_violation = processes.violates_privacy(route_bytes)
            except Exception:
                output_violation = True
            if output_violation:
                outcome = "privacy-failure"
                exit_code = DRIVER_PRIVACY_FAILURE
            try:
                files_are_private = task_root is None or task_root.audit_regular_files(
                    route_bytes
                )
            except Exception:
                files_are_private = False
            if not files_are_private:
                outcome = "privacy-failure"
                exit_code = DRIVER_PRIVACY_FAILURE
        if task_root is not None:
            try:
                dependencies.before_cleanup(task_root.require_current())
            except Exception:
                cleanup_ok = False
            try:
                task_root_finalized = dependencies.task_root_remover(task_root)
                cleanup_ok = task_root_finalized and cleanup_ok
            except Exception:
                cleanup_ok = False
            finally:
                task_root.close()
        if identity_ambiguous:
            outcome = "identity-ambiguous"
            exact_browser_identity = False
            exit_code = DRIVER_BROWSER_IDENTITY_AMBIGUOUS
        elif signal_guard.received_during_cleanup:
            outcome = "cleanup-interrupted"
            exit_code = DRIVER_CLEANUP_FAILURE
        elif not cleanup_ok and exit_code not in {
            DRIVER_INVALID_STATUS,
            DRIVER_INVALID_RECEIPT,
            DRIVER_HELPER_FAILURE,
            DRIVER_PROVENANCE_FAILURE,
        }:
            outcome = "cleanup-error"
            exit_code = DRIVER_CLEANUP_FAILURE
        signal_guard.restore()

    total_elapsed = max(dependencies.monotonic() - started, 0.0)
    state_proof_reports = []
    for state, request, proof, identity, route_elapsed in state_proofs:
        state_proof_reports.append(
            {
                "state": state,
                "request": request,
                "outcome": proof.outcome,
                "receipt": proof.token_received,
                "e2eIdentity": True,
                "browserIdentity": proof.exact_browser_identity,
                "provenance": proof.launch_provenance,
                "processIdentifier": identity.pid if identity is not None else None,
                "processStartSeconds": (
                    identity.start_seconds if identity is not None else None
                ),
                "processStartMicroseconds": (
                    identity.start_microseconds if identity is not None else None
                ),
                "routeElapsedSeconds": round(route_elapsed, 6),
            }
        )
    report = {
        "schemaVersion": 1,
        "session": config.session_nonce,
        "request": config.request_nonce,
        "bundleIdentifier": config.bundle_identifier,
        "targetID": target_id,
        "capability": config.capability,
        "state": config.state,
        "mode": config.mode,
        "mechanism": config.expected_mechanism,
        "e2eAppIdentity": config.e2e_app_identity,
        "browserAppIdentity": config.browser_app_identity,
        "outcome": outcome,
        "token_received": received,
        "exact_process_identity": exact_e2e_identity,
        "exact_browser_process_identity": exact_browser_identity,
        "launch_provenance": launch_provenance,
        "total_elapsed_seconds": round(total_elapsed, 6),
        "route_timeout_seconds": round(timeout, 6),
        "browser_cleanup_grace_seconds": BROWSER_CLEANUP_GRACE_SECONDS,
        "browser_quiescence_seconds": BROWSER_QUIESCENCE_SECONDS,
        "provenance_settle_seconds": PROVENANCE_SETTLE_SECONDS,
        "provenance_status_grace_seconds": PROVENANCE_STATUS_GRACE_SECONDS,
        "cleanup_success": cleanup_ok
        and task_root_finalized
        and not identity_ambiguous
        and not identity_inspection_failed,
        "task_root_finalized": task_root_finalized,
        "stateProofs": state_proof_reports,
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
    parser.add_argument(
        "--mechanism",
        choices=("process", "workspace", "duckduckgo"),
        required=True,
    )
    parser.add_argument("--session", required=True)
    parser.add_argument("--request", default=secrets.token_hex(16))
    parser.add_argument(
        "--capability",
        choices=("normal", "private", "profile", "profile-private"),
        default="normal",
    )
    parser.add_argument(
        "--state", choices=("cold", "running", "reopen", "sequence"), default="cold"
    )
    parser.add_argument("--e2e-app-identity", default="0" * 64)
    parser.add_argument("--browser-app-identity", default="0" * 64)
    parser.add_argument("--sequence-request", action="append", default=[])
    parser.add_argument("--timeout", type=float, default=30.0)
    parser.add_argument("--route-count", type=int, default=1)
    parser.add_argument("--profile-strategy", choices=("chromium", "firefox"))
    parser.add_argument("--profile-relative-root")
    parser.add_argument("--create-profile", action="store_true")
    parser.add_argument("--derive-profile-target", action="store_true")
    arguments = parser.parse_args(argv)
    result = run_driver(
        DriverConfig(
            e2e_app=arguments.e2e_app,
            browser_app=arguments.browser_app,
            expected_browser_executable=arguments.expected_browser_executable,
            target_id=arguments.target_id,
            bundle_identifier=arguments.bundle_id,
            mode=arguments.mode,
            expected_mechanism=arguments.mechanism,
            session_nonce=arguments.session,
            timeout=arguments.timeout,
            route_count=arguments.route_count,
            profile_strategy=arguments.profile_strategy,
            profile_relative_root=arguments.profile_relative_root,
            create_profile=arguments.create_profile,
            derive_profile_target=arguments.derive_profile_target,
            request_nonce=arguments.request,
            capability=arguments.capability,
            state=arguments.state,
            e2e_app_identity=arguments.e2e_app_identity,
            browser_app_identity=arguments.browser_app_identity,
            sequence_requests=tuple(arguments.sequence_request),
        )
    )
    sys.stdout.buffer.write(result.stdout)
    sys.stdout.buffer.flush()
    return result.exit_code


if __name__ == "__main__":
    raise SystemExit(main())
