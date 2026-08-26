#!/usr/bin/env python3

import configparser
import contextlib
import io
import json
import os
import pathlib
import plistlib
import signal
import subprocess
import tempfile
import unittest
from unittest import mock

import create_synthetic_profile as creator


SCRIPT = pathlib.Path(__file__).with_name("create_synthetic_profile.py")


_FAKE_BROWSER_SOURCE = r"""
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static volatile sig_atomic_t stopping = 0;
static void stop(int value) { (void)value; stopping = 1; }

static int make_directory(const char *path) {
  if (mkdir(path, 0700) == 0 || errno == EEXIST) return 0;
  return 1;
}

int main(int argc, char **argv) {
  signal(SIGTERM, stop);
  const char *root = NULL;
  const char *profile = NULL;
  int chromium_flags = 0;
  for (int index = 1; index < argc; index++) {
    if (strncmp(argv[index], "--user-data-dir=", 16) == 0) root = argv[index] + 16;
    if (strncmp(argv[index], "--profile-directory=", 20) == 0) profile = argv[index] + 20;
    if (strcmp(argv[index], "-CreateProfile") == 0 && index + 1 < argc) {
      const char *space = strchr(argv[index + 1], ' ');
      if (space != NULL) profile = space + 1;
    }
    if (strcmp(argv[index], "--no-first-run") == 0) chromium_flags |= 1;
    if (strcmp(argv[index], "--no-default-browser-check") == 0) chromium_flags |= 2;
    if (strcmp(argv[index], "--disable-sync") == 0) chromium_flags |= 4;
    if (strcmp(argv[index], "--disable-background-networking") == 0) chromium_flags |= 8;
    if (strcmp(argv[index], "about:blank") == 0) chromium_flags |= 16;
  }
  if (root != NULL && profile != NULL) {
    if (chromium_flags != 31) return 7;
    char profile_path[4096];
    char state_path[4096];
    if (snprintf(profile_path, sizeof(profile_path), "%s/%s", root, profile) < 0) return 2;
    if (snprintf(state_path, sizeof(state_path), "%s/Local State", root) < 0) return 2;
    if (make_directory(root) || make_directory(profile_path)) return 3;
    FILE *state = fopen(state_path, "w");
    if (state == NULL) return 4;
    fputs("{\"profile\":{\"info_cache\":{\"PickVia E2E\":{\"name\":\"Temporary\"}}}}", state);
    fclose(state);
    while (!stopping) usleep(10000);
    return 0;
  }
  if (profile != NULL) {
    if (make_directory(profile)) return 5;
    usleep(100000);
    return 0;
  }
  return 6;
}
"""


