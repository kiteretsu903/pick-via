#!/usr/bin/env python3

import argparse
import json
import os
import pathlib
import plistlib
import re
import stat
import sys
import time

import smoke_e2e_runtime


_PROFILE_NAME = "PickVia E2E"
_BUNDLE_IDENTIFIER = re.compile(r"\A[A-Za-z0-9][A-Za-z0-9.-]{2,254}\Z")
_MAXIMUM_PLIST_BYTES = 64 * 1024
_MAXIMUM_LOCAL_STATE_BYTES = 1024 * 1024
_CREATE_TIMEOUT_SECONDS = 5.0
_SHUTDOWN_TIMEOUT_SECONDS = 2.0


class SyntheticProfileError(RuntimeError):
    pass


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


def _physical_executable(application, executable, bundle_identifier):
    application = _physical_directory(application)
    if application.suffix.lower() != ".app":
        raise SyntheticProfileError("invalid input")
    executable = pathlib.Path(executable)
    if not executable.is_absolute():
        raise SyntheticProfileError("invalid input")
    executable = pathlib.Path(os.path.normpath(executable))
    _reject_symlink_components(executable)
    try:
        metadata = executable.lstat()
        physical = executable.resolve(strict=True)
    except OSError as error:
        raise SyntheticProfileError("invalid input") from error
    application_prefix = os.fspath(application) + os.sep
    if (
        physical != executable
        or not stat.S_ISREG(metadata.st_mode)
        or metadata.st_mode & 0o111 == 0
        or not os.fspath(executable).startswith(application_prefix)
    ):
        raise SyntheticProfileError("invalid input")

    plist_path = application / "Contents" / "Info.plist"
    _reject_symlink_components(plist_path)
    try:
        plist_metadata = plist_path.lstat()
        if (
            not stat.S_ISREG(plist_metadata.st_mode)
            or plist_metadata.st_size > _MAXIMUM_PLIST_BYTES
            or plist_metadata.st_nlink != 1
        ):
            raise SyntheticProfileError("invalid input")
        with plist_path.open("rb") as handle:
            plist = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException) as error:
        raise SyntheticProfileError("invalid input") from error
    if (
        plist.get("CFBundleIdentifier") != bundle_identifier
        or plist.get("CFBundleExecutable") != executable.name
    ):
        raise SyntheticProfileError("invalid input")
    return application, executable


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
            or any(root.iterdir())
        ):
            raise SyntheticProfileError("invalid input")
    else:
        root.mkdir(mode=0o700)
    if root.parent != parent:
        raise SyntheticProfileError("invalid input")
    _validate_owned_directory(root)
    return root


def _validate_owned_directory(path):
    _reject_symlink_components(path)
    metadata = path.lstat()
    if (
        not stat.S_ISDIR(metadata.st_mode)
        or metadata.st_uid != os.getuid()
        or metadata.st_mode & 0o077
        or path.resolve(strict=True) != path
    ):
        raise SyntheticProfileError("invalid output")


def _restrict_owned_directory(path):
    _reject_symlink_components(path)
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        opened = os.fstat(descriptor)
        named = path.lstat()
        if (
            not stat.S_ISDIR(opened.st_mode)
            or opened.st_uid != os.getuid()
            or (opened.st_dev, opened.st_ino) != (named.st_dev, named.st_ino)
            or path.resolve(strict=True) != path
        ):
            raise SyntheticProfileError("invalid output")
        os.fchmod(descriptor, 0o700)
        after = os.fstat(descriptor)
        named_after = path.lstat()
        if (
            (after.st_dev, after.st_ino) != (opened.st_dev, opened.st_ino)
            or (named_after.st_dev, named_after.st_ino)
            != (opened.st_dev, opened.st_ino)
            or after.st_mode & 0o077
        ):
            raise SyntheticProfileError("invalid output")
    finally:
        os.close(descriptor)


def _minimal_environment(root):
    private_home = root / ".creator-home"
    private_home.mkdir(mode=0o700)
    return {
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "LANG": "en_US.UTF-8",
        "LC_CTYPE": "UTF-8",
        "TMPDIR": os.fspath(root),
        "HOME": os.fspath(private_home),
        "CFFIXED_USER_HOME": os.fspath(private_home),
    }


def _start_exact(executable, arguments, environment):
    return smoke_e2e_runtime.ExactProcess.start(
        [executable, *arguments],
        environment=environment,
        expected_executable=executable,
        identity_timeout=1.0,
    )


def _wait_for_chromium_profile(root, process):
    profile = root / _PROFILE_NAME
    marker = root / "Local State"
    deadline = time.monotonic() + _CREATE_TIMEOUT_SECONDS
    while time.monotonic() < deadline:
        if profile.exists() and marker.exists():
            return
        if process.process.poll() is not None:
            break
        time.sleep(0.02)
    raise SyntheticProfileError("creation failed")


