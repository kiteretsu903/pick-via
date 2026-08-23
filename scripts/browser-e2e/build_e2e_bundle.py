#!/usr/bin/env python3

import hashlib
import os
import pathlib
import plistlib
import stat
import subprocess
import sys


class BundleBuildError(RuntimeError):
    pass


STABLE_FIELDS = (
    "st_dev",
    "st_ino",
    "st_mode",
    "st_size",
    "st_mtime_ns",
    "st_ctime_ns",
)


def same_identity(left, right):
    return (left.st_dev, left.st_ino, left.st_mode) == (
        right.st_dev,
        right.st_ino,
        right.st_mode,
    )


def exact_entries(directory_fd, expected):
    names = set(os.listdir(directory_fd))
    if names != set(expected):
        raise BundleBuildError("bundle contains unexpected entries")
    for name in names:
        metadata = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
        if stat.S_ISLNK(metadata.st_mode):
            raise BundleBuildError("bundle contains a symlink")


def bind_child(parent_fd, name):
    descriptor = os.open(
        name,
        os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW,
        dir_fd=parent_fd,
    )
    pinned = os.fstat(descriptor)
    named = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    if not stat.S_ISDIR(pinned.st_mode) or not same_identity(pinned, named):
        os.close(descriptor)
        raise BundleBuildError("bundle child directory changed")
    return descriptor, pinned


def validate_child(parent_fd, name, descriptor, expected):
    pinned = os.fstat(descriptor)
    named = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    if not same_identity(pinned, expected) or not same_identity(pinned, named):
        raise BundleBuildError("bundle child directory changed")


def stable_file_record(descriptor):
    before = os.fstat(descriptor)
    if not stat.S_ISREG(before.st_mode):
        raise BundleBuildError("bundle source is not regular")
    os.lseek(descriptor, 0, os.SEEK_SET)
    digest = hashlib.sha256()
    while True:
        chunk = os.read(descriptor, 65_536)
        if not chunk:
            break
        digest.update(chunk)
    after = os.fstat(descriptor)
    if any(getattr(before, field) != getattr(after, field) for field in STABLE_FIELDS):
        raise BundleBuildError("bundle source changed during read")
    return tuple(getattr(before, field) for field in STABLE_FIELDS), digest.digest()


def validate_named_source(path, expected):
    descriptor = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        current = stable_file_record(descriptor)
    finally:
        os.close(descriptor)
    if current != expected:
        raise BundleBuildError("bundle source path changed")


def open_destination(directory_fd, name, mode):
    flags = os.O_RDWR | os.O_CLOEXEC | os.O_NOFOLLOW
    try:
        descriptor = os.open(name, flags, dir_fd=directory_fd)
    except PermissionError:
        readonly = os.open(
            name,
            os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW,
            dir_fd=directory_fd,
        )
        try:
            pinned = os.fstat(readonly)
            named = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
            if (
                not stat.S_ISREG(pinned.st_mode)
                or pinned.st_nlink != 1
                or not same_identity(pinned, named)
            ):
                raise BundleBuildError("bundle destination link identity is unsafe")
            os.fchmod(readonly, pinned.st_mode | stat.S_IWUSR)
        finally:
            os.close(readonly)
        descriptor = os.open(name, flags, dir_fd=directory_fd)
        if not same_identity(os.fstat(descriptor), pinned):
            os.close(descriptor)
            raise BundleBuildError("bundle destination was replaced")
    except FileNotFoundError:
        descriptor = os.open(
            name,
            flags | os.O_CREAT | os.O_EXCL,
            mode,
            dir_fd=directory_fd,
        )
    try:
        validate_writable_destination(directory_fd, name, descriptor)
    except Exception:
        os.close(descriptor)
        raise
    return descriptor


def validate_writable_destination(directory_fd, name, descriptor):
    pinned = os.fstat(descriptor)
    named = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
    if (
        not stat.S_ISREG(pinned.st_mode)
        or pinned.st_nlink != 1
        or not same_identity(pinned, named)
    ):
        raise BundleBuildError("bundle destination link identity is unsafe")


