#!/usr/bin/env python3

import argparse
import hashlib
import json
import os
import pathlib
import plistlib
import re
import stat
import sys
import time

import smoke_e2e_runtime
import pickvia_e2e_driver as browser_driver


_PROFILE_NAME = "PickVia E2E"
_BUNDLE_IDENTIFIER = re.compile(r"\A[A-Za-z0-9][A-Za-z0-9.-]{2,254}\Z")
_MAXIMUM_PLIST_BYTES = 64 * 1024
_MAXIMUM_LOCAL_STATE_BYTES = 1024 * 1024
_MAXIMUM_EXECUTABLE_BYTES = 512 * 1024 * 1024
_CREATE_TIMEOUT_SECONDS = 5.0
_SHUTDOWN_TIMEOUT_SECONDS = 2.0


class SyntheticProfileError(RuntimeError):
    pass


class SyntheticProfileArgumentError(SyntheticProfileError):
    pass


class _SanitizedArgumentParser(argparse.ArgumentParser):
    def error(self, _message):
        raise SyntheticProfileArgumentError("invalid arguments")


class _PinnedRoot:
    def __init__(self, path, descriptor, identity):
        self.path = path
        self.descriptor = descriptor
        self.identity = identity

    def require_current(self):
        if self.descriptor < 0:
            raise SyntheticProfileError("invalid root")
        try:
            opened = os.fstat(self.descriptor)
            named = self.path.lstat()
        except OSError as error:
            raise SyntheticProfileError("invalid root") from error
        if (
            not stat.S_ISDIR(opened.st_mode)
            or not stat.S_ISDIR(named.st_mode)
            or self._generation(opened) != self.identity
            or self._generation(named) != self.identity
            or opened.st_uid != os.getuid()
            or named.st_uid != os.getuid()
            or opened.st_mode & 0o077
            or named.st_mode & 0o077
            or self.path.resolve(strict=True) != self.path
        ):
            raise SyntheticProfileError("invalid root")
        return self.path

    def close(self):
        if self.descriptor >= 0:
            os.close(self.descriptor)
            self.descriptor = -1

    @staticmethod
    def _generation(metadata):
        return (
            metadata.st_dev,
            metadata.st_ino,
            metadata.st_uid,
            stat.S_IMODE(metadata.st_mode),
        )


class _PinnedApplication:
    def __init__(
        self,
        application,
        executable,
        bundle_identifier,
        application_descriptor,
        application_identity,
        plist_descriptor,
        plist_identity,
        plist_digest,
        executable_descriptor,
        executable_identity,
        executable_digest,
    ):
        self.application = application
        self.executable = executable
        self.bundle_identifier = bundle_identifier
        self.application_descriptor = application_descriptor
        self.application_identity = application_identity
        self.plist_path = application / "Contents" / "Info.plist"
        self.plist_descriptor = plist_descriptor
        self.plist_identity = plist_identity
        self.plist_digest = plist_digest
        self.executable_descriptor = executable_descriptor
        self.executable_identity = executable_identity
        self.executable_digest = executable_digest

    def require_current(self):
        if (
            min(
                self.application_descriptor,
                self.plist_descriptor,
                self.executable_descriptor,
            )
            < 0
        ):
            raise SyntheticProfileError("invalid application")
        try:
            application_opened = os.fstat(self.application_descriptor)
            application_named = self.application.lstat()
            if (
                not stat.S_ISDIR(application_opened.st_mode)
                or _entry_identity(application_opened) != self.application_identity
                or _entry_identity(application_named) != self.application_identity
                or self.application.resolve(strict=True) != self.application
            ):
                raise SyntheticProfileError("invalid application")
            self._require_file(
                self.plist_path,
                self.plist_descriptor,
                self.plist_identity,
                self.plist_digest,
                _MAXIMUM_PLIST_BYTES,
                executable=False,
            )
            self._require_file(
                self.executable,
                self.executable_descriptor,
                self.executable_identity,
                self.executable_digest,
                _MAXIMUM_EXECUTABLE_BYTES,
                executable=True,
            )
        except SyntheticProfileError:
            raise
        except OSError as error:
            raise SyntheticProfileError("invalid application") from error
        return self

    @staticmethod
    def _require_file(path, descriptor, identity, digest, maximum_bytes, *, executable):
        opened = os.fstat(descriptor)
        named = os.stat(path, follow_symlinks=False)
        if (
            not stat.S_ISREG(opened.st_mode)
            or _entry_identity(opened) != identity
            or _entry_identity(named) != identity
            or stat.S_ISLNK(named.st_mode)
            or path.resolve(strict=True) != path
            or (executable and opened.st_mode & 0o111 == 0)
        ):
            raise SyntheticProfileError("invalid application")
        current_digest, after = _digest_pinned_file(descriptor, maximum_bytes)
        if _entry_identity(after) != identity or current_digest != digest:
            raise SyntheticProfileError("invalid application")

    def close(self):
        for attribute in (
            "executable_descriptor",
            "plist_descriptor",
            "application_descriptor",
        ):
            descriptor = getattr(self, attribute)
            if descriptor >= 0:
                os.close(descriptor)
                setattr(self, attribute, -1)


