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

CHECKED_MANIFEST = (
    pathlib.Path(__file__).resolve().parent / "browser_matrix_manifest.json"
)


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

    def load_manifest(self, path=None):
        return matrix.load_manifest(
            path or self.manifest_path,
            enforce_required=False,
        )

    def checked_document(self):
        return json.loads(CHECKED_MANIFEST.read_text(encoding="utf-8"))

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

    def test_required_manifest_rejects_omitted_or_skipped_non_safari_apps(self):
        chrome_only = {
            "schemaVersion": 1,
            "applications": [
                self.edge_application(
                    bundleIdentifier="com.google.Chrome",
                    applicationPath="/Applications/Google Chrome.app",
                    executableRelativePath="Contents/MacOS/Google Chrome",
                )
            ],
        }
        self.manifest_path.write_text(json.dumps(chrome_only) + "\n", encoding="utf-8")
        with self.assertRaises(matrix.MatrixManifestError):
            matrix.load_manifest(self.manifest_path, enforce_required=True)

        for bundle_identifier in ("com.google.Chrome", "com.microsoft.edgemac"):
            with self.subTest(bundle_identifier=bundle_identifier):
                document = self.checked_document()
                application = next(
                    item
                    for item in document["applications"]
                    if item["bundleIdentifier"] == bundle_identifier
                )
                application["skip"] = True
                self.manifest_path.write_text(
                    json.dumps(document) + "\n", encoding="utf-8"
                )
                with self.assertRaises(matrix.MatrixManifestError):
                    matrix.load_manifest(self.manifest_path, enforce_required=True)

    def test_duckduckgo_normal_and_fire_cells_are_required_and_planned(self):
        manifest = matrix.load_manifest(CHECKED_MANIFEST, enforce_required=True)
        cells = matrix.plan_cells(manifest, lambda _application: True)
        duck = [
            cell
            for cell in cells
            if cell.bundle_identifier == "com.duckduckgo.macos.browser"
        ]
        self.assertEqual(
            [(cell.capability, cell.state, cell.mechanism) for cell in duck],
            [
                (capability, state, "duckduckgo")
                for capability in ("normal", "private")
                for state in ("cold", "running", "reopen")
            ],
        )

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

    def test_installed_absence_is_factual_not_run_evidence(self):
        chrome = self.edge_application(
            bundleIdentifier="com.google.Chrome",
            applicationPath="/Applications/Google Chrome.app",
            executableRelativePath="Contents/MacOS/Google Chrome",
        )
        dependencies = FakeDependencies()
        dependencies.is_installed = (
            lambda application: application.bundle_identifier != "com.google.Chrome"
        )
        result = matrix.execute_matrix(
            matrix.load_manifest(
                self.write_manifest([chrome, self.edge_application()])
            ),
            self.root / "output",
            dependencies=dependencies,
        )
        chrome_records = [
            record
            for record in result.records
            if record["bundleIdentifier"] == "com.google.Chrome"
        ]
        self.assertTrue(all(record["result"] == "NOT RUN" for record in chrome_records))
        self.assertTrue(
            all(record["detail"] == "installed-absence" for record in chrome_records)
        )

    def test_edge_pilot_installed_absence_stops_before_build(self):
        dependencies = FakeDependencies()
        dependencies.is_installed = (
            lambda application: application.bundle_identifier != "com.microsoft.edgemac"
        )
        result = matrix.execute_matrix(
            matrix.load_manifest(self.write_manifest()),
            self.root / "output",
            dependencies=dependencies,
        )
        self.assertEqual(result.exit_code, matrix.MATRIX_BLOCKED)
        self.assertEqual(result.records[0]["result"], "NOT RUN")
        self.assertEqual(result.records[0]["detail"], "installed-absence")
        self.assertEqual(dependencies.build_count, 0)

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
        self.assertTrue(
            all(
                len(set(sessions[index : index + 3])) == 1
                for index in range(0, len(sessions), 3)
            )
        )
        requests = [call["request"] for call in dependencies.driver_calls]
        self.assertEqual(len(requests), len(set(requests)))
        self.assertTrue(all(len(session) >= 32 for session in sessions))
        self.assertEqual(dependencies.build_count, 1)

    def test_pinned_e2e_identity_failure_closes_pin_and_finalizes_evidence(self):
        class PinnedFixture:
            closed = False

            def close(self):
                self.closed = True

        pinned = PinnedFixture()
        dependencies = FakeDependencies()
        dependencies.build_and_pin = lambda: pinned

        def fail_identity(_pinned):
            raise matrix.MatrixIdentityError("synthetic E2E identity blocker")

        dependencies.e2e_identity = fail_identity
        result = matrix.execute_matrix(
            matrix.load_manifest(self.write_manifest()),
            self.root / "output",
            dependencies=dependencies,
        )
        self.assertEqual(result.exit_code, matrix.MATRIX_BLOCKED)
        self.assertTrue(pinned.closed)
        self.assertTrue(all(record["result"] == "NOT RUN" for record in result.records))
        self.assertTrue(
            all(record["detail"] == "build-blocker" for record in result.records)
        )

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

    def test_driver_report_contract_rejects_missing_wrong_or_incoherent_proof(self):
        expectation = matrix.DriverProofExpectation(
            session="session_0123456789abcdef",
            request="request_0123456789abcdef",
            bundle_identifier="com.microsoft.edgemac",
            target_id="com.microsoft.edgemac||normal",
            capability="normal",
            state="cold",
            mode="normal",
            mechanism="workspace",
            e2e_app_identity="e" * 64,
            browser_app_identity="b" * 64,
        )
        valid = {
            "schemaVersion": 1,
            "session": expectation.session,
            "request": expectation.request,
            "bundleIdentifier": expectation.bundle_identifier,
            "targetID": expectation.target_id,
            "capability": expectation.capability,
            "state": expectation.state,
            "mode": expectation.mode,
            "mechanism": expectation.mechanism,
            "e2eAppIdentity": expectation.e2e_app_identity,
            "browserAppIdentity": expectation.browser_app_identity,
            "outcome": "selected",
            "token_received": True,
            "exact_process_identity": True,
            "exact_browser_process_identity": True,
            "launch_provenance": "launch-observed",
            "total_elapsed_seconds": 1.0,
            "route_timeout_seconds": 30.0,
            "browser_cleanup_grace_seconds": 5.0,
            "browser_quiescence_seconds": 2.0,
            "provenance_settle_seconds": 0.25,
            "provenance_status_grace_seconds": 1.0,
            "cleanup_success": True,
            "task_root_finalized": True,
            "stateProofs": [
                {
                    "state": expectation.state,
                    "request": expectation.request,
                    "outcome": "selected",
                    "receipt": True,
                    "e2eIdentity": True,
                    "browserIdentity": True,
                    "provenance": "launch-observed",
                    "processIdentifier": 9001,
                    "processStartSeconds": 1,
                    "processStartMicroseconds": 2,
                    "routeElapsedSeconds": 1.0,
                }
            ],
        }
        self.assertEqual(
            matrix.validate_driver_report(valid, 0, expectation)[0],
            "PASS",
        )
        mutations = (
            lambda report: report.pop("request"),
            lambda report: report.update(session="wrong_session_012345"),
            lambda report: report.update(request="wrong_request_012345"),
            lambda report: report.update(bundleIdentifier="com.example.Wrong"),
            lambda report: report.update(targetID="com.microsoft.edgemac||private"),
            lambda report: report.update(state="running"),
            lambda report: report.update(token_received=False),
            lambda report: report.update(launch_provenance="launch-error"),
            lambda report: report.update(total_elapsed_seconds=float("inf")),
            lambda report: report.update(browser_cleanup_grace_seconds=4.0),
            lambda report: report.update(browser_quiescence_seconds=3.0),
            lambda report: report.update(cleanup_success=False),
            lambda report: report.update(task_root_finalized=False),
            lambda report: report["stateProofs"][0].update(
                processStartMicroseconds=1_000_000
            ),
            lambda report: report.update(unexpected=True),
        )
        for mutate in mutations:
            with self.subTest(mutate=mutate):
                candidate = dict(valid)
                mutate(candidate)
                with self.assertRaises(matrix.DriverProofError):
                    matrix.validate_driver_report(candidate, 0, expectation)
        launch_error = dict(valid)
        launch_error.update(
            outcome="launch-error",
            token_received=False,
            exact_browser_process_identity=False,
            launch_provenance="launch-error",
        )
        launch_error["stateProofs"] = [dict(valid["stateProofs"][0])]
        launch_error["stateProofs"][0].update(
            outcome="launch-error",
            receipt=False,
            browserIdentity=False,
            provenance="launch-error",
            processIdentifier=None,
            processStartSeconds=None,
            processStartMicroseconds=None,
        )
        self.assertEqual(
            matrix.validate_driver_report(launch_error, 10, expectation)[0],
            "FAIL",
        )
        for mutate in (
            lambda report: report.update(exact_browser_process_identity=True),
            lambda report: report["stateProofs"][0].update(browserIdentity=True),
            lambda report: report.update(total_elapsed_seconds=0.5),
        ):
            candidate = json.loads(json.dumps(launch_error))
            mutate(candidate)
            with (
                self.subTest(launch_error_mutation=mutate),
                self.assertRaises(matrix.DriverProofError),
            ):
                matrix.validate_driver_report(candidate, 10, expectation)
        with self.assertRaises(matrix.DriverProofError):
            matrix.validate_driver_report(launch_error, 0, expectation)

    def test_sequence_report_rejects_forged_generation_request_and_cleanup(self):
        cells = matrix.plan_cells(
            matrix.load_manifest(self.write_manifest()), lambda _application: True
        )[:3]
        session = "session_0123456789abcdef"
        requests = (
            "request_cold_0123456789",
            "request_running_01234567",
            "request_reopen_012345678",
        )
        dependencies = FakeDependencies()
        valid = dependencies.sequence_report(
            cells, session, requests, "e" * 64, "b" * 64
        )
        expectations = tuple(
            matrix.DriverProofExpectation(
                session=session,
                request=request,
                bundle_identifier=cell.bundle_identifier,
                target_id=matrix._expected_target_id(cell),
                capability=cell.capability,
                state=cell.state,
                mode=cell.mode,
                mechanism=cell.mechanism,
                e2e_app_identity="e" * 64,
                browser_app_identity="b" * 64,
            )
            for cell, request in zip(cells, requests)
        )
        self.assertEqual(
            matrix.validate_driver_sequence_report(valid, 0, expectations),
            (("PASS", "proven-route"),) * 3,
        )
        mutations = (
            lambda report: report["stateProofs"][1].update(
                request="forged_request_0000"
            ),
            lambda report: report["stateProofs"][1].update(processStartSeconds=99),
            lambda report: report["stateProofs"][1].update(
                processStartMicroseconds=1_000_000
            ),
            lambda report: [
                proof.update(processStartMicroseconds=1_000_000)
                for proof in report["stateProofs"]
            ],
            lambda report: report["stateProofs"][2].update(processIdentifier=9001),
            lambda report: report.update(cleanup_success=False),
            lambda report: report.update(task_root_finalized=False),
            lambda report: report["stateProofs"].pop(),
            lambda report: report.update(total_elapsed_seconds=0.2),
        )
        for mutate in mutations:
            candidate = json.loads(json.dumps(valid))
            mutate(candidate)
            with (
                self.subTest(mutate=mutate),
                self.assertRaises(matrix.DriverProofError),
            ):
                matrix.validate_driver_sequence_report(candidate, 0, expectations)

        launch_error = json.loads(json.dumps(valid))
        launch_error["stateProofs"] = launch_error["stateProofs"][:2]
        launch_error["stateProofs"][-1].update(
            outcome="launch-error",
            receipt=False,
            browserIdentity=False,
            provenance="launch-error",
            processIdentifier=None,
            processStartSeconds=None,
            processStartMicroseconds=None,
        )
        launch_error.update(
            outcome="launch-error",
            token_received=False,
            exact_browser_process_identity=False,
            launch_provenance="launch-error",
        )
        self.assertEqual(
            matrix.validate_driver_sequence_report(launch_error, 10, expectations),
            (
                ("PASS", "proven-route"),
                ("FAIL", "product-route-failure"),
                ("NOT RUN", "blocked-after-sequence-failure"),
            ),
        )
        for mutate in (
            lambda report: report.update(token_received=True),
            lambda report: report.update(exact_browser_process_identity=True),
            lambda report: report["stateProofs"][-1].update(browserIdentity=True),
        ):
            candidate = json.loads(json.dumps(launch_error))
            mutate(candidate)
            with (
                self.subTest(sequence_launch_error_mutation=mutate),
                self.assertRaises(matrix.DriverProofError),
            ):
                matrix.validate_driver_sequence_report(candidate, 10, expectations)

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
            len(profile_calls) // 3,
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
        return matrix.VerifiedApplication(
            self.unsafe_version or "151.0",
            "b" * 64,
        )

    def build_and_pin(self):
        self.build_count += 1
        return object()

    def e2e_identity(self, _pinned_app):
        return "e" * 64

    def run_sequence(
        self,
        _pinned_app,
        group,
        session,
        requests,
        profile_relative_root,
        e2e_app_identity,
        browser_app_identity,
    ):
        self.active_drivers += 1
        self.max_active_drivers = max(self.max_active_drivers, self.active_drivers)
        try:
            if any(
                (item.bundle_identifier, item.state) == self.raise_on for item in group
            ):
                raise RuntimeError("synthetic secret /private/tmp/driver")
            for item, request in zip(group, requests):
                self.driver_calls.append(
                    {
                        "bundle_identifier": item.bundle_identifier,
                        "state": item.state,
                        "session": session,
                        "request": request,
                        "profile_strategy": item.profile_strategy
                        if item.has_profile
                        else None,
                        "profile_relative_root": profile_relative_root,
                        "create_profile": bool(profile_relative_root),
                    }
                )
            report = self.sequence_report(
                group, session, requests, e2e_app_identity, browser_app_identity
            )
            ambiguous_index = next(
                (
                    index
                    for index, item in enumerate(group)
                    if (item.bundle_identifier, item.state) == self.ambiguous_on
                ),
                None,
            )
            if ambiguous_index is not None:
                report["stateProofs"] = report["stateProofs"][:ambiguous_index]
                report.update(
                    outcome="state-sequence-error",
                    token_received=False,
                    exact_browser_process_identity=False,
                    launch_provenance="none",
                )
                return report, matrix.DRIVER_AMBIGUOUS
            failure_index = next(
                (
                    index
                    for index, item in enumerate(group)
                    if (item.bundle_identifier, item.state) == self.fail_on
                ),
                None,
            )
            if failure_index is not None:
                report["stateProofs"] = report["stateProofs"][: failure_index + 1]
                report["stateProofs"][-1].update(
                    outcome="launch-error",
                    receipt=False,
                    browserIdentity=False,
                    provenance="launch-error",
                    processIdentifier=None,
                    processStartSeconds=None,
                    processStartMicroseconds=None,
                )
                report.update(
                    outcome="launch-error",
                    token_received=False,
                    exact_browser_process_identity=False,
                    launch_provenance="launch-error",
                )
                return report, 10
            if self.unsafe_outcome is not None:
                report["outcome"] = self.unsafe_outcome
                return report, 14
            if not self.omit_provenance:
                return report, 0
            report["stateProofs"][0]["provenance"] = "none"
            report["launch_provenance"] = "none"
            return report, 0
        finally:
            self.active_drivers -= 1

    def sequence_report(
        self, group, session, requests, e2e_app_identity, browser_app_identity
    ):
        cell = group[0]
        target_id = (
            f"{cell.bundle_identifier}|PickVia E2E|{cell.mode}"
            if cell.has_profile and cell.profile_strategy == "chromium"
            else f"{cell.bundle_identifier}||{cell.mode}"
        )
        return {
            "schemaVersion": 1,
            "session": session,
            "request": requests[0],
            "bundleIdentifier": cell.bundle_identifier,
            "targetID": target_id,
            "capability": cell.capability,
            "state": "sequence",
            "mode": cell.mode,
            "mechanism": cell.mechanism,
            "e2eAppIdentity": e2e_app_identity,
            "browserAppIdentity": browser_app_identity,
            "outcome": "selected",
            "token_received": True,
            "exact_process_identity": True,
            "exact_browser_process_identity": True,
            "launch_provenance": "launch-observed",
            "total_elapsed_seconds": 0.3,
            "route_timeout_seconds": 30.0,
            "browser_cleanup_grace_seconds": 5.0,
            "browser_quiescence_seconds": 2.0,
            "provenance_settle_seconds": 0.25,
            "provenance_status_grace_seconds": 1.0,
            "cleanup_success": True,
            "task_root_finalized": True,
            "stateProofs": [
                {
                    "state": item.state,
                    "request": request,
                    "outcome": "selected",
                    "receipt": True,
                    "e2eIdentity": True,
                    "browserIdentity": True,
                    "provenance": "launch-observed",
                    "processIdentifier": 9001 if item.state != "reopen" else 9002,
                    "processStartSeconds": 1,
                    "processStartMicroseconds": 2,
                    "routeElapsedSeconds": 0.1,
                }
                for item, request in zip(group, requests)
            ],
        }


if __name__ == "__main__":
    unittest.main()