def write_bytes(directory_fd, name, contents, mode):
    descriptor = open_destination(directory_fd, name, mode)
    try:
        validate_writable_destination(directory_fd, name, descriptor)
        os.ftruncate(descriptor, 0)
        os.lseek(descriptor, 0, os.SEEK_SET)
        view = memoryview(contents)
        while view:
            view = view[os.write(descriptor, view) :]
        os.fchmod(descriptor, mode)
        os.fsync(descriptor)
        validate_writable_destination(directory_fd, name, descriptor)
        after = os.fstat(descriptor)
        if after.st_size != len(contents):
            raise BundleBuildError("bundle destination changed after write")
    finally:
        os.close(descriptor)


def copy_descriptor(source_fd, directory_fd, name, mode, expected_source):
    before, source_hash = expected_source
    descriptor = open_destination(directory_fd, name, mode)
    try:
        os.lseek(source_fd, 0, os.SEEK_SET)
        validate_writable_destination(directory_fd, name, descriptor)
        os.ftruncate(descriptor, 0)
        os.lseek(descriptor, 0, os.SEEK_SET)
        copied_hash = hashlib.sha256()
        while True:
            chunk = os.read(source_fd, 65_536)
            if not chunk:
                break
            copied_hash.update(chunk)
            view = memoryview(chunk)
            while view:
                view = view[os.write(descriptor, view) :]
        os.fchmod(descriptor, mode)
        os.fsync(descriptor)
        after_source = os.fstat(source_fd)
        after_destination = os.fstat(descriptor)
        validate_writable_destination(directory_fd, name, descriptor)
        if tuple(getattr(after_source, field) for field in STABLE_FIELDS) != before:
            raise BundleBuildError("bundle source changed during copy")
        if copied_hash.digest() != source_hash or after_destination.st_size != after_source.st_size:
            raise BundleBuildError("bundle copy digest mismatch")
    finally:
        os.close(descriptor)


def read_source(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        record, _ = stable_file_record(descriptor)
        os.lseek(descriptor, 0, os.SEEK_SET)
        contents = bytearray()
        while True:
            chunk = os.read(descriptor, 65_536)
            if not chunk:
                break
            contents.extend(chunk)
        after = os.fstat(descriptor)
        if tuple(getattr(after, field) for field in STABLE_FIELDS) != record:
            raise BundleBuildError("bundle source changed during read")
        return bytes(contents)
    finally:
        os.close(descriptor)


def validate_single_link_file(directory_fd, name):
    descriptor = os.open(
        name,
        os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW,
        dir_fd=directory_fd,
    )
    try:
        pinned = os.fstat(descriptor)
        named = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
        if (
            not stat.S_ISREG(pinned.st_mode)
            or pinned.st_nlink != 1
            or not same_identity(pinned, named)
        ):
            raise BundleBuildError("signature link identity is unsafe")
    finally:
        os.close(descriptor)


def run_hook(repo_root, phase):
    hook = os.environ.get("PICKVIA_BUILD_E2E_CONTRACT_HOOK")
    if not hook:
        return
    fixture_prefix = "/private/tmp/pickvia-e2e-build-isolation."
    if not os.fspath(repo_root).startswith(fixture_prefix) or not hook.startswith(fixture_prefix):
        raise BundleBuildError("build contract hook is forbidden")
    metadata = os.lstat(hook)
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        raise BundleBuildError("build contract hook is invalid")
    environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}
    environment.update(
        (key, value)
        for key, value in os.environ.items()
        if key.startswith("PICKVIA_BUILD_CONTRACT_")
    )
    completed = subprocess.run(
        [hook, phase],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        env=environment,
        close_fds=True,
        timeout=5,
        check=False,
    )
    if completed.returncode != 0:
        raise BundleBuildError("build contract hook failed")