def _restricted_regular_file(path, maximum_bytes, *, require_restricted=False):
    _reject_symlink_components(path)
    metadata = path.lstat()
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_uid != os.getuid()
        or metadata.st_nlink != 1
        or metadata.st_size > maximum_bytes
        or (require_restricted and metadata.st_mode & 0o077)
    ):
        raise SyntheticProfileError("invalid output")
    return metadata


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


def _normalize_chromium(root):
    _validate_owned_directory(root)
    profile = root / _PROFILE_NAME
    marker = root / "Local State"
    _restrict_owned_directory(profile)
    before = _restricted_regular_file(marker, _MAXIMUM_LOCAL_STATE_BYTES)
    try:
        data = marker.read_bytes()
        value = json.loads(data)
        info_cache = value["profile"]["info_cache"]
    except (
        OSError,
        UnicodeDecodeError,
        json.JSONDecodeError,
        KeyError,
        TypeError,
    ) as error:
        raise SyntheticProfileError("invalid output") from error
    if set(info_cache) != {_PROFILE_NAME} or not isinstance(
        info_cache[_PROFILE_NAME], dict
    ):
        raise SyntheticProfileError("invalid output")
    info_cache[_PROFILE_NAME]["name"] = _PROFILE_NAME
    encoded = json.dumps(value, separators=(",", ":"), sort_keys=True).encode("utf-8")
    if len(encoded) > _MAXIMUM_LOCAL_STATE_BYTES:
        raise SyntheticProfileError("invalid output")
    after_read = marker.lstat()
    if _file_identity(before) != _file_identity(after_read):
        raise SyntheticProfileError("invalid output")
    descriptor = os.open(marker, os.O_WRONLY | os.O_NOFOLLOW)
    try:
        if _file_identity(os.fstat(descriptor)) != _file_identity(before):
            raise SyntheticProfileError("invalid output")
        os.ftruncate(descriptor, 0)
        offset = 0
        while offset < len(encoded):
            written = os.write(descriptor, encoded[offset:])
            if written <= 0:
                raise SyntheticProfileError("invalid output")
            offset += written
        os.fchmod(descriptor, 0o600)
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    _restricted_regular_file(
        marker, _MAXIMUM_LOCAL_STATE_BYTES, require_restricted=True
    )


def _create_chromium(root, executable, environment):
    arguments = [
        f"--user-data-dir={root}",
        f"--profile-directory={_PROFILE_NAME}",
        "--no-first-run",
        "--no-default-browser-check",
        "--disable-sync",
        "--disable-background-networking",
        "--disable-component-update",
        "--disable-default-apps",
        "about:blank",
    ]
    process = _start_exact(executable, arguments, environment)
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
    _normalize_chromium(root)


def _write_firefox_profiles(root):
    profile = root / _PROFILE_NAME
    _restrict_owned_directory(profile)
    marker = root / "profiles.ini"
    contents = (
        "[General]\n"
        "StartWithLastProfile=0\n"
        "Version=2\n\n"
        "[Profile0]\n"
        f"Name={_PROFILE_NAME}\n"
        "IsRelative=1\n"
        f"Path={_PROFILE_NAME}\n"
        "Default=1\n"
    ).encode("utf-8")
    descriptor = os.open(
        marker, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600
    )
    try:
        if os.write(descriptor, contents) != len(contents):
            raise SyntheticProfileError("invalid output")
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    _restricted_regular_file(marker, len(contents), require_restricted=True)


def _create_firefox(root, executable, environment):
    profile = root / _PROFILE_NAME
    process = _start_exact(
        executable,
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
    _write_firefox_profiles(root)


def create_synthetic_profile(args):
    if not _BUNDLE_IDENTIFIER.fullmatch(args.bundle_identifier):
        raise SyntheticProfileError("invalid input")
    if args.strategy not in {"chromium", "firefox"}:
        raise SyntheticProfileError("invalid input")
    _, executable = _physical_executable(
        args.application,
        args.executable,
        args.bundle_identifier,
    )
    root = _prepare_root(args.root)
    environment = _minimal_environment(root)
    if args.strategy == "chromium":
        _create_chromium(root, executable, environment)
    elif args.strategy == "firefox":
        _create_firefox(root, executable, environment)


def _arguments(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--application", required=True)
    parser.add_argument("--executable", required=True)
    parser.add_argument("--bundle-identifier", required=True)
    parser.add_argument("--strategy", choices=("chromium", "firefox"), required=True)
    parser.add_argument("--root", required=True)
    return parser.parse_args(argv)


def main(argv=None):
    try:
        create_synthetic_profile(_arguments(argv))
    except (SyntheticProfileError, OSError, ValueError):
        print("synthetic profile creation failed", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
