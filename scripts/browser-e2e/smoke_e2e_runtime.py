#!/usr/bin/env python3

import argparse
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


class PinnedApplication:
    def __init__(self, path, directory_fd, executable_fd, directory_stat, executable_stat):
        self.path = path
        self.directory_fd = directory_fd
        self.executable_fd = executable_fd
        self.directory_stat = directory_stat
        self.executable_stat = executable_stat
        self.executable = path / "Contents" / "MacOS" / "PickVia"

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
            pinned = cls(
                physical,
                directory_fd,
                executable_fd,
                directory_stat,
                executable_stat,
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
            )
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
        poll,
        wait,
    ):
        self.process = process
        self.pid = process.pid if process is not None else None
        self.expected_identity = expected_identity
        self._identity = identity
        self._signal_group = signal_group
        self._process_group = process_group
        self._poll = poll
        self._wait = wait

    @classmethod
    def start(cls, arguments, *, environment, stdin=subprocess.DEVNULL):
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
        deadline = time.monotonic() + 0.5
        while expected_identity is None and time.monotonic() < deadline:
            current_identity = driver._darwin_process_identity(process.pid)
            if current_identity is not None and current_identity == previous_identity:
                expected_identity = current_identity
                break
            previous_identity = current_identity
            if process.poll() is not None:
                break
            time.sleep(0.005)
        if expected_identity is None:
            try:
                process.terminate()
                process.wait(timeout=0.5)
            except (ProcessLookupError, subprocess.TimeoutExpired):
                try:
                    process.kill()
                except ProcessLookupError:
                    pass
            raise SmokePolicyError("child identity could not be pinned")
        return cls(
            process,
            expected_identity,
            driver._darwin_process_identity,
            os.killpg,
            os.getpgid,
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
    ):
        instance = cls(
            None,
            expected_identity,
            identity,
            signal_group,
            process_group,
            poll,
            wait,
        )
        instance.pid = pid
        return instance

    def _is_exact_generation(self):
        try:
            return (
                self._poll() is None
                and self._process_group(self.pid) == self.pid
                and self._identity(self.pid) == self.expected_identity
            )
        except (OSError, ProcessLookupError):
            return False

    def _wait_bounded(self, timeout):
        deadline = time.monotonic() + timeout
        try:
            self._wait(timeout)
        except subprocess.TimeoutExpired:
            return False
        while time.monotonic() < deadline:
            if self._group_is_absent():
                return True
            time.sleep(0.01)
        return self._group_is_absent()

    def _group_is_absent(self):
        try:
            self._signal_group(self.pid, 0)
            return False
        except (OSError, ProcessLookupError):
            return True

    def terminate_bounded(self, *, term_timeout, kill_timeout):
        if self._poll() is not None:
            return self._group_is_absent()
        if not self._is_exact_generation():
            return False
        self._signal_group(self.pid, signal.SIGTERM)
        if self._wait_bounded(term_timeout):
            return True
        if not self._is_exact_generation():
            return False
        self._signal_group(self.pid, signal.SIGKILL)
        return self._wait_bounded(kill_timeout)

    def wait_success(self, timeout):
        deadline = time.monotonic() + timeout
        try:
            return_code = self._wait(timeout)
        except subprocess.TimeoutExpired:
            return False
        while time.monotonic() < deadline:
            if self._group_is_absent():
                return return_code == 0
            time.sleep(0.01)
        return False

    def close_streams(self):
        if self.process is None:
            return
        for stream in (self.process.stdin, self.process.stdout, self.process.stderr):
            if stream is not None and not stream.closed:
                stream.close()


def _main(arguments=None):
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
