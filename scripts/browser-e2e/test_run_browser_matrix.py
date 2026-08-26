#!/usr/bin/env python3

import contextlib
import io
import json
import pathlib
import tempfile
import unittest

try:
    import run_browser_matrix as matrix
except ModuleNotFoundError:
    matrix = None


class MatrixAvailabilityTests(unittest.TestCase):
    def test_runner_module_exists(self):
        self.assertIsNotNone(matrix, "browser matrix runner is not implemented")


@unittest.skipIf(matrix is None, "browser matrix runner is not implemented")
class MatrixRunnerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(
            prefix="pickvia-matrix-test-", dir="/private/tmp"
        )
        self.root = pathlib.Path(self.temporary.name)
        self.manifest_path = self.root / "manifest.json"

    def tearDown(self):
        self.temporary.cleanup()

    def write_manifest(self, applications=None, **overrides):
        document = {
            "schemaVersion": 1,
            "applications": applications or [self.edge_application()],
        }
        document.update(overrides)
        self.manifest_path.write_text(json.dumps(document) + "\n", encoding="utf-8")
        return self.manifest_path

    def edge_application(self, **overrides):
        application = {
            "bundleIdentifier": "com.microsoft.edgemac",
            "applicationPath": "/Applications/Microsoft Edge.app",
            "executableRelativePath": "Contents/MacOS/Microsoft Edge",
            "profileStrategy": "chromium",
            "normalStrategy": "workspace",
            "browserPrivate": True,
            "profile": True,
            "profilePrivate": False,
            "skip": False,
        }
        application.update(overrides)
        return application

    def safari_application(self, **overrides):
        application = {
            "bundleIdentifier": "com.apple.Safari",
            "applicationPath": "/Applications/Safari.app",
            "executableRelativePath": "Contents/MacOS/Safari",
            "profileStrategy": "none",
            "normalStrategy": "workspace",
            "browserPrivate": False,
            "profile": False,
            "profilePrivate": False,
            "skip": True,
        }
        application.update(overrides)
        return application

    def test_manifest_rejects_unknown_schema_duplicate_and_unsafe_paths(self):
        invalid_documents = (
            {"schemaVersion": 2, "applications": [self.edge_application()]},
            {
                "schemaVersion": 1,
                "applications": [self.edge_application(), self.edge_application()],
            },
            {
                "schemaVersion": 1,
                "applications": [
                    self.edge_application(applicationPath="Applications/Edge.app")
                ],
            },
            {
                "schemaVersion": 1,
                "applications": [
                    self.edge_application(executableRelativePath="Contents/../outside")
                ],
            },
            {
                "schemaVersion": 1,
                "applications": [self.edge_application(unexpected=True)],
            },
        )
        for index, document in enumerate(invalid_documents):
            with self.subTest(index=index):
                path = self.root / f"invalid-{index}.json"
                path.write_text(json.dumps(document) + "\n", encoding="utf-8")
                with self.assertRaises(matrix.MatrixManifestError):
                    matrix.load_manifest(path)

    def test_manifest_rejects_duplicate_json_keys_and_nonfinite_values(self):
        for payload in (
            b'{"schemaVersion":1,"schemaVersion":1,"applications":[]}\n',
            b'{"schemaVersion":NaN,"applications":[]}\n',
            b'{"schemaVersion":1,"applications":[]} trailing\n',
        ):
            with self.subTest(payload=payload):
                self.manifest_path.write_bytes(payload)
                with self.assertRaises(matrix.MatrixManifestError):
                    matrix.load_manifest(self.manifest_path)

    def test_safari_and_technology_preview_must_be_forced_skip(self):
        for bundle_identifier in (
            "com.apple.Safari",
            "com.apple.SafariTechnologyPreview",
        ):
            safari = self.safari_application(
                bundleIdentifier=bundle_identifier,
                skip=False,
            )
            self.write_manifest([safari])
            with self.assertRaises(matrix.MatrixManifestError):
                matrix.load_manifest(self.manifest_path)

    def test_edge_pilot_is_first_and_three_state_then_remaining_cells_are_sequential(
        self,
    ):
        chrome = self.edge_application(
            bundleIdentifier="com.google.Chrome",
            applicationPath="/Applications/Google Chrome.app",
            executableRelativePath="Contents/MacOS/Google Chrome",
        )
        manifest = matrix.load_manifest(
            self.write_manifest([chrome, self.edge_application()])
        )
        cells = matrix.plan_cells(manifest, lambda _application: True)
        self.assertEqual(
            [
                (cell.bundle_identifier, cell.capability, cell.state)
                for cell in cells[:3]
            ],
            [
                ("com.microsoft.edgemac", "normal", "cold"),
                ("com.microsoft.edgemac", "normal", "running"),
                ("com.microsoft.edgemac", "normal", "reopen"),
            ],
        )
        self.assertEqual(len({cell.sequence for cell in cells}), len(cells))
        self.assertEqual([cell.sequence for cell in cells], list(range(len(cells))))

    def test_signature_blocker_is_not_run_and_stops_before_build_or_launch(self):
        dependencies = FakeDependencies(signature_ok=False)
        result = matrix.execute_matrix(
            matrix.load_manifest(self.write_manifest()),
            self.root / "output",
            dependencies=dependencies,
        )
        self.assertEqual(result.exit_code, matrix.MATRIX_BLOCKED)
        self.assertEqual(result.records[0]["result"], "NOT RUN")
        self.assertEqual(result.records[0]["detail"], "signature-blocker")
        self.assertEqual(dependencies.build_count, 0)
        self.assertEqual(dependencies.active_drivers, 0)

    def test_nonpilot_signature_blocker_does_not_borrow_or_stop_other_apps(self):
        chrome = self.edge_application(
            bundleIdentifier="com.google.Chrome",
            applicationPath="/Applications/Google Chrome.app",
            executableRelativePath="Contents/MacOS/Google Chrome",
        )
        dependencies = FakeDependencies(blocked_bundles={"com.google.Chrome"})
        result = matrix.execute_matrix(
            matrix.load_manifest(
                self.write_manifest([chrome, self.edge_application()])
            ),
            self.root / "output",
            dependencies=dependencies,
        )
        self.assertEqual(result.exit_code, matrix.MATRIX_BLOCKED)
        edge = [
            record
            for record in result.records
            if record["bundleIdentifier"] == "com.microsoft.edgemac"
        ]
        chrome_records = [
            record
            for record in result.records
            if record["bundleIdentifier"] == "com.google.Chrome"
        ]
        self.assertTrue(all(record["result"] == "PASS" for record in edge))
        self.assertTrue(all(record["result"] == "NOT RUN" for record in chrome_records))
        self.assertTrue(
            all(record["detail"] == "signature-blocker" for record in chrome_records)
        )

    def test_driver_invocations_use_fresh_secrets_and_never_overlap(self):
        dependencies = FakeDependencies()
        result = matrix.execute_matrix(
            matrix.load_manifest(self.write_manifest()),
            self.root / "output",
            dependencies=dependencies,
        )
        self.assertEqual(result.exit_code, 0)
        self.assertEqual(dependencies.max_active_drivers, 1)
        sessions = [call["session"] for call in dependencies.driver_calls]
        self.assertEqual(len(sessions), len(set(sessions)))
        self.assertTrue(all(len(session) >= 32 for session in sessions))
        self.assertEqual(dependencies.build_count, 1)

    def test_fresh_run_rejects_nonempty_output_without_overwriting_it(self):
        output = self.root / "output"
        output.mkdir(mode=0o700)
        sentinel = output / "preserve"
        sentinel.write_text("owned elsewhere", encoding="utf-8")
        with self.assertRaises(matrix.MatrixError):
            matrix.execute_matrix(
                matrix.load_manifest(self.write_manifest()),
                output,
                dependencies=FakeDependencies(),
            )
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "owned elsewhere")

    def test_driver_runtime_exception_is_sanitized_not_run_and_stops(self):
        dependencies = FakeDependencies(raise_on=("com.microsoft.edgemac", "cold"))
        result = matrix.execute_matrix(
            matrix.load_manifest(self.write_manifest()),
            self.root / "output",
            dependencies=dependencies,
        )
        self.assertEqual(result.exit_code, matrix.MATRIX_BLOCKED)
        self.assertEqual(result.records[0]["result"], "NOT RUN")
        self.assertEqual(result.records[0]["detail"], "harness-ambiguity")
        self.assertNotIn("synthetic secret", json.dumps(result.records))

    def test_untrusted_driver_outcome_and_version_are_never_written_to_evidence(self):
        dependencies = FakeDependencies(
            unsafe_outcome="/private/tmp/token-secret",
            unsafe_version="151.0\n/private/tmp/version-secret",
        )
        matrix.execute_matrix(
            matrix.load_manifest(self.write_manifest()),
            self.root / "output",
            dependencies=dependencies,
        )
        evidence = (self.root / "output" / "evidence.jsonl").read_text(encoding="utf-8")
        self.assertNotIn("/private/tmp", evidence)
        self.assertNotIn("token-secret", evidence)
        self.assertNotIn("version-secret", evidence)

    def test_edge_pilot_failure_stops_and_marks_later_cells_not_run(self):
        chrome = self.edge_application(
            bundleIdentifier="com.google.Chrome",
            applicationPath="/Applications/Google Chrome.app",
            executableRelativePath="Contents/MacOS/Google Chrome",
        )
        dependencies = FakeDependencies(fail_on=("com.microsoft.edgemac", "running"))
        result = matrix.execute_matrix(
            matrix.load_manifest(
                self.write_manifest([chrome, self.edge_application()])
            ),
            self.root / "output",
            dependencies=dependencies,
        )
        self.assertEqual(result.exit_code, matrix.MATRIX_PRODUCT_FAILURE)
        self.assertEqual(
            [record["result"] for record in result.records[:2]], ["PASS", "FAIL"]
        )
        self.assertTrue(
            all(record["result"] == "NOT RUN" for record in result.records[2:])
        )
        self.assertEqual(dependencies.max_active_drivers, 1)

    def test_harness_ambiguity_stops_without_becoming_capability_evidence(self):
        dependencies = FakeDependencies(ambiguous_on=("com.microsoft.edgemac", "cold"))
        result = matrix.execute_matrix(
            matrix.load_manifest(self.write_manifest()),
            self.root / "output",
            dependencies=dependencies,
        )
        self.assertEqual(result.exit_code, matrix.MATRIX_BLOCKED)
        self.assertEqual(result.records[0]["result"], "NOT RUN")
        self.assertEqual(result.records[0]["detail"], "harness-ambiguity")
        self.assertTrue(all(record["result"] == "NOT RUN" for record in result.records))

    def test_selected_without_observed_launch_provenance_can_never_pass(self):
        dependencies = FakeDependencies(omit_provenance=True)
        result = matrix.execute_matrix(
            matrix.load_manifest(self.write_manifest()),
            self.root / "output",
            dependencies=dependencies,
        )
        self.assertEqual(result.exit_code, matrix.MATRIX_BLOCKED)
        self.assertEqual(result.records[0]["result"], "NOT RUN")
        self.assertEqual(result.records[0]["provenance"], "none")

    def test_profile_cells_request_one_isolated_driver_owned_root(self):
        dependencies = FakeDependencies()
        matrix.execute_matrix(
            matrix.load_manifest(self.write_manifest()),
            self.root / "output",
            dependencies=dependencies,
        )
        profile_calls = [
            call for call in dependencies.driver_calls if call["profile_strategy"]
        ]
        self.assertTrue(profile_calls)
        self.assertTrue(all(call["create_profile"] for call in profile_calls))
        self.assertEqual(
            len({call["profile_relative_root"] for call in profile_calls}),
            len(profile_calls),
        )
        self.assertTrue(
            all(
                call["profile_relative_root"].startswith("profiles/")
                for call in profile_calls
            )
        )

    def test_evidence_is_sanitized_hash_chained_and_resume_skips_exact_completed_cells(
        self,
    ):
        output = self.root / "output"
        first_dependencies = FakeDependencies()
        first = matrix.execute_matrix(
            matrix.load_manifest(self.write_manifest()),
            output,
            dependencies=first_dependencies,
        )
        self.assertEqual(first.exit_code, 0)
        evidence = (output / "evidence.jsonl").read_text(encoding="utf-8")
        for forbidden in (
            "/Applications/",
            "/private/tmp/",
            "session",
            "token",
            "fifo",
            "pid",
        ):
            self.assertNotIn(forbidden, evidence.lower())
        records = [json.loads(line) for line in evidence.splitlines()]
        self.assertEqual(records[0]["recordType"], "run")
        self.assertTrue(all("recordHash" in record for record in records))

        resumed_dependencies = FakeDependencies()
        resumed = matrix.execute_matrix(
            matrix.load_manifest(self.manifest_path),
            output,
            dependencies=resumed_dependencies,
            resume=True,
        )
        self.assertEqual(resumed.exit_code, 0)
        self.assertEqual(resumed_dependencies.build_count, 0)
        self.assertEqual(resumed_dependencies.driver_calls, [])

        records[-1]["result"] = "FAIL"
        (output / "evidence.jsonl").write_text(
            "\n".join(json.dumps(record, sort_keys=True) for record in records) + "\n",
            encoding="utf-8",
        )
        with self.assertRaises(matrix.MatrixResumeError):
            matrix.execute_matrix(
                matrix.load_manifest(self.manifest_path),
                output,
                dependencies=FakeDependencies(),
                resume=True,
            )

    def test_resume_rejects_rehashed_cell_mismatch_and_extra_files(self):
        output = self.root / "output"
        matrix.execute_matrix(
            matrix.load_manifest(self.write_manifest()),
            output,
            dependencies=FakeDependencies(),
        )
        evidence_path = output / "evidence.jsonl"
        records = [
            json.loads(line)
            for line in evidence_path.read_text(encoding="utf-8").splitlines()
        ]
        records[1]["bundleIdentifier"] = "com.example.Substituted"
        previous = "0" * 64
        for record in records:
            record["previousHash"] = previous
            unhashed = dict(record)
            unhashed.pop("recordHash", None)
            record["recordHash"] = matrix._digest_json(unhashed)
            previous = record["recordHash"]
        evidence_path.write_text(
            "\n".join(
                json.dumps(record, separators=(",", ":"), sort_keys=True)
                for record in records
            )
            + "\n",
            encoding="utf-8",
        )
        with self.assertRaises(matrix.MatrixResumeError):
            matrix.execute_matrix(
                matrix.load_manifest(self.manifest_path),
                output,
                dependencies=FakeDependencies(),
                resume=True,
            )

        clean_output = self.root / "clean-output"
        matrix.execute_matrix(
            matrix.load_manifest(self.manifest_path),
            clean_output,
            dependencies=FakeDependencies(),
        )
        clean_output.joinpath("unexpected").write_text("preserve", encoding="utf-8")
        with self.assertRaises(matrix.MatrixResumeError):
            matrix.execute_matrix(
                matrix.load_manifest(self.manifest_path),
                clean_output,
                dependencies=FakeDependencies(),
                resume=True,
            )

    def test_dry_run_lists_only_installed_non_safari_cells_without_mutation(self):
        dependencies = FakeDependencies()
        manifest = matrix.load_manifest(
            self.write_manifest([self.edge_application(), self.safari_application()])
        )
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            result = matrix.dry_run(manifest, dependencies=dependencies)
        self.assertEqual(result, 0)
        self.assertIn("com.microsoft.edgemac", output.getvalue())
        self.assertNotIn("com.apple.Safari|", output.getvalue())
        self.assertEqual(dependencies.build_count, 0)
        self.assertEqual(dependencies.driver_calls, [])
        self.assertEqual(dependencies.created_paths, [])