def _reject_symlink_components(path):
    current = pathlib.Path(path.anchor)
    for component in path.parts[1:]:
        current /= component
        try:
            metadata = current.lstat()
        except FileNotFoundError:
            return
        if stat.S_ISLNK(metadata.st_mode):
            raise SyntheticProfileError("invalid input")


def _physical_directory(path):
    candidate = pathlib.Path(path)
    if not candidate.is_absolute():
        raise SyntheticProfileError("invalid input")
    candidate = pathlib.Path(os.path.normpath(candidate))
    _reject_symlink_components(candidate)
    try:
        metadata = candidate.lstat()
        physical = candidate.resolve(strict=True)
    except OSError as error:
        raise SyntheticProfileError("invalid input") from error
    if not stat.S_ISDIR(metadata.st_mode) or physical != candidate:
        raise SyntheticProfileError("invalid input")
    return candidate


def _entry_identity(metadata):
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_uid,
        metadata.st_nlink,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
    )


def _digest_pinned_file(descriptor, maximum_bytes):
    before = os.fstat(descriptor)
    if (
        not stat.S_ISREG(before.st_mode)
        or before.st_size < 1
        or before.st_size > maximum_bytes
    ):
        raise SyntheticProfileError("invalid application")
    os.lseek(descriptor, 0, os.SEEK_SET)
    digest = hashlib.sha256()
    remaining = before.st_size
    while remaining:
        chunk = os.read(descriptor, min(65536, remaining))
        if not chunk:
            raise SyntheticProfileError("invalid application")
        remaining -= len(chunk)
        digest.update(chunk)
    after = os.fstat(descriptor)
    os.lseek(descriptor, 0, os.SEEK_SET)
    if _entry_identity(before) != _entry_identity(after):
        raise SyntheticProfileError("invalid application")
    return digest.digest(), after


def _open_pinned_file(path, maximum_bytes, *, executable=False):
    descriptor = -1
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
        digest, opened = _digest_pinned_file(descriptor, maximum_bytes)
        named = os.stat(path, follow_symlinks=False)
        identity = _entry_identity(opened)
        if (
            identity != _entry_identity(named)
            or stat.S_ISLNK(named.st_mode)
            or path.resolve(strict=True) != path
            or (executable and opened.st_mode & 0o111 == 0)
        ):
            raise SyntheticProfileError("invalid application")
        return descriptor, identity, digest
    except Exception:
        if descriptor >= 0:
            os.close(descriptor)
        raise


