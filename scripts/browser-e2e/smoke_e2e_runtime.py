#!/usr/bin/env python3

import argparse
import ctypes
import hashlib
import os
import pathlib
import signal
import stat
import subprocess
import time

import pickvia_e2e_driver as driver


class SmokePolicyError(RuntimeError):
    pass


_ALLOWED_POLICY_ENVIRONMENT_KEYS = frozenset(
    {
        "PATH",
        "LANG",
        "LC_CTYPE",
        "TMPDIR",
        "CFFIXED_USER_HOME",
        "PYTHONDONTWRITEBYTECODE",
        "__CF_USER_TEXT_ENCODING",
        "SDKROOT",
        "CPATH",
        "LIBRARY_PATH",
        "MANPATH",
    }
)


def _reject_symlink_components(path):
    current = pathlib.Path(path.anchor)
    for component in path.parts[1:]:
        current /= component
        if current.is_symlink():
            raise SmokePolicyError("symlinked path component")


def _same_stat(left, right):
    return (left.st_dev, left.st_ino, left.st_mode) == (
        right.st_dev,
        right.st_ino,
        right.st_mode,
    )


def _darwin_process_group_snapshot(process_group):
    library = driver._load_libproc()
    required_bytes = library.proc_listpids(4, os.getuid(), None, 0)
    if required_bytes <= 0:
        raise SmokePolicyError("process group inspection failed")
    count = required_bytes // ctypes.sizeof(ctypes.c_int) + 128
    pids = (ctypes.c_int * count)()
    used_bytes = library.proc_listpids(4, os.getuid(), pids, ctypes.sizeof(pids))
    if used_bytes <= 0 or used_bytes >= ctypes.sizeof(pids):
        raise SmokePolicyError("process group inspection failed")
    identities = set()
    for process_identifier in pids[: used_bytes // ctypes.sizeof(ctypes.c_int)]:
        if process_identifier <= 0:
            continue
        information = driver._ProcBSDInfo()
        if library.proc_pidinfo(
            process_identifier,
            3,
            0,
            ctypes.byref(information),
            ctypes.sizeof(information),
        ) != ctypes.sizeof(information):
            continue
        if int(information.pbi_pgid) != process_group:
            continue
        try:
            identities.add(driver._darwin_process_identity(process_identifier, library))
        except (driver._ProcessDisappeared, driver._IdentityInspectionError):
            continue
    return frozenset(identities)


class PinnedApplication:
    bundle_directories = {
        "": {"Contents": "directory"},
        "Contents": {
            "Info.plist": "file",
            "MacOS": "directory",
            "Resources": "directory",
            "_CodeSignature": "directory",
        },
        "Contents/MacOS": {"PickVia": "file"},
        "Contents/Resources": {
            "PickVia.icns": "file",
            "PickViaMenuBarTemplate.png": "file",
        },
        "Contents/_CodeSignature": {"CodeResources": "file"},
    }
    maximum_bundle_bytes = 64 * 1_024 * 1_024

    def __init__(
        self,
        path,
        directory_fd,
        executable_fd,
        directory_stat,
        executable_stat,
        bundle_manifest,
    ):
        self.path = path
        self.directory_fd = directory_fd
        self.executable_fd = executable_fd
        self.directory_stat = directory_stat
        self.executable_stat = executable_stat
        self.executable = path / "Contents" / "MacOS" / "PickVia"
        self.bundle_manifest = bundle_manifest

    @classmethod
    def _open_directory(cls, root_fd, relative):
        descriptor = os.dup(root_fd)
        try:
            for component in pathlib.PurePosixPath(relative).parts:
                if not component or component == ".":
                    continue
                child = os.open(
                    component,
                    os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW,
                    dir_fd=descriptor,
                )
                os.close(descriptor)
                descriptor = child
            return descriptor
        except Exception:
            os.close(descriptor)
            raise

    @classmethod
    def _capture_bundle_manifest(cls, root_fd):
        records = []
        total_bytes = 0
        for relative_directory, expected_entries in cls.bundle_directories.items():
            directory_fd = cls._open_directory(root_fd, relative_directory)
            try:
                directory_stat = os.fstat(directory_fd)
                if not stat.S_ISDIR(directory_stat.st_mode):
                    raise SmokePolicyError("bundle directory is invalid")
                names = set(os.listdir(directory_fd))
                if names != set(expected_entries):
                    raise SmokePolicyError("bundle contains unexpected entries")
                records.append(
                    (
                        relative_directory,
                        "directory",
                        directory_stat.st_dev,
                        directory_stat.st_ino,
                        directory_stat.st_mode,
                        directory_stat.st_ctime_ns,
                    )
                )
                for name, expected_kind in sorted(expected_entries.items()):
                    named = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
                    if expected_kind == "directory":
                        if not stat.S_ISDIR(named.st_mode):
                            raise SmokePolicyError("bundle directory entry is invalid")
                        continue
                    descriptor = os.open(
                        name,
                        os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW,
                        dir_fd=directory_fd,
                    )
                    try:
                        before = os.fstat(descriptor)
                        if not stat.S_ISREG(before.st_mode):
                            raise SmokePolicyError("bundle file entry is invalid")
                        total_bytes += before.st_size
                        if total_bytes > cls.maximum_bundle_bytes:
                            raise SmokePolicyError("bundle byte budget exceeded")
                        contents = bytearray()
                        while len(contents) < before.st_size:
                            chunk = os.read(descriptor, min(65_536, before.st_size - len(contents)))
                            if not chunk:
                                break
                            contents.extend(chunk)
                        after = os.fstat(descriptor)
                        current = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
                        fields = (
                            "st_dev",
                            "st_ino",
                            "st_mode",
                            "st_size",
                            "st_mtime_ns",
                            "st_ctime_ns",
                        )
                        if len(contents) != before.st_size or any(
                            getattr(before, field) != getattr(after, field) for field in fields
                        ):
                            raise SmokePolicyError("bundle file changed during read")
                        if not _same_stat(after, current):
                            raise SmokePolicyError("bundle file path was replaced")
                        records.append(
                            (
                                f"{relative_directory}/{name}".lstrip("/"),
                                "file",
                                *(getattr(before, field) for field in fields),
                                hashlib.sha256(contents).hexdigest(),
                            )
                        )
                    finally:
                        os.close(descriptor)
            finally:
                os.close(directory_fd)
        return tuple(records)

    @classmethod
    def open(cls, application):
        candidate = pathlib.Path(application)
        if not candidate.is_absolute():
            candidate = pathlib.Path.cwd() / candidate
        candidate = pathlib.Path(os.path.normpath(candidate))
        _reject_symlink_components(candidate)
        try:
            physical = candidate.resolve(strict=True)
        except OSError as error:
            raise SmokePolicyError("application is unavailable") from error
        if physical != candidate or physical.suffix.lower() != ".app":
            raise SmokePolicyError("application path is not canonical")

        directory_fd = -1
        executable_fd = -1
        try:
            directory_fd = os.open(
                physical,
                os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW,
            )
            directory_stat = os.fstat(directory_fd)
            executable = physical / "Contents" / "MacOS" / "PickVia"
            _reject_symlink_components(executable)
            executable_fd = os.open(
                executable, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW
            )
            executable_stat = os.fstat(executable_fd)
            if not stat.S_ISDIR(directory_stat.st_mode) or not stat.S_ISREG(
                executable_stat.st_mode
            ):
                raise SmokePolicyError("application identity is invalid")
            if executable_stat.st_mode & 0o111 == 0:
                raise SmokePolicyError("application executable is not executable")
            bundle_manifest = cls._capture_bundle_manifest(directory_fd)
            pinned = cls(
                physical,
                directory_fd,
                executable_fd,
                directory_stat,
                executable_stat,
                bundle_manifest,
            )
            directory_fd = -1
            executable_fd = -1
            if not pinned.validate():
                raise SmokePolicyError("application identity changed while pinning")
            return pinned
        except OSError as error:
            raise SmokePolicyError("application could not be pinned") from error
        finally:
            if executable_fd >= 0:
                os.close(executable_fd)
            if directory_fd >= 0:
                os.close(directory_fd)

    def validate(self):
        try:
            if self.path.is_symlink() or self.executable.is_symlink():
                return False
            if self.path.resolve(strict=True) != self.path:
                return False
            return _same_stat(os.fstat(self.directory_fd), self.directory_stat) and _same_stat(
                os.stat(self.path, follow_symlinks=False), self.directory_stat
            ) and _same_stat(os.fstat(self.executable_fd), self.executable_stat) and _same_stat(
                os.stat(self.executable, follow_symlinks=False), self.executable_stat
            ) and self._capture_bundle_manifest(self.directory_fd) == self.bundle_manifest
        except OSError:
            return False

    def close(self):
        for descriptor in (self.executable_fd, self.directory_fd):
            if descriptor >= 0:
                os.close(descriptor)
        self.executable_fd = -1
        self.directory_fd = -1


class PreferenceDirectorySnapshot:
    prefix = "dev.bozhenpeng.PickVia.E2E"

    def __init__(self, preferences_path, directories, after_open):
        self.preferences_path = preferences_path
        self.directories = directories
        self.after_open = after_open

    @classmethod
    def open(cls, home, after_open=lambda directory_name, name: None):
        home_path = pathlib.Path(home)
        if not home_path.is_absolute():
            home_path = pathlib.Path.cwd() / home_path
        preferences = pathlib.Path(os.path.normpath(home_path)) / "Library" / "Preferences"
        _reject_symlink_components(preferences)
        directories = []
        try:
            preferences_fd = os.open(
                preferences,
                os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW,
            )
            directories.append(
                ("Preferences", preferences, preferences_fd, os.fstat(preferences_fd))
            )
            try:
                by_host_fd = os.open(
                    "ByHost",
                    os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW,
                    dir_fd=preferences_fd,
                )
            except FileNotFoundError:
                by_host_fd = -1
            if by_host_fd >= 0:
                directories.append(
                    (
                        "ByHost",
                        preferences / "ByHost",
                        by_host_fd,
                        os.fstat(by_host_fd),
                    )
                )
            snapshot = cls(preferences, directories, after_open)
            if not snapshot.validate_directories():
                raise SmokePolicyError("preference directory identity changed while pinning")
            return snapshot
        except (OSError, SmokePolicyError) as error:
            for _, _, descriptor, _ in directories:
                os.close(descriptor)
            if isinstance(error, SmokePolicyError):
                raise
            raise SmokePolicyError("preference directories could not be pinned") from error

    def validate_directories(self):
        for _, path, descriptor, expected in self.directories:
            try:
                current = os.stat(path, follow_symlinks=False)
                if path.is_symlink() or not _same_stat(os.fstat(descriptor), expected):
                    return False
                if not _same_stat(current, expected) or not stat.S_ISDIR(current.st_mode):
                    return False
            except OSError:
                return False
        return True

    def capture(self):
        if not self.validate_directories():
            raise SmokePolicyError("preference directory identity changed")
        records = []
        for directory_name, _, directory_fd, _ in self.directories:
            for name in sorted(os.listdir(directory_fd)):
                if not name.startswith(self.prefix):
                    continue
                descriptor = -1
                try:
                    descriptor = os.open(
                        name,
                        os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW,
                        dir_fd=directory_fd,
                    )
                    before = os.fstat(descriptor)
                    if not stat.S_ISREG(before.st_mode):
                        raise SmokePolicyError("unsafe preference artifact")
                    self.after_open(directory_name, name)
                    contents = bytearray()
                    while True:
                        chunk = os.read(descriptor, 65_536)
                        if not chunk:
                            break
                        contents.extend(chunk)
                    after = os.fstat(descriptor)
                    named = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
                    stable_fields = (
                        "st_dev",
                        "st_ino",
                        "st_mode",
                        "st_size",
                        "st_mtime_ns",
                        "st_ctime_ns",
                    )
                    if any(getattr(before, field) != getattr(after, field) for field in stable_fields):
                        raise SmokePolicyError("preference artifact changed during read")
                    if not _same_stat(after, named):
                        raise SmokePolicyError("preference artifact path was replaced")
                    records.append(
                        (
                            directory_name,
                            name,
                            before.st_dev,
                            before.st_ino,
                            before.st_mode,
                            before.st_size,
                            before.st_mtime_ns,
                            before.st_ctime_ns,
                            hashlib.sha256(contents).hexdigest(),
                        )
                    )
                except OSError as error:
                    raise SmokePolicyError("preference artifact could not be read") from error
                finally:
                    if descriptor >= 0:
                        os.close(descriptor)
        if not self.validate_directories():
            raise SmokePolicyError("preference directory identity changed")
        return tuple(records)

    def close(self):
        for _, _, descriptor, _ in reversed(self.directories):
            os.close(descriptor)
        self.directories = []


class ExactProcess:
    def __init__(
        self,
        process,
        expected_identity,
        identity,
        signal_group,
        process_group,
        group_snapshot,
        poll,
        wait,
    ):
        self.process = process
        self.pid = process.pid if process is not None else None
        self.expected_identity = expected_identity
        self._identity = identity
        self._signal_group = signal_group
        self._process_group = process_group
        self._group_snapshot = group_snapshot
        self._poll = poll
        self._wait = wait

    @classmethod
    def start(
        cls,
        arguments,
        *,
        environment,
        stdin=subprocess.DEVNULL,
        identity_resolver=driver._darwin_process_identity,
        identity_timeout=0.5,
    ):
        process = subprocess.Popen(
            [os.fspath(argument) for argument in arguments],
            stdin=stdin,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env=dict(environment),
            close_fds=True,
            start_new_session=True,
        )
        expected_identity = None
        previous_identity = None
        deadline = time.monotonic() + identity_timeout
        while expected_identity is None and time.monotonic() < deadline:
            try:
                current_identity = identity_resolver(process.pid)
            except (driver._ProcessDisappeared, driver._IdentityInspectionError):
                current_identity = None
            if current_identity is not None and current_identity == previous_identity:
                expected_identity = current_identity
                break
            previous_identity = current_identity
            if process.poll() is not None:
                break
            time.sleep(0.005)
        if expected_identity is None:
            cls._cleanup_unpinned_group(process)
            raise SmokePolicyError("child identity could not be pinned")
        return cls(
            process,
            expected_identity,
            driver._darwin_process_identity,
            os.killpg,
            os.getpgid,
            _darwin_process_group_snapshot,
            process.poll,
            process.wait,
        )

    @classmethod
    def for_test(
        cls,
        *,
        pid,
        poll,
        wait,
        identity,
        signal_group,
        process_group,
        expected_identity,
        group_snapshot=None,
    ):
        instance = cls(
            None,
            expected_identity,
            identity,
            signal_group,
            process_group,
            group_snapshot,
            poll,
            wait,
        )
        instance.pid = pid
        return instance

    @staticmethod
    def _cleanup_unpinned_group(process):
        process_group = process.pid
        try:
            current_group = os.getpgid(process.pid)
            if current_group != process_group:
                return False
        except ProcessLookupError:
            try:
                members = _darwin_process_group_snapshot(process_group)
            except SmokePolicyError:
                return False
            if not members or any(member.pid == process_group for member in members):
                return not members
        try:
            os.killpg(process_group, signal.SIGTERM)
        except ProcessLookupError:
            return True
        try:
            process.wait(timeout=0.5)
        except subprocess.TimeoutExpired:
            pass
        deadline = time.monotonic() + 0.5
        while time.monotonic() < deadline:
            try:
                if not _darwin_process_group_snapshot(process_group):
                    return True
            except SmokePolicyError:
                return False
            time.sleep(0.01)
        try:
            members = _darwin_process_group_snapshot(process_group)
        except SmokePolicyError:
            return False
        if not members or any(member.pid == process_group for member in members):
            return not members
        os.killpg(process_group, signal.SIGKILL)
        deadline = time.monotonic() + 0.5
        while time.monotonic() < deadline:
            if not _darwin_process_group_snapshot(process_group):
                try:
                    process.wait(timeout=0)
                except (subprocess.TimeoutExpired, ChildProcessError):
                    pass
                return True
            time.sleep(0.01)
        return False

    def _group_state(self):
        if self._group_snapshot is None:
            try:
                if self._poll() is not None:
                    return "absent" if self._group_is_absent_fallback() else "ambiguous"
                if self._process_group(self.pid) != self.pid:
                    return "ambiguous"
                return (
                    "owned"
                    if self._identity(self.pid) == self.expected_identity
                    else "ambiguous"
                )
            except (OSError, ProcessLookupError):
                return "ambiguous"
        try:
            members = self._group_snapshot(self.pid)
        except (OSError, SmokePolicyError):
            return "ambiguous"
        if not members:
            return "absent"
        expected_start = (
            self.expected_identity.start_seconds,
            self.expected_identity.start_microseconds,
        )
        for member in members:
            member_start = (member.start_seconds, member.start_microseconds)
            if member.pid == self.pid and member != self.expected_identity:
                return "ambiguous"
            if member_start < expected_start:
                return "ambiguous"
        return "owned"

    def _group_is_absent_fallback(self):
        try:
            self._signal_group(self.pid, 0)
            return False
        except (OSError, ProcessLookupError):
            return True

    def _wait_for_group_absence(self, timeout):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            state = self._group_state()
            if state == "absent":
                try:
                    self._wait(0)
                except (subprocess.TimeoutExpired, ChildProcessError):
                    pass
                return True
            if state != "owned":
                return False
            time.sleep(0.01)
        return self._group_state() == "absent"

    def terminate_bounded(self, *, term_timeout, kill_timeout):
        state = self._group_state()
        if state == "absent":
            return True
        if state != "owned":
            return False
        self._signal_group(self.pid, signal.SIGTERM)
        if self._wait_for_group_absence(term_timeout):
            return True
        if self._group_state() != "owned":
            return False
        self._signal_group(self.pid, signal.SIGKILL)
        return self._wait_for_group_absence(kill_timeout)

    def wait_success(self, timeout):
        deadline = time.monotonic() + timeout
        try:
            return_code = self._wait(timeout)
        except subprocess.TimeoutExpired:
            return False
        return return_code == 0 and self._wait_for_group_absence(
            max(0, deadline - time.monotonic())
        )

    def close_streams(self):
        if self.process is None:
            return
        for stream in (self.process.stdin, self.process.stdout, self.process.stderr):
            if stream is not None and not stream.closed:
                stream.close()


def _main(arguments=None):
    if not set(os.environ).issubset(_ALLOWED_POLICY_ENVIRONMENT_KEYS):
        return 1
    parser = argparse.ArgumentParser(add_help=False)
    subparsers = parser.add_subparsers(dest="command", required=True)
    canonical = subparsers.add_parser("canonical-app", add_help=False)
    canonical.add_argument("application")
    app_identity = subparsers.add_parser("app-identity", add_help=False)
    app_identity.add_argument("application")
    snapshot = subparsers.add_parser("snapshot-preferences", add_help=False)
    snapshot.add_argument("home")
    compile_helper = subparsers.add_parser("compile-helper", add_help=False)
    compile_helper.add_argument("source")
    compile_helper.add_argument("output")
    compile_helper.add_argument("runtime_root")
    run_helper = subparsers.add_parser("run-helper", add_help=False)
    run_helper.add_argument("helper")
    run_helper.add_argument("application")
    run_helper.add_argument("process_identifier", type=int)
    run_helper.add_argument("runtime_root")
    process_identity = subparsers.add_parser("process-identity", add_help=False)
    process_identity.add_argument("process_identifier", type=int)
    process_identity.add_argument("expected_executable")
    verify_app = subparsers.add_parser("verify-app", add_help=False)
    verify_app.add_argument("application")
    try:
        options = parser.parse_args(arguments)
        if options.command in ("canonical-app", "app-identity"):
            pinned = PinnedApplication.open(options.application)
            try:
                if options.command == "canonical-app":
                    print(pinned.path)
                else:
                    fields = (
                        pinned.path,
                        pinned.directory_stat.st_dev,
                        pinned.directory_stat.st_ino,
                        pinned.directory_stat.st_ctime_ns,
                        pinned.executable_stat.st_dev,
                        pinned.executable_stat.st_ino,
                        pinned.executable_stat.st_size,
                        pinned.executable_stat.st_mtime_ns,
                        pinned.executable_stat.st_ctime_ns,
                        pinned.bundle_manifest,
                    )
                    print(hashlib.sha256(repr(fields).encode("utf-8")).hexdigest())
            finally:
                pinned.close()
            return 0
        if options.command == "compile-helper":
            environment = {
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "LANG": "en_US.UTF-8",
                "LC_CTYPE": "UTF-8",
                "TMPDIR": options.runtime_root,
                "CFFIXED_USER_HOME": options.runtime_root,
            }
            compiler = ExactProcess.start(
                [
                    "/usr/bin/xcrun",
                    "--sdk",
                    "macosx",
                    "swiftc",
                    "-swift-version",
                    "6",
                    "-warnings-as-errors",
                    options.source,
                    "-o",
                    options.output,
                ],
                environment=environment,
            )
            try:
                if not compiler.wait_success(30):
                    compiler.terminate_bounded(term_timeout=2, kill_timeout=2)
                    return 1
            finally:
                compiler.close_streams()
            return 0
        if options.command == "run-helper":
            environment = {
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "LANG": "en_US.UTF-8",
                "LC_CTYPE": "UTF-8",
                "TMPDIR": options.runtime_root,
                "CFFIXED_USER_HOME": options.runtime_root,
            }
            helper = ExactProcess.start(
                [options.helper, options.application, str(options.process_identifier)],
                environment=environment,
                stdin=subprocess.PIPE,
            )
            try:
                helper.process.stdin.write(b"https://127.0.0.1/pickvia-e2e-smoke")
                helper.process.stdin.close()
                if not helper.wait_success(10):
                    helper.terminate_bounded(term_timeout=2, kill_timeout=2)
                    return 1
            finally:
                helper.close_streams()
            return 0
        if options.command == "process-identity":
            identity = driver._darwin_process_identity(options.process_identifier)
            expected = pathlib.Path(options.expected_executable).resolve(strict=True)
            if identity is None or identity.executable.resolve(strict=True) != expected:
                return 1
            fields = (
                identity.pid,
                identity.parent_pid,
                identity.start_seconds,
                identity.start_microseconds,
                identity.executable,
            )
            print(hashlib.sha256(repr(fields).encode("utf-8")).hexdigest())
            return 0
        if options.command == "verify-app":
            pinned = PinnedApplication.open(options.application)
            verifier = None
            try:
                verifier = ExactProcess.start(
                    [
                        "/usr/bin/codesign",
                        "--verify",
                        "--deep",
                        "--strict",
                        pinned.path,
                    ],
                    environment={
                        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                        "LANG": "en_US.UTF-8",
                        "LC_CTYPE": "UTF-8",
                    },
                )
                return 0 if verifier.wait_success(5) and pinned.validate() else 1
            finally:
                if verifier is not None:
                    if verifier._group_state() == "owned":
                        verifier.terminate_bounded(term_timeout=1, kill_timeout=1)
                    verifier.close_streams()
                pinned.close()
        preferences = PreferenceDirectorySnapshot.open(options.home)
        try:
            records = preferences.capture()
            directories = tuple(
                (name, metadata.st_dev, metadata.st_ino, metadata.st_mode)
                for name, _, _, metadata in preferences.directories
            )
            digest = hashlib.sha256(repr((directories, records)).encode("utf-8")).hexdigest()
            print(digest)
        finally:
            preferences.close()
        return 0
    except (OSError, SmokePolicyError, SystemExit):
        return 1


if __name__ == "__main__":
    raise SystemExit(_main())