class SyntheticProfileFixture:
    def __init__(self, strategy="chromium", unsafe_root=None):
        self.strategy = strategy
        self.temporary = tempfile.TemporaryDirectory(
            prefix="pickvia-synthetic-profile-"
        )
        self.base = pathlib.Path(self.temporary.name).resolve()
        self.application = self.base / "Fake Browser.app"
        self.executable = self.application / "Contents" / "MacOS" / "Fake Browser"
        self.root = self.base / "synthetic-root"
        self.bundle_identifier = "test.pickvia.fake-browser"
        self._build_application()
        if unsafe_root == "nonempty":
            self.root.mkdir(mode=0o700)
            (self.root / "foreign").write_bytes(b"foreign")
        elif unsafe_root == "symlink":
            destination = self.base / "outside"
            destination.mkdir(mode=0o700)
            self.root.symlink_to(destination, target_is_directory=True)

    def _build_application(self):
        self.executable.parent.mkdir(parents=True)
        source = self.base / "fake_browser.c"
        source.write_text(_FAKE_BROWSER_SOURCE, encoding="utf-8")
        subprocess.run(
            [
                "/usr/bin/xcrun",
                "clang",
                "-std=c17",
                "-Wall",
                "-Wextra",
                "-Werror",
                str(source),
                "-o",
                str(self.executable),
            ],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        with (self.application / "Contents" / "Info.plist").open("wb") as handle:
            plistlib.dump(
                {
                    "CFBundleIdentifier": self.bundle_identifier,
                    "CFBundleExecutable": "Fake Browser",
                },
                handle,
            )
        subprocess.run(
            [
                "/usr/bin/codesign",
                "--force",
                "--sign",
                "-",
                str(self.application),
            ],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

    def run(self):
        return subprocess.run(
            [
                str(SCRIPT),
                "--application",
                str(self.application),
                "--executable",
                str(self.executable),
                "--bundle-identifier",
                self.bundle_identifier,
                "--strategy",
                self.strategy,
                "--root",
                str(self.root),
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=10,
            check=False,
        )

    def close(self):
        self.temporary.cleanup()

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        self.close()


class _CreatorProcessDouble:
    def __init__(self, wait_success=lambda _timeout: True, pid=9_001):
        self.process = mock.Mock()
        self.process.poll.return_value = None
        self.pid = pid
        self._wait_success = wait_success
        self.signals = []
        self.close_count = 0

    def terminate_bounded(self, *, term_timeout, kill_timeout):
        del term_timeout, kill_timeout
        self.signals.append("term")
        return True

    def wait_success(self, timeout):
        return self._wait_success(timeout)

    def close_streams(self):
        self.close_count += 1


class SyntheticProfileCreatorTests(unittest.TestCase):
    def test_pinned_application_rejects_same_path_executable_replacement(self):
        with SyntheticProfileFixture() as fixture:
            pinned = creator._pin_application(
                fixture.application,
                fixture.executable,
                fixture.bundle_identifier,
            )
            replacement = fixture.base / "replacement-executable"
            replacement.write_bytes(b"replacement")
            replacement.chmod(0o700)
            fixture.executable.unlink()
            replacement.rename(fixture.executable)
            try:
                with mock.patch.object(
                    creator.smoke_e2e_runtime.ExactProcess, "start"
                ) as start:
                    with self.assertRaises(creator.SyntheticProfileError):
                        creator._start_exact(pinned, [], {})
                start.assert_not_called()
            finally:
                pinned.close()

    def test_pinned_application_rejects_same_path_plist_replacement(self):
        with SyntheticProfileFixture() as fixture:
            pinned = creator._pin_application(
                fixture.application,
                fixture.executable,
                fixture.bundle_identifier,
            )
            plist = fixture.application / "Contents" / "Info.plist"
            replacement = fixture.base / "replacement.plist"
            replacement.write_bytes(plist.read_bytes())
            plist.unlink()
            replacement.rename(plist)
            try:
                with mock.patch.object(
                    creator.smoke_e2e_runtime.ExactProcess, "start"
                ) as start:
                    with self.assertRaises(creator.SyntheticProfileError):
                        creator._start_exact(pinned, [], {})
                start.assert_not_called()
            finally:
                pinned.close()

    def test_pinned_application_rejects_executable_ancestor_symlink_replacement(self):
        with SyntheticProfileFixture() as fixture:
            pinned = creator._pin_application(
                fixture.application,
                fixture.executable,
                fixture.bundle_identifier,
            )
            macos = fixture.application / "Contents" / "MacOS"
            moved = fixture.base / "moved-macos"
            macos.rename(moved)
            macos.symlink_to(moved, target_is_directory=True)
            try:
                with mock.patch.object(
                    creator.smoke_e2e_runtime.ExactProcess, "start"
                ) as start:
                    with self.assertRaises(creator.SyntheticProfileError):
                        creator._start_exact(pinned, [], {})
                start.assert_not_called()
            finally:
                pinned.close()

    def test_application_update_race_after_start_grants_no_signal_authority(self):
        for replaced_entry in ("executable", "plist"):
            with self.subTest(replaced_entry=replaced_entry):
                with SyntheticProfileFixture() as fixture:
                    pinned = creator._pin_application(
                        fixture.application,
                        fixture.executable,
                        fixture.bundle_identifier,
                    )
                    process = _CreatorProcessDouble()

                    def replace_and_return(*_args, **_kwargs):
                        if replaced_entry == "executable":
                            path = fixture.executable
                            contents = b"replacement"
                        else:
                            path = fixture.application / "Contents" / "Info.plist"
                            contents = path.read_bytes()
                        replacement = fixture.base / f"replacement-{replaced_entry}"
                        replacement.write_bytes(contents)
                        replacement.chmod(path.stat().st_mode & 0o777)
                        path.unlink()
                        replacement.rename(path)
                        return process

                    try:
                        with (
                            mock.patch.object(
                                creator.smoke_e2e_runtime.ExactProcess,
                                "start",
                                side_effect=replace_and_return,
                            ),
                            mock.patch.object(
                                creator.browser_driver,
                                "_validate_running_browser_code",
                            ) as attest,
                        ):
                            with self.assertRaises(creator.SyntheticProfileError):
                                creator._start_exact(pinned, [], {})
                        attest.assert_not_called()
                        self.assertEqual(process.signals, [])
                        self.assertEqual(process.close_count, 1)
                    finally:
                        pinned.close()

    def test_mismatched_live_code_grants_no_signal_authority(self):
        with SyntheticProfileFixture() as fixture:
            pinned = creator._pin_application(
                fixture.application,
                fixture.executable,
                fixture.bundle_identifier,
            )
            process = _CreatorProcessDouble()
            try:
                with (
                    mock.patch.object(
                        creator.smoke_e2e_runtime.ExactProcess,
                        "start",
                        return_value=process,
                    ),
                    mock.patch.object(
                        creator.browser_driver,
                        "_validate_running_browser_code",
                        side_effect=RuntimeError("mismatched live code"),
                    ),
                ):
                    with self.assertRaises(creator.SyntheticProfileError):
                        creator._start_exact(pinned, [], {})
                self.assertEqual(process.signals, [])
                self.assertEqual(process.close_count, 1)
            finally:
                pinned.close()

    def test_chromium_creator_uses_isolated_user_data_and_one_profile(self):
        with SyntheticProfileFixture(strategy="chromium") as fixture:
            result = fixture.run()

            self.assertEqual(result.returncode, 0, result.stderr)
            state = json.loads(
                (fixture.root / "Local State").read_text(encoding="utf-8")
            )
            self.assertEqual(
                state["profile"]["info_cache"],
                {"PickVia E2E": {"name": "PickVia E2E"}},
            )
            self.assertTrue((fixture.root / "PickVia E2E").is_dir())
            self.assertEqual((fixture.root.stat().st_mode & 0o777), 0o700)
            self.assertEqual(
                (fixture.root / "PickVia E2E").stat().st_mode & 0o777, 0o700
            )
            self.assertEqual(
                (fixture.root / "Local State").stat().st_mode & 0o777, 0o600
            )

    def test_firefox_creator_uses_create_profile_and_one_profiles_ini_entry(self):
        with SyntheticProfileFixture(strategy="firefox") as fixture:
            result = fixture.run()

            self.assertEqual(result.returncode, 0, result.stderr)
            parser = configparser.ConfigParser()
            parser.read(fixture.root / "profiles.ini", encoding="utf-8")
            sections = [
                name for name in parser.sections() if name.startswith("Profile")
            ]
            self.assertEqual(sections, ["Profile0"])
            self.assertEqual(parser["Profile0"]["Name"], "PickVia E2E")
            self.assertEqual(parser["Profile0"]["Path"], "PickVia E2E")
            self.assertEqual(
                (fixture.root / "profiles.ini").stat().st_mode & 0o777, 0o600
            )

    def test_creator_rejects_existing_nonempty_or_symlink_root(self):
        for unsafe_kind in ("nonempty", "symlink"):
            with (
                self.subTest(unsafe_kind=unsafe_kind),
                SyntheticProfileFixture(unsafe_root=unsafe_kind) as fixture,
            ):
                self.assertNotEqual(fixture.run().returncode, 0)

    def test_creator_does_not_signal_preexisting_process(self):
        preexisting = subprocess.Popen(["/bin/sleep", "30"])
        try:
            with SyntheticProfileFixture(strategy="chromium") as fixture:
                result = fixture.run()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIsNone(preexisting.poll())
        finally:
            if preexisting.poll() is None:
                os.kill(preexisting.pid, signal.SIGTERM)
            preexisting.wait(timeout=2)

    def test_creator_never_emits_profile_path_or_label(self):
        with SyntheticProfileFixture(strategy="chromium") as fixture:
            result = fixture.run()
            output = result.stdout + result.stderr

            self.assertNotIn(str(fixture.root).encode(), output)
            self.assertNotIn(b"PickVia E2E", output)

    def test_browser_child_environment_is_fixed_and_excludes_parent_secrets(self):
        with tempfile.TemporaryDirectory(
            prefix="pickvia-synthetic-environment-"
        ) as temporary:
            root = pathlib.Path(temporary).resolve()
            root.chmod(0o700)
            synthetic_root = root / "synthetic-root"
            pinned = creator._prepare_root(synthetic_root)
            try:
                environment = creator._minimal_environment(pinned)
            finally:
                pinned.close()

            self.assertEqual(
                set(environment),
                {"PATH", "LANG", "LC_CTYPE", "TMPDIR", "HOME", "CFFIXED_USER_HOME"},
            )
            self.assertNotIn("SSH_AUTH_SOCK", environment)
            self.assertNotIn("GITHUB_TOKEN", environment)
            self.assertNotIn("AGENT_RUNTIME_SENTINEL", environment)

    def test_prepared_root_replacement_is_rejected_before_environment_mutation(self):
        with tempfile.TemporaryDirectory(
            prefix="pickvia-synthetic-root-pin-"
        ) as temporary:
            parent = pathlib.Path(temporary).resolve()
            root = parent / "root"
            pinned = creator._prepare_root(root)
            original = parent / "original"
            root.rename(original)
            root.mkdir(mode=0o700)
            replacement_marker = root / "replacement"
            replacement_marker.write_bytes(b"preserved")
            try:
                with self.assertRaises(creator.SyntheticProfileError):
                    creator._minimal_environment(pinned)
                self.assertEqual(replacement_marker.read_bytes(), b"preserved")
                self.assertFalse((root / ".creator-home").exists())
            finally:
                pinned.close()

    def test_chromium_replacement_after_child_is_not_normalized(self):
        with tempfile.TemporaryDirectory(
            prefix="pickvia-synthetic-chromium-pin-"
        ) as temporary:
            parent = pathlib.Path(temporary).resolve()
            root = parent / "root"
            pinned = creator._prepare_root(root)
            environment = creator._minimal_environment(pinned)
            process = _CreatorProcessDouble()
            replacement_contents = (
                b'{"profile":{"info_cache":{"PickVia E2E":{"name":"Replacement"}}}}'
            )

            def replace_after_child(*_args):
                root.rename(parent / "original")
                root.mkdir(mode=0o700)
                (root / "PickVia E2E").mkdir(mode=0o755)
                (root / "Local State").write_bytes(replacement_contents)

            try:
                with (
                    mock.patch.object(creator, "_start_exact", return_value=process),
                    mock.patch.object(
                        creator,
                        "_wait_for_chromium_profile",
                        side_effect=replace_after_child,
                    ),
                ):
                    with self.assertRaises(creator.SyntheticProfileError):
                        creator._create_chromium(
                            pinned,
                            pathlib.Path("/private/tmp/fake-browser"),
                            environment,
                        )
                self.assertEqual(
                    (root / "Local State").read_bytes(), replacement_contents
                )
                self.assertEqual((root / "PickVia E2E").stat().st_mode & 0o777, 0o755)
                self.assertEqual(process.signals, ["term"])
            finally:
                pinned.close()

    def test_firefox_replacement_after_child_is_not_mutated(self):
        with tempfile.TemporaryDirectory(
            prefix="pickvia-synthetic-firefox-pin-"
        ) as temporary:
            parent = pathlib.Path(temporary).resolve()
            root = parent / "root"
            pinned = creator._prepare_root(root)
            environment = creator._minimal_environment(pinned)

            def replace_and_finish(_timeout):
                root.rename(parent / "original")
                root.mkdir(mode=0o700)
                (root / "PickVia E2E").mkdir(mode=0o755)
                (root / "replacement").write_bytes(b"preserved")
                return True

            process = _CreatorProcessDouble(wait_success=replace_and_finish)
            try:
                with mock.patch.object(creator, "_start_exact", return_value=process):
                    with self.assertRaises(creator.SyntheticProfileError):
                        creator._create_firefox(
                            pinned,
                            pathlib.Path("/private/tmp/fake-browser"),
                            environment,
                        )
                self.assertEqual((root / "replacement").read_bytes(), b"preserved")
                self.assertEqual((root / "PickVia E2E").stat().st_mode & 0o777, 0o755)
                self.assertFalse((root / "profiles.ini").exists())
                self.assertEqual(process.signals, [])
            finally:
                pinned.close()

    def test_malformed_cli_uses_fixed_sanitized_argument_stage(self):
        secret = "/private/tmp/sensitive-PickVia E2E-profile"
        cases = [
            [f"--unknown={secret}"],
            ["--strategy", secret],
            ["--application", secret],
        ]
        for arguments in cases:
            with self.subTest(arguments=arguments):
                result = subprocess.run(
                    [str(SCRIPT), *arguments],
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    timeout=5,
                    check=False,
                )
                output = result.stdout + result.stderr
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(output, b"synthetic-profile-error:arguments\n")
                self.assertNotIn(secret.encode(), output)
                self.assertNotIn(b"PickVia E2E", output)

    def test_arbitrary_runtime_exception_text_uses_fixed_creation_stage(self):
        secret = "/private/tmp/sensitive-PickVia E2E-runtime"
        stderr = io.StringIO()
        with (
            mock.patch.object(creator, "_arguments", return_value=object()),
            mock.patch.object(
                creator,
                "create_synthetic_profile",
                side_effect=RuntimeError(secret),
            ),
            contextlib.redirect_stderr(stderr),
        ):
            result = creator.main([])

        self.assertEqual(result, 1)
        self.assertEqual(stderr.getvalue(), "synthetic-profile-error:creation\n")
        self.assertNotIn(secret, stderr.getvalue())

    def test_chromium_normalization_rejects_marker_replacement_before_write(self):
        with tempfile.TemporaryDirectory(
            prefix="pickvia-synthetic-normalization-"
        ) as temporary:
            root = pathlib.Path(temporary).resolve()
            root = root / "root"
            pinned = creator._prepare_root(root)
            (root / "PickVia E2E").mkdir(mode=0o700)
            marker = root / "Local State"
            marker.write_text(
                '{"profile":{"info_cache":{"PickVia E2E":{"name":"Temporary"}}}}',
                encoding="utf-8",
            )
            replacement = root / "replacement"
            replacement.write_bytes(b"replacement-preserved")
            real_open = os.open
            swapped = False

            def replace_before_open(path, flags, *args, **kwargs):
                nonlocal swapped
                if (
                    os.fspath(path) == "Local State"
                    and flags & os.O_WRONLY
                    and not swapped
                ):
                    swapped = True
                    directory = kwargs["dir_fd"]
                    os.unlink("Local State", dir_fd=directory)
                    os.rename(
                        "replacement",
                        "Local State",
                        src_dir_fd=directory,
                        dst_dir_fd=directory,
                    )
                return real_open(path, flags, *args, **kwargs)

            try:
                with mock.patch.object(
                    creator.os, "open", side_effect=replace_before_open
                ):
                    with self.assertRaises(creator.SyntheticProfileError):
                        creator._normalize_chromium(pinned)

                self.assertEqual(marker.read_bytes(), b"replacement-preserved")
            finally:
                pinned.close()

    def test_chromium_normalization_rejects_profile_symlink_without_mutation(self):
        with tempfile.TemporaryDirectory(
            prefix="pickvia-synthetic-profile-symlink-"
        ) as temporary:
            root = pathlib.Path(temporary).resolve()
            root = root / "root"
            pinned = creator._prepare_root(root)
            external = root.parent / f"external-profile-{os.getpid()}"
            external.mkdir(mode=0o755)
            try:
                (root / "PickVia E2E").symlink_to(external, target_is_directory=True)
                (root / "Local State").write_text(
                    '{"profile":{"info_cache":{"PickVia E2E":{"name":"Temporary"}}}}',
                    encoding="utf-8",
                )

                with self.assertRaises(creator.SyntheticProfileError):
                    creator._normalize_chromium(pinned)

                self.assertEqual(external.stat().st_mode & 0o777, 0o755)
            finally:
                pinned.close()
                external.rmdir()

    def test_chromium_normalization_rejects_duplicates_and_nonfinite_values(self):
        invalid_documents = (
            b'{"profile":{"info_cache":{"PickVia E2E":{"name":"a","name":"b"}}}}',
            b'{"profile":{"info_cache":{"PickVia E2E":{"name":NaN}}}}',
            b'{"profile":{"info_cache":{"PickVia E2E":{"name":Infinity}}}}',
            b'{"profile":{"info_cache":{"PickVia E2E":{"name":-Infinity}}}}',
        )
        for document in invalid_documents:
            with self.subTest(document=document):
                with tempfile.TemporaryDirectory(
                    prefix="pickvia-synthetic-local-state-"
                ) as temporary:
                    root = pathlib.Path(temporary).resolve() / "root"
                    pinned = creator._prepare_root(root)
                    (root / "PickVia E2E").mkdir(mode=0o700)
                    marker = root / "Local State"
                    marker.write_bytes(document)
                    try:
                        with self.assertRaises(creator.SyntheticProfileError):
                            creator._normalize_chromium(pinned)
                        self.assertEqual(marker.read_bytes(), document)
                    finally:
                        pinned.close()

    def test_chromium_normalization_writes_exact_canonical_json(self):
        with tempfile.TemporaryDirectory(
            prefix="pickvia-synthetic-local-state-canonical-"
        ) as temporary:
            root = pathlib.Path(temporary).resolve() / "root"
            pinned = creator._prepare_root(root)
            (root / "PickVia E2E").mkdir(mode=0o700)
            marker = root / "Local State"
            marker.write_bytes(
                b'{ "z": 1, "profile": {"info_cache": {'
                b'"PickVia E2E": {"name": "Temporary", "a": 2}}}}'
            )
            try:
                creator._normalize_chromium(pinned)
                self.assertEqual(
                    marker.read_bytes(),
                    b'{"profile":{"info_cache":{"PickVia E2E":'
                    b'{"a":2,"name":"PickVia E2E"}}},"z":1}',
                )
            finally:
                pinned.close()

    def test_firefox_profiles_final_content_must_match_canonical_bytes(self):
        with tempfile.TemporaryDirectory(
            prefix="pickvia-synthetic-firefox-content-"
        ) as temporary:
            root = pathlib.Path(temporary).resolve() / "root"
            pinned = creator._prepare_root(root)
            (root / "PickVia E2E").mkdir(mode=0o700)
            real_fsync = os.fsync

            def replace_with_same_length(descriptor):
                real_fsync(descriptor)
                expected = creator._firefox_profiles_contents()
                os.lseek(descriptor, 0, os.SEEK_SET)
                os.write(descriptor, b"X" * len(expected))
                real_fsync(descriptor)

            try:
                with mock.patch.object(
                    creator.os, "fsync", side_effect=replace_with_same_length
                ):
                    with self.assertRaises(creator.SyntheticProfileError):
                        creator._write_firefox_profiles(pinned)
                self.assertEqual(
                    (root / "profiles.ini").read_bytes(),
                    b"X" * len(creator._firefox_profiles_contents()),
                )
            finally:
                pinned.close()


if __name__ == "__main__":
    unittest.main()