def _pin_application(application, executable, bundle_identifier):
    application = _physical_directory(application)
    if application.suffix.lower() != ".app":
        raise SyntheticProfileError("invalid input")
    executable = pathlib.Path(executable)
    if not executable.is_absolute():
        raise SyntheticProfileError("invalid input")
    executable = pathlib.Path(os.path.normpath(executable))
    _reject_symlink_components(executable)
    application_prefix = os.fspath(application) + os.sep
    if not os.fspath(executable).startswith(application_prefix):
        raise SyntheticProfileError("invalid input")

    plist_path = application / "Contents" / "Info.plist"
    _reject_symlink_components(plist_path)
    application_descriptor = -1
    plist_descriptor = -1
    executable_descriptor = -1
    try:
        application_descriptor = os.open(
            application,
            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
        )
        application_metadata = os.fstat(application_descriptor)
        application_named = application.lstat()
        application_identity = _entry_identity(application_metadata)
        if (
            not stat.S_ISDIR(application_metadata.st_mode)
            or _entry_identity(application_named) != application_identity
        ):
            raise SyntheticProfileError("invalid input")
        plist_descriptor, plist_identity, plist_digest = _open_pinned_file(
            plist_path, _MAXIMUM_PLIST_BYTES
        )
        executable_descriptor, executable_identity, executable_digest = (
            _open_pinned_file(executable, _MAXIMUM_EXECUTABLE_BYTES, executable=True)
        )
        with os.fdopen(os.dup(plist_descriptor), "rb") as handle:
            plist = plistlib.load(handle)
        if (
            not isinstance(plist, dict)
            or plist.get("CFBundleIdentifier") != bundle_identifier
            or plist.get("CFBundleExecutable") != executable.name
        ):
            raise SyntheticProfileError("invalid input")
        pinned = _PinnedApplication(
            application,
            executable,
            bundle_identifier,
            application_descriptor,
            application_identity,
            plist_descriptor,
            plist_identity,
            plist_digest,
            executable_descriptor,
            executable_identity,
            executable_digest,
        )
        application_descriptor = -1
        plist_descriptor = -1
        executable_descriptor = -1
        try:
            pinned.require_current()
            browser_driver._validate_signed_browser_binding(
                application, executable, bundle_identifier
            )
            pinned.require_current()
            return pinned
        except Exception as error:
            pinned.close()
            if isinstance(error, SyntheticProfileError):
                raise
            raise SyntheticProfileError("invalid input") from error
    except (OSError, plistlib.InvalidFileException) as error:
        raise SyntheticProfileError("invalid input") from error
    finally:
        for descriptor in (
            executable_descriptor,
            plist_descriptor,
            application_descriptor,
        ):
            if descriptor >= 0:
                os.close(descriptor)


def _prepare_root(path):
    root = pathlib.Path(path)
    if not root.is_absolute():
        raise SyntheticProfileError("invalid input")
    root = pathlib.Path(os.path.normpath(root))
    if root.parent == root:
        raise SyntheticProfileError("invalid input")
    parent = _physical_directory(root.parent)
    if root.exists() or root.is_symlink():
        _reject_symlink_components(root)
        try:
            metadata = root.lstat()
        except OSError as error:
            raise SyntheticProfileError("invalid input") from error
        if (
            not stat.S_ISDIR(metadata.st_mode)
            or metadata.st_uid != os.getuid()
            or metadata.st_mode & 0o077
        ):
            raise SyntheticProfileError("invalid input")
    else:
        root.mkdir(mode=0o700)
    if root.parent != parent:
        raise SyntheticProfileError("invalid input")
    descriptor = -1
    try:
        descriptor = os.open(
            root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
        )
        opened = os.fstat(descriptor)
        named = root.lstat()
        identity = _PinnedRoot._generation(opened)
        if (
            not stat.S_ISDIR(opened.st_mode)
            or _PinnedRoot._generation(named) != identity
            or opened.st_uid != os.getuid()
            or opened.st_mode & 0o077
            or root.resolve(strict=True) != root
            or os.listdir(descriptor)
        ):
            raise SyntheticProfileError("invalid input")
        pinned = _PinnedRoot(root, descriptor, identity)
        pinned.require_current()
        return pinned
    except Exception:
        if descriptor >= 0:
            os.close(descriptor)
        raise


