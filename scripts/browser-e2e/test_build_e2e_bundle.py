#!/usr/bin/env python3

import os
import pathlib
import shutil
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).parent))

import build_e2e_bundle as bundle


class DestinationLinkRaceTests(unittest.TestCase):
    def setUp(self):
        self.root = pathlib.Path(
            tempfile.mkdtemp(prefix="pickvia-bundle-link-race-", dir="/private/tmp")
        )
        self.directory_fd = os.open(
            self.root,
            os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW,
        )
        self.destination = self.root / "destination"
        self.external = self.root / "external"
        self.destination.write_bytes(b"preserved")

    def tearDown(self):
        os.close(self.directory_fd)
        shutil.rmtree(self.root)

    def _open_then_link(self, original):
        def injected(*arguments):
            descriptor = original(*arguments)
            os.link(self.destination, self.external)
            return descriptor

        return injected

    def test_write_rechecks_link_count_immediately_before_truncate(self):
        original = bundle.open_destination
        with mock.patch.object(
            bundle,
            "open_destination",
            side_effect=self._open_then_link(original),
        ):
            with self.assertRaises(bundle.BundleBuildError):
                bundle.write_bytes(
                    self.directory_fd,
                    self.destination.name,
                    b"replacement",
                    0o644,
                )
        self.assertEqual(self.external.read_bytes(), b"preserved")

    def test_copy_rechecks_link_count_immediately_before_truncate(self):
        source = self.root / "source"
        source.write_bytes(b"replacement")
        source_fd = os.open(source, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
        try:
            expected = bundle.stable_file_record(source_fd)
            original = bundle.open_destination
            with mock.patch.object(
                bundle,
                "open_destination",
                side_effect=self._open_then_link(original),
            ):
                with self.assertRaises(bundle.BundleBuildError):
                    bundle.copy_descriptor(
                        source_fd,
                        self.directory_fd,
                        self.destination.name,
                        0o755,
                        expected,
                    )
        finally:
            os.close(source_fd)
        self.assertEqual(self.external.read_bytes(), b"preserved")


if __name__ == "__main__":
    unittest.main()
