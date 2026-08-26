#!/usr/bin/env python3

import os
import pathlib
import shutil
import socket
import subprocess
import tempfile
import unittest


SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
SOURCE = SCRIPT_DIR / "exclusive_cleanup.c"


class ExclusiveCleanupTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build_root = pathlib.Path(
            tempfile.mkdtemp(prefix="pickvia-exclusive-cleanup-tests-", dir="/private/tmp")
        )
        cls.addClassCleanup(shutil.rmtree, cls.build_root)
        cls.helper = cls.build_root / "exclusive_cleanup"
        completed = subprocess.run(
            [
                "/usr/bin/xcrun",
                "clang",
                "-std=c17",
                "-Wall",
                "-Wextra",
                "-Werror",
                "-DPICKVIA_EXCLUSIVE_CLEANUP_TESTING=1",
                os.fspath(SOURCE),
                "-o",
                os.fspath(cls.helper),
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin"},
            timeout=10,
            check=False,
        )
        if completed.returncode != 0:
            raise AssertionError(completed.stderr.decode("utf-8", "replace"))

    def setUp(self):
        self.parent = pathlib.Path(
            tempfile.mkdtemp(prefix="pickvia-exclusive-parent-", dir="/private/tmp")
        )
        self.root = self.parent / "pickvia-e2e-owned"
        self.root.mkdir(mode=0o700)
        self.parent_fd = os.open(
            self.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
        )
        self.root_fd = os.open(self.root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)

    def tearDown(self):
        os.close(self.root_fd)
        os.close(self.parent_fd)
        shutil.rmtree(self.parent)

    def _arguments(
        self, *, quarantine=".pickvia-finalize-0123456789abcdef", root_fd=None
    ):
        root_fd = self.root_fd if root_fd is None else root_fd
        root_metadata = os.fstat(root_fd)
        parent_metadata = os.fstat(self.parent_fd)
        return [
            os.fspath(self.helper),
            str(self.parent_fd),
            str(root_fd),
            self.root.name,
            quarantine,
            str(root_metadata.st_dev),
            str(root_metadata.st_ino),
            str(root_metadata.st_uid),
            str(root_metadata.st_mode),
            str(parent_metadata.st_dev),
            str(parent_metadata.st_ino),
            str(parent_metadata.st_uid),
            str(parent_metadata.st_mode),
        ]

    def _run(self, *, arguments=None, pass_fds=(), environment=None):
        inherited = (self.parent_fd, self.root_fd, *pass_fds)
        return subprocess.run(
            arguments or self._arguments(),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment or {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin"},
            pass_fds=inherited,
            timeout=2,
            check=False,
        )

    def test_removes_successful_empty_owned_root(self):
        completed = self._run()
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertFalse(self.root.exists())
        self.assertEqual(os.listdir(self.root_fd), [])

    def test_existing_quarantine_collision_is_preserved(self):
        quarantine = ".pickvia-finalize-collision"
        collision = self.parent / quarantine
        collision.write_bytes(b"preserve collision")
        completed = self._run(arguments=self._arguments(quarantine=quarantine))
        self.assertEqual(completed.returncode, 70)
        self.assertTrue(self.root.is_dir())
        self.assertEqual(collision.read_bytes(), b"preserve collision")

    def test_replacement_after_rename_is_preserved_and_fails_closed(self):
        controller, inherited = socket.socketpair()
        environment = {
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "PICKVIA_EXCLUSIVE_CLEANUP_TEST_SOCKET_FD": str(inherited.fileno()),
        }
        process = subprocess.Popen(
            self._arguments(),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment,
            pass_fds=(self.parent_fd, self.root_fd, inherited.fileno()),
        )
        inherited.close()
        try:
            self.assertEqual(controller.recv(1), b"R")
            self.root.mkdir(mode=0o700)
            marker = self.root / "replacement-must-survive"
            marker.write_bytes(b"replacement")
            controller.sendall(b"C")
            stdout, stderr = process.communicate(timeout=2)
        finally:
            controller.close()
            if process.poll() is None:
                process.kill()
                process.wait(timeout=1)
        self.assertEqual(process.returncode, 70, (stdout, stderr))
        self.assertEqual(marker.read_bytes(), b"replacement")
        quarantines = list(self.parent.glob(".pickvia-finalize-*"))
        self.assertEqual(len(quarantines), 1)
        self.assertTrue(quarantines[0].is_dir())

    def test_expected_identity_mismatch_preserves_state(self):
        arguments = self._arguments()
        arguments[6] = str(int(arguments[6]) + 1)
        completed = self._run(arguments=arguments)
        self.assertEqual(completed.returncode, 70)
        self.assertTrue(self.root.is_dir())

    def test_nonempty_root_is_preserved(self):
        marker = self.root / "must-survive"
        marker.write_bytes(b"owned but nonempty")
        completed = self._run()
        self.assertEqual(completed.returncode, 71)
        self.assertEqual(marker.read_bytes(), b"owned but nonempty")

    def test_in_root_helper_is_not_unlinked_or_treated_as_special(self):
        nested_helper = self.root / "exclusive-cleanup"
        shutil.copyfile(self.helper, nested_helper)
        nested_helper.chmod(0o700)
        completed = self._run()
        self.assertEqual(completed.returncode, 71)
        self.assertTrue(nested_helper.is_file())

    def test_cross_device_root_is_preserved(self):
        other_fd = os.open("/dev", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            completed = self._run(
                arguments=self._arguments(root_fd=other_fd), pass_fds=(other_fd,)
            )
        finally:
            os.close(other_fd)
        self.assertEqual(completed.returncode, 70)
        self.assertTrue(self.root.is_dir())

    def test_uninspectable_root_is_preserved(self):
        regular = self.parent / "not-a-directory"
        regular.write_bytes(b"preserve")
        regular_fd = os.open(regular, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            completed = self._run(
                arguments=self._arguments(root_fd=regular_fd), pass_fds=(regular_fd,)
            )
        finally:
            os.close(regular_fd)
        self.assertEqual(completed.returncode, 70)
        self.assertTrue(self.root.is_dir())
        self.assertEqual(regular.read_bytes(), b"preserve")

    def test_usage_is_closed(self):
        completed = subprocess.run(
            [os.fspath(self.helper)],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin"},
            timeout=2,
            check=False,
        )
        self.assertEqual(completed.returncode, 64)


if __name__ == "__main__":
    unittest.main()