def _restrict_owned_directory(root, name):
    root.require_current()
    if not _safe_child_name(name):
        raise SyntheticProfileError("invalid output")
    try:
        descriptor = os.open(
            name,
            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
            dir_fd=root.descriptor,
        )
    except OSError as error:
        raise SyntheticProfileError("invalid output") from error
    try:
        opened = os.fstat(descriptor)
        named = os.stat(name, dir_fd=root.descriptor, follow_symlinks=False)
        if (
            not stat.S_ISDIR(opened.st_mode)
            or opened.st_uid != os.getuid()
            or opened.st_dev != root.identity[0]
            or (opened.st_dev, opened.st_ino) != (named.st_dev, named.st_ino)
        ):
            raise SyntheticProfileError("invalid output")
        root.require_current()
        os.fchmod(descriptor, 0o700)
        after = os.fstat(descriptor)
        named_after = os.stat(name, dir_fd=root.descriptor, follow_symlinks=False)
        if (
            (after.st_dev, after.st_ino) != (opened.st_dev, opened.st_ino)
            or (named_after.st_dev, named_after.st_ino)
            != (opened.st_dev, opened.st_ino)
            or after.st_mode & 0o077
        ):
            raise SyntheticProfileError("invalid output")
    finally:
        os.close(descriptor)
    root.require_current()


def _safe_child_name(name):
    return (
        bool(name) and name not in {".", ".."} and "/" not in name and "\\" not in name
    )


def _minimal_environment(root):
    root_path = root.require_current()
    try:
        os.mkdir(".creator-home", mode=0o700, dir_fd=root.descriptor)
    except FileExistsError:
        raise SyntheticProfileError("invalid root")
    root.require_current()
    _restrict_owned_directory(root, ".creator-home")
    private_home = root_path / ".creator-home"
    return {
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "LANG": "en_US.UTF-8",
        "LC_CTYPE": "UTF-8",
        "TMPDIR": os.fspath(root_path),
        "HOME": os.fspath(private_home),
        "CFFIXED_USER_HOME": os.fspath(private_home),
    }


def _start_exact(application, arguments, environment):
    application.require_current()
    process = None
    try:
        process = smoke_e2e_runtime.ExactProcess.start(
            [application.executable, *arguments],
            environment=environment,
            expected_executable=application.executable,
            identity_timeout=1.0,
        )
        application.require_current()
        browser_driver._validate_running_browser_code(
            process.pid,
            application.application,
            application.executable,
            application.bundle_identifier,
        )
        application.require_current()
        return process
    except Exception as error:
        if process is not None:
            process.close_streams()
        if isinstance(error, SyntheticProfileError):
            raise
        raise SyntheticProfileError("launch validation failed") from error


def _wait_for_chromium_profile(root, process):
    deadline = time.monotonic() + _CREATE_TIMEOUT_SECONDS
    while time.monotonic() < deadline:
        root.require_current()
        if _entry_has_type(root, _PROFILE_NAME, stat.S_IFDIR) and _entry_has_type(
            root, "Local State", stat.S_IFREG
        ):
            return
        if process.process.poll() is not None:
            break
        time.sleep(0.02)
    raise SyntheticProfileError("creation failed")


def _entry_has_type(root, name, expected_type):
    try:
        metadata = os.stat(name, dir_fd=root.descriptor, follow_symlinks=False)
    except FileNotFoundError:
        return False
    except OSError as error:
        raise SyntheticProfileError("invalid output") from error
    return stat.S_IFMT(metadata.st_mode) == expected_type


def _read_restricted_regular_file(
    root, name, maximum_bytes, *, require_restricted=False
):
    root.require_current()
    try:
        descriptor = os.open(
            name,
            os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC,
            dir_fd=root.descriptor,
        )
    except OSError as error:
        raise SyntheticProfileError("invalid output") from error
    try:
        metadata = os.fstat(descriptor)
        named = os.stat(name, dir_fd=root.descriptor, follow_symlinks=False)
        if _file_generation(metadata) != _file_generation(named):
            raise SyntheticProfileError("invalid output")
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != os.getuid()
            or metadata.st_dev != root.identity[0]
            or metadata.st_nlink != 1
            or metadata.st_size > maximum_bytes
            or (require_restricted and metadata.st_mode & 0o077)
        ):
            raise SyntheticProfileError("invalid output")
        contents = bytearray()
        while len(contents) <= maximum_bytes:
            chunk = os.read(descriptor, min(65536, maximum_bytes + 1 - len(contents)))
            if not chunk:
                break
            contents.extend(chunk)
        after = os.fstat(descriptor)
        named_after = os.stat(name, dir_fd=root.descriptor, follow_symlinks=False)
        if (
            len(contents) != metadata.st_size
            or _file_identity(metadata) != _file_identity(after)
            or _file_generation(metadata) != _file_generation(named_after)
        ):
            raise SyntheticProfileError("invalid output")
    finally:
        os.close(descriptor)
    root.require_current()
    return bytes(contents), metadata