class FakeDependencies:
    def __init__(
        self,
        *,
        signature_ok=True,
        fail_on=None,
        ambiguous_on=None,
        blocked_bundles=frozenset(),
        raise_on=None,
        unsafe_outcome=None,
        unsafe_version=None,
        omit_provenance=False,
    ):
        self.signature_ok = signature_ok
        self.fail_on = fail_on
        self.ambiguous_on = ambiguous_on
        self.blocked_bundles = set(blocked_bundles)
        self.raise_on = raise_on
        self.unsafe_outcome = unsafe_outcome
        self.unsafe_version = unsafe_version
        self.omit_provenance = omit_provenance
        self.build_count = 0
        self.driver_calls = []
        self.active_drivers = 0
        self.max_active_drivers = 0
        self.created_paths = []

    def is_installed(self, _application):
        return True

    def verify_application(self, _application):
        if (
            not self.signature_ok
            or _application.bundle_identifier in self.blocked_bundles
        ):
            raise matrix.MatrixIdentityError("blocked")
        return self.unsafe_version or "151.0"

    def build_and_pin(self):
        self.build_count += 1
        return object()

    def run_driver(self, _pinned_app, cell, session, profile_relative_root):
        self.active_drivers += 1
        self.max_active_drivers = max(self.max_active_drivers, self.active_drivers)
        try:
            if (cell.bundle_identifier, cell.state) == self.raise_on:
                raise RuntimeError("synthetic secret /private/tmp/driver")
            self.driver_calls.append(
                {
                    "bundle_identifier": cell.bundle_identifier,
                    "state": cell.state,
                    "session": session,
                    "profile_strategy": cell.profile_strategy
                    if cell.has_profile
                    else None,
                    "profile_relative_root": profile_relative_root,
                    "create_profile": bool(profile_relative_root),
                }
            )
            if (cell.bundle_identifier, cell.state) == self.ambiguous_on:
                return {
                    "outcome": "identity-ambiguous",
                    "total_elapsed_seconds": 0.1,
                    "route_timeout_seconds": 30.0,
                    "browser_cleanup_grace_seconds": 5.0,
                    "browser_quiescence_seconds": 2.0,
                }, matrix.DRIVER_AMBIGUOUS
            if (cell.bundle_identifier, cell.state) == self.fail_on:
                return {
                    "outcome": "launch-error",
                    "total_elapsed_seconds": 0.1,
                    "route_timeout_seconds": 30.0,
                    "browser_cleanup_grace_seconds": 5.0,
                    "browser_quiescence_seconds": 2.0,
                }, 10
            if self.unsafe_outcome is not None:
                return {
                    "outcome": self.unsafe_outcome,
                    "total_elapsed_seconds": 0.1,
                }, 14
            report = {
                "outcome": "selected",
                "token_received": True,
                "exact_process_identity": True,
                "exact_browser_process_identity": True,
                "total_elapsed_seconds": 0.1,
                "route_timeout_seconds": 30.0,
                "browser_cleanup_grace_seconds": 5.0,
                "browser_quiescence_seconds": 2.0,
            }
            if not self.omit_provenance:
                report["launch_provenance"] = "launch-observed"
            return report, 0
        finally:
            self.active_drivers -= 1


if __name__ == "__main__":
    unittest.main()
