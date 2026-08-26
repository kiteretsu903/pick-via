#!/usr/bin/env python3

import configparser
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


class SyntheticProfileCreatorTests(unittest.TestCase):
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
            environment = creator._minimal_environment(root)

            self.assertEqual(
                set(environment),
                {"PATH", "LANG", "LC_CTYPE", "TMPDIR", "HOME", "CFFIXED_USER_HOME"},
            )
            self.assertNotIn("SSH_AUTH_SOCK", environment)
            self.assertNotIn("GITHUB_TOKEN", environment)
            self.assertNotIn("AGENT_RUNTIME_SENTINEL", environment)

    def test_chromium_normalization_rejects_marker_replacement_before_write(self):
        with tempfile.TemporaryDirectory(
            prefix="pickvia-synthetic-normalization-"
        ) as temporary:
            root = pathlib.Path(temporary).resolve()
            root.chmod(0o700)
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
                if pathlib.Path(path) == marker and flags & os.O_WRONLY and not swapped:
                    swapped = True
                    marker.unlink()
                    replacement.rename(marker)
                return real_open(path, flags, *args, **kwargs)

            with mock.patch.object(creator.os, "open", side_effect=replace_before_open):
                with self.assertRaises(creator.SyntheticProfileError):
                    creator._normalize_chromium(root)

            self.assertEqual(marker.read_bytes(), b"replacement-preserved")

    def test_chromium_normalization_rejects_profile_symlink_without_mutation(self):
        with tempfile.TemporaryDirectory(
            prefix="pickvia-synthetic-profile-symlink-"
        ) as temporary:
            root = pathlib.Path(temporary).resolve()
            root.chmod(0o700)
            external = root.parent / f"external-profile-{os.getpid()}"
            external.mkdir(mode=0o755)
            try:
                (root / "PickVia E2E").symlink_to(external, target_is_directory=True)
                (root / "Local State").write_text(
                    '{"profile":{"info_cache":{"PickVia E2E":{"name":"Temporary"}}}}',
                    encoding="utf-8",
                )

                with self.assertRaises(creator.SyntheticProfileError):
                    creator._normalize_chromium(root)

                self.assertEqual(external.stat().st_mode & 0o777, 0o755)
            finally:
                external.rmdir()


if __name__ == "__main__":
    unittest.main()