def _validate_restricted_regular_file(root, name, maximum_bytes):
    contents, _ = _read_restricted_regular_file(
        root, name, maximum_bytes, require_restricted=True
    )
    return contents


def _file_generation(metadata):
    return metadata.st_dev, metadata.st_ino


def _file_identity(metadata):
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_uid,
        metadata.st_nlink,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
    )


def _unique_json_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise SyntheticProfileError("invalid output")
        value[key] = item
    return value


def _reject_nonfinite_json(_value):
    raise SyntheticProfileError("invalid output")


def _decode_local_state(data):
    try:
        value = json.loads(
            data,
            object_pairs_hook=_unique_json_object,
            parse_constant=_reject_nonfinite_json,
        )
    except (
        UnicodeDecodeError,
        json.JSONDecodeError,
        TypeError,
        ValueError,
    ) as error:
        raise SyntheticProfileError("invalid output") from error
    if not isinstance(value, dict):
        raise SyntheticProfileError("invalid output")
    profile = value.get("profile")
    if not isinstance(profile, dict):
        raise SyntheticProfileError("invalid output")
    info_cache = profile.get("info_cache")
    if not isinstance(info_cache, dict) or set(info_cache) != {_PROFILE_NAME}:
        raise SyntheticProfileError("invalid output")
    metadata = info_cache[_PROFILE_NAME]
    if not isinstance(metadata, dict):
        raise SyntheticProfileError("invalid output")
    return value, metadata


def _normalize_chromium(root):
    root.require_current()
    _restrict_owned_directory(root, _PROFILE_NAME)
    data, before = _read_restricted_regular_file(
        root, "Local State", _MAXIMUM_LOCAL_STATE_BYTES
    )
    value, metadata = _decode_local_state(data)
    metadata["name"] = _PROFILE_NAME
    try:
        encoded = json.dumps(
            value,
            allow_nan=False,
            ensure_ascii=True,
            separators=(",", ":"),
            sort_keys=True,
        ).encode("utf-8")
    except (TypeError, ValueError) as error:
        raise SyntheticProfileError("invalid output") from error
    if len(encoded) > _MAXIMUM_LOCAL_STATE_BYTES:
        raise SyntheticProfileError("invalid output")
    root.require_current()
    after_read = os.stat("Local State", dir_fd=root.descriptor, follow_symlinks=False)
    if _file_identity(before) != _file_identity(after_read):
        raise SyntheticProfileError("invalid output")
    root.require_current()
    descriptor = os.open(
        "Local State",
        os.O_WRONLY | os.O_NOFOLLOW | os.O_CLOEXEC,
        dir_fd=root.descriptor,
    )
    try:
        if _file_identity(os.fstat(descriptor)) != _file_identity(before):
            raise SyntheticProfileError("invalid output")
        root.require_current()
        os.ftruncate(descriptor, 0)
        offset = 0
        while offset < len(encoded):
            root.require_current()
            written = os.write(descriptor, encoded[offset:])
            if written <= 0:
                raise SyntheticProfileError("invalid output")
            offset += written
        root.require_current()
        os.fchmod(descriptor, 0o600)
        root.require_current()
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    root.require_current()
    if (
        _validate_restricted_regular_file(
            root, "Local State", _MAXIMUM_LOCAL_STATE_BYTES
        )
        != encoded
    ):
        raise SyntheticProfileError("invalid output")