def main(arguments):
    if len(arguments) != 10:
        return 1
    repo_root = pathlib.Path(arguments[0])
    app_path = pathlib.Path(arguments[1])
    app_fd = int(arguments[2])
    contents_fd = int(arguments[3])
    scratch_path = pathlib.Path(arguments[4])
    scratch_fd = int(arguments[5])
    info_path = pathlib.Path(arguments[6])
    icon_path = pathlib.Path(arguments[7])
    menu_path = pathlib.Path(arguments[8])
    app_existed = arguments[9] == "true"
    contents_expected = os.fstat(contents_fd)
    app_expected = os.fstat(app_fd)
    source_expected = stable_file_record(scratch_fd)
    children = []
    try:
        for name, phase in (
            ("MacOS", "before-macos-open"),
            ("Resources", "before-resources-open"),
            ("_CodeSignature", "before-signature-open"),
        ):
            run_hook(repo_root, phase)
            descriptor, metadata = bind_child(contents_fd, name)
            children.append((name, descriptor, metadata))
        child_map = {name: descriptor for name, descriptor, _ in children}
        if app_existed:
            exact_entries(child_map["MacOS"], {"PickVia"})
            exact_entries(
                child_map["Resources"],
                {"PickVia.icns", "PickViaMenuBarTemplate.png"},
            )
            exact_entries(child_map["_CodeSignature"], {"CodeResources"})
            validate_single_link_file(child_map["_CodeSignature"], "CodeResources")
        else:
            for _, descriptor, _ in children:
                exact_entries(descriptor, set())
        run_hook(repo_root, "before-scratch-copy")
        if stable_file_record(scratch_fd) != source_expected:
            raise BundleBuildError("pinned scratch executable changed")
        validate_named_source(scratch_path, source_expected)
        for name, descriptor, metadata in children:
            validate_child(contents_fd, name, descriptor, metadata)
        copy_descriptor(
            scratch_fd,
            child_map["MacOS"],
            "PickVia",
            0o755,
            source_expected,
        )
        values = plistlib.loads(read_source(info_path))
        values["CFBundleIdentifier"] = "dev.bozhenpeng.PickVia.E2E"
        values["CFBundleName"] = "PickVia E2E"
        values["PickViaE2EAutomation"] = True
        values["PickViaE2EAutomationMarker"] = "PICKVIA_E2E_AUTOMATION_ENABLED"
        write_bytes(
            contents_fd,
            "Info.plist",
            plistlib.dumps(values, fmt=plistlib.FMT_XML, sort_keys=True),
            0o644,
        )
        write_bytes(child_map["Resources"], "PickVia.icns", read_source(icon_path), 0o644)
        write_bytes(
            child_map["Resources"],
            "PickViaMenuBarTemplate.png",
            read_source(menu_path),
            0o644,
        )
        if stable_file_record(scratch_fd) != source_expected:
            raise BundleBuildError("scratch executable changed after copy")
        named_app = os.stat(app_path, follow_symlinks=False)
        named_contents = os.stat("Contents", dir_fd=app_fd, follow_symlinks=False)
        if not same_identity(app_expected, named_app) or not same_identity(
            contents_expected, named_contents
        ):
            raise BundleBuildError("public bundle identity changed")
        for name, descriptor, metadata in children:
            validate_child(contents_fd, name, descriptor, metadata)
        os.fchdir(app_fd)
        completed = subprocess.run(
            ["/usr/bin/codesign", "--force", "--deep", "--sign", "-", "."],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env={
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "LANG": "C",
                "LC_CTYPE": "C",
            },
            close_fds=True,
            timeout=10,
            check=False,
        )
        if completed.returncode != 0:
            raise BundleBuildError("bundle signing failed")
        exact_entries(contents_fd, {"Info.plist", "MacOS", "Resources", "_CodeSignature"})
        exact_entries(child_map["MacOS"], {"PickVia"})
        exact_entries(
            child_map["Resources"],
            {"PickVia.icns", "PickViaMenuBarTemplate.png"},
        )
        exact_entries(child_map["_CodeSignature"], {"CodeResources"})
        validate_single_link_file(child_map["_CodeSignature"], "CodeResources")
        for name, descriptor, metadata in children:
            validate_child(contents_fd, name, descriptor, metadata)
        return 0
    except (BundleBuildError, OSError, plistlib.InvalidFileException, subprocess.TimeoutExpired):
        return 1
    finally:
        for _, descriptor, _ in reversed(children):
            os.close(descriptor)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