def _create_chromium(root, application, environment):
    root_path = root.require_current()
    arguments = [
        f"--user-data-dir={root_path}",
        f"--profile-directory={_PROFILE_NAME}",
        "--no-first-run",
        "--no-default-browser-check",
        "--disable-sync",
        "--disable-background-networking",
        "--disable-component-update",
        "--disable-default-apps",
        "about:blank",
    ]
    root.require_current()
    process = _start_exact(application, arguments, environment)
    stopped = False
    try:
        _wait_for_chromium_profile(root, process)
        stopped = process.terminate_bounded(
            term_timeout=_SHUTDOWN_TIMEOUT_SECONDS,
            kill_timeout=_SHUTDOWN_TIMEOUT_SECONDS,
        )
    finally:
        if not stopped:
            process.terminate_bounded(
                term_timeout=_SHUTDOWN_TIMEOUT_SECONDS,
                kill_timeout=_SHUTDOWN_TIMEOUT_SECONDS,
            )
        process.close_streams()
    if not stopped:
        raise SyntheticProfileError("shutdown failed")
    root.require_current()
    _normalize_chromium(root)


def _firefox_profiles_contents():
    return (
        "[General]\n"
        "StartWithLastProfile=0\n"
        "Version=2\n\n"
        "[Profile0]\n"
        f"Name={_PROFILE_NAME}\n"
        "IsRelative=1\n"
        f"Path={_PROFILE_NAME}\n"
        "Default=1\n"
    ).encode("utf-8")


def _write_firefox_profiles(root):
    root.require_current()
    _restrict_owned_directory(root, _PROFILE_NAME)
    contents = _firefox_profiles_contents()
    root.require_current()
    descriptor = os.open(
        "profiles.ini",
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
        0o600,
        dir_fd=root.descriptor,
    )
    try:
        root.require_current()
        offset = 0
        while offset < len(contents):
            root.require_current()
            written = os.write(descriptor, contents[offset:])
            if written <= 0:
                raise SyntheticProfileError("invalid output")
            offset += written
        root.require_current()
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    root.require_current()
    if (
        _validate_restricted_regular_file(root, "profiles.ini", len(contents))
        != contents
    ):
        raise SyntheticProfileError("invalid output")


def _create_firefox(root, application, environment):
    root_path = root.require_current()
    profile = root_path / _PROFILE_NAME
    root.require_current()
    process = _start_exact(
        application,
        ["-CreateProfile", f"PickViaE2E {profile}"],
        environment,
    )
    try:
        if not process.wait_success(_CREATE_TIMEOUT_SECONDS):
            if not process.terminate_bounded(
                term_timeout=_SHUTDOWN_TIMEOUT_SECONDS,
                kill_timeout=_SHUTDOWN_TIMEOUT_SECONDS,
            ):
                raise SyntheticProfileError("shutdown failed")
            raise SyntheticProfileError("creation failed")
    finally:
        process.close_streams()
    root.require_current()
    _write_firefox_profiles(root)


def create_synthetic_profile(args):
    if not _BUNDLE_IDENTIFIER.fullmatch(args.bundle_identifier):
        raise SyntheticProfileError("invalid input")
    if args.strategy not in {"chromium", "firefox"}:
        raise SyntheticProfileError("invalid input")
    application = _pin_application(
        args.application,
        args.executable,
        args.bundle_identifier,
    )
    root = None
    try:
        root = _prepare_root(args.root)
        environment = _minimal_environment(root)
        if args.strategy == "chromium":
            _create_chromium(root, application, environment)
        elif args.strategy == "firefox":
            _create_firefox(root, application, environment)
        root.require_current()
    finally:
        if root is not None:
            root.close()
        application.close()


def _arguments(argv=None):
    parser = _SanitizedArgumentParser()
    parser.add_argument("--application", required=True)
    parser.add_argument("--executable", required=True)
    parser.add_argument("--bundle-identifier", required=True)
    parser.add_argument("--strategy", choices=("chromium", "firefox"), required=True)
    parser.add_argument("--root", required=True)
    return parser.parse_args(argv)


def main(argv=None):
    try:
        create_synthetic_profile(_arguments(argv))
    except SyntheticProfileArgumentError:
        print("synthetic-profile-error:arguments", file=sys.stderr)
        return 2
    except Exception:
        print("synthetic-profile-error:creation", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
