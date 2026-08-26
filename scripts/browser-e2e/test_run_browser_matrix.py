#!/usr/bin/env python3

import contextlib
import hashlib
import io
import json
import os
import pathlib
import plistlib
import tempfile
import unittest
from unittest import mock

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

    def read_evidence(self, output):
        return [
            json.loads(line)
            for line in output.joinpath("evidence.jsonl")
            .read_text(encoding="utf-8")
            .splitlines()
        ]

    def write_rehashed_evidence(self, output, records):
        previous = "0" * 64
        for record in records:
            record["previousHash"] = previous
            unhashed = dict(record)
            unhashed.pop("recordHash", None)
            record["recordHash"] = matrix._digest_json(unhashed)
            previous = record["recordHash"]
        output.joinpath("evidence.jsonl").write_text(
            "\n".join(
                json.dumps(record, separators=(",", ":"), sort_keys=True)
                for record in records
            )
            + "\n",
            encoding="utf-8",
        )

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

    def test_manifest_rejects_symlink_and_parent_replacement_during_read(self):
        outside = self.root / "outside-manifest.json"
        outside.write_text(
            json.dumps({"schemaVersion": 1, "applications": [self.edge_application()]})
            + "\n",
            encoding="utf-8",
        )
        linked = self.root / "linked-manifest.json"
        linked.symlink_to(outside)
        with self.assertRaises(matrix.MatrixManifestError):
            matrix.load_manifest(linked)

        parent = self.root / "manifest-parent"
        parent.mkdir()
        manifest = parent / "manifest.json"
        manifest.write_bytes(outside.read_bytes())
        displaced = self.root / "manifest-parent-displaced"
        real_read = os.read
        attacked = False

        def replace_parent(descriptor, count):
            nonlocal attacked
            if not attacked:
                attacked = True
                parent.rename(displaced)
                parent.mkdir()
                (parent / "manifest.json").write_bytes(outside.read_bytes())
            return real_read(descriptor, count)

        with (
            mock.patch.object(matrix.os, "read", side_effect=replace_parent),
            self.assertRaises(matrix.MatrixManifestError),
        ):
            matrix.load_manifest(manifest)

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
        self.assertEqual(len(sessions), len(set(sessions)))
        self.assertTrue(
            all(
                len(set(sessions[index : index + 3])) == 3
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

    def test_browser_static_identity_change_before_sequence_stops_without_driver(self):
        dependencies = FakeDependencies(static_change_phase="pre")
        result = matrix.execute_matrix(
            matrix.load_manifest(self.write_manifest()),
            self.root / "output",
            dependencies=dependencies,
        )
        self.assertEqual(result.exit_code, matrix.MATRIX_BLOCKED)
        self.assertEqual(dependencies.driver_calls, [])
        self.assertTrue(all(record["result"] == "NOT RUN" for record in result.records))
        self.assertEqual(result.records[0]["detail"], "browser-identity-changed")
        self.assertEqual(result.records[0]["installedVersion"], "unavailable")

    def test_edge_pilot_reverification_failure_is_signature_blocker_not_change(self):
        dependencies = FakeDependencies(verification_failure_phase="pre")
        result = matrix.execute_matrix(
            matrix.load_manifest(self.write_manifest()),
            self.root / "output",
            dependencies=dependencies,
        )
        self.assertEqual(result.exit_code, matrix.MATRIX_BLOCKED)
        self.assertEqual(dependencies.driver_calls, [])
        edge_pilot = result.records[:3]
        tail = result.records[3:]
        self.assertTrue(all(record["result"] == "NOT RUN" for record in result.records))
        self.assertTrue(
            all(record["detail"] == "signature-blocker" for record in edge_pilot)
        )
        self.assertTrue(
            all(record["detail"] == "blocked-before-run" for record in tail)
        )

    def test_postroute_reverification_failure_discards_proof_as_signature_blocker(self):
        chrome = self.edge_application(
            bundleIdentifier="com.google.Chrome",
            applicationPath="/Applications/Google Chrome.app",
            executableRelativePath="Contents/MacOS/Google Chrome",
        )
        dependencies = FakeDependencies(verification_failure_phase="post")
        result = matrix.execute_matrix(
            matrix.load_manifest(
                self.write_manifest([chrome, self.edge_application()])
            ),
            self.root / "output",
            dependencies=dependencies,
        )
        self.assertEqual(result.exit_code, matrix.MATRIX_BLOCKED)
        self.assertTrue(dependencies.driver_calls)
        edge = result.records[:3]
        tail = result.records[3:]
        self.assertTrue(all(record["result"] == "NOT RUN" for record in edge))
        self.assertTrue(all(record["detail"] == "signature-blocker" for record in edge))
        self.assertTrue(all(record["result"] == "NOT RUN" for record in tail))
        self.assertTrue(
            all(record["detail"] == "blocked-after-ambiguity" for record in tail)
        )

    def test_postroute_signature_blocker_preserves_only_authenticated_finalization(
        self,
    ):
        class FinalizationDependencies(FakeDependencies):
            def __init__(self, finalized):
                super().__init__(verification_failure_phase="post")
                self.finalized = finalized

            def run_sequence(self, *args, **kwargs):
                report, return_code = super().run_sequence(*args, **kwargs)
                return report, return_code, self.finalized

        chrome = self.edge_application(
            bundleIdentifier="com.google.Chrome",
            applicationPath="/Applications/Google Chrome.app",
            executableRelativePath="Contents/MacOS/Google Chrome",
        )
        for finalized in (True, False):
            with self.subTest(finalized=finalized):
                result = matrix.execute_matrix(
                    matrix.load_manifest(
                        self.write_manifest([chrome, self.edge_application()])
                    ),
                    self.root / f"post-signature-{finalized}",
                    dependencies=FinalizationDependencies(finalized),
                )
                pilot = result.records[:3]
                tail = result.records[3:]
                self.assertTrue(
                    all(record["detail"] == "signature-blocker" for record in pilot)
                )
                self.assertTrue(
                    all(record["taskRootFinalized"] is finalized for record in pilot)
                )
                self.assertTrue(
                    all(
                        record.get("taskFinalizationSource")
                        == (
                            matrix._AUTHENTICATED_FINALIZATION_SOURCE
                            if finalized
                            else None
                        )
                        for record in pilot
                    )
                )
                self.assertTrue(
                    all(record["taskRootFinalized"] is False for record in tail)
                )
                self.assertTrue(
                    all(
                        ("taskFinalizationProof" in record) is finalized
                        for record in pilot
                    )
                )
                self.assertTrue(
                    all("taskFinalizationProof" not in record for record in tail)
                )
                if finalized:
                    resume_dependencies = FakeDependencies()
                    resumed = matrix.execute_matrix(
                        matrix.load_manifest(self.manifest_path),
                        self.root / f"post-signature-{finalized}",
                        dependencies=resume_dependencies,
                        resume=True,
                    )
                    self.assertEqual(resumed.exit_code, matrix.MATRIX_BLOCKED)
                    self.assertEqual(resume_dependencies.driver_calls, [])

    def test_browser_static_identity_change_after_sequence_discards_stale_evidence(
        self,
    ):
        dependencies = FakeDependencies(static_change_phase="post")
        result = matrix.execute_matrix(
            matrix.load_manifest(self.write_manifest()),
            self.root / "output",
            dependencies=dependencies,
        )
        self.assertEqual(result.exit_code, matrix.MATRIX_BLOCKED)
        self.assertTrue(dependencies.driver_calls)
        self.assertTrue(all(record["result"] == "NOT RUN" for record in result.records))
        self.assertEqual(result.records[0]["detail"], "browser-identity-changed")
        self.assertEqual(result.records[0]["installedVersion"], "unavailable")

    def test_postroute_static_change_preserves_only_authenticated_finalization(self):
        class FinalizationDependencies(FakeDependencies):
            def __init__(self, finalized):
                super().__init__(static_change_phase="post")
                self.finalized = finalized

            def run_sequence(self, *args, **kwargs):
                report, return_code = super().run_sequence(*args, **kwargs)
                return report, return_code, self.finalized

        chrome = self.edge_application(
            bundleIdentifier="com.google.Chrome",
            applicationPath="/Applications/Google Chrome.app",
            executableRelativePath="Contents/MacOS/Google Chrome",
        )
        for finalized in (True, False):
            with self.subTest(finalized=finalized):
                result = matrix.execute_matrix(
                    matrix.load_manifest(
                        self.write_manifest([chrome, self.edge_application()])
                    ),
                    self.root / f"post-static-{finalized}",
                    dependencies=FinalizationDependencies(finalized),
                )
                pilot = result.records[:3]
                tail = result.records[3:]
                self.assertTrue(
                    all(
                        record["detail"] == "browser-identity-changed"
                        for record in pilot
                    )
                )
                self.assertTrue(
                    all(record["taskRootFinalized"] is finalized for record in pilot)
                )
                self.assertTrue(
                    all(
                        record.get("taskFinalizationSource")
                        == (
                            matrix._AUTHENTICATED_FINALIZATION_SOURCE
                            if finalized
                            else None
                        )
                        for record in pilot
                    )
                )
                self.assertTrue(
                    all(record["taskRootFinalized"] is False for record in tail)
                )
                self.assertTrue(
                    all(
                        ("taskFinalizationProof" in record) is finalized
                        for record in pilot
                    )
                )
                self.assertTrue(
                    all("taskFinalizationProof" not in record for record in tail)
                )

    def test_preroute_blocker_and_rehashed_resume_forgery_cannot_claim_finalization(
        self,
    ):
        output = self.root / "preroute-finalization-forgery"
        result = matrix.execute_matrix(
            matrix.load_manifest(self.write_manifest()),
            output,
            dependencies=FakeDependencies(verification_failure_phase="pre"),
        )
        self.assertTrue(
            all(record["taskRootFinalized"] is False for record in result.records)
        )
        evidence_path = output / "evidence.jsonl"
        records = [
            json.loads(line)
            for line in evidence_path.read_text(encoding="utf-8").splitlines()
        ]
        for record in records[1:4]:
            record["taskRootFinalized"] = True
            record["taskFinalizationSource"] = matrix._AUTHENTICATED_FINALIZATION_SOURCE
        self.write_rehashed_evidence(output, records)
        resume_dependencies = FakeDependencies()
        with self.assertRaises(matrix.MatrixResumeError):
            matrix.execute_matrix(
                matrix.load_manifest(self.manifest_path),
                output,
                dependencies=resume_dependencies,
                resume=True,
            )
        self.assertEqual(resume_dependencies.build_count, 0)
        self.assertEqual(resume_dependencies.driver_calls, [])

    def test_finalization_proof_binds_success_failure_and_postroute_groups(self):
        class AuthenticatedDependencies(FakeDependencies):
            def run_sequence(self, *args, **kwargs):
                report, return_code = super().run_sequence(*args, **kwargs)
                return report, return_code, True

        chrome = self.edge_application(
            bundleIdentifier="com.google.Chrome",
            applicationPath="/Applications/Google Chrome.app",
            executableRelativePath="Contents/MacOS/Google Chrome",
        )
        manifest = matrix.load_manifest(
            self.write_manifest([chrome, self.edge_application()])
        )
        output = self.root / "bound-groups"
        result = matrix.execute_matrix(
            manifest,
            output,
            dependencies=AuthenticatedDependencies(
                fail_on=("com.google.Chrome", "cold")
            ),
        )
        self.assertEqual(result.exit_code, matrix.MATRIX_PRODUCT_FAILURE)
        records = self.read_evidence(output)[1:]
        for offset in range(0, 6, 3):
            group = records[offset : offset + 3]
            proofs = {record.get("taskFinalizationProof") for record in group}
            self.assertEqual(len(proofs), 1)
            self.assertRegex(proofs.pop(), r"\A[0-9a-f]{64}\Z")
            self.assertTrue(all(record["taskRootFinalized"] for record in group))
        self.assertNotEqual(
            records[0]["taskFinalizationProof"],
            records[3]["taskFinalizationProof"],
        )

    def test_finalization_proof_context_binds_exact_ordered_cell_identity(self):
        output = self.root / "exact-cell-identity"
        manifest = matrix.load_manifest(self.write_manifest())
        matrix.execute_matrix(manifest, output, dependencies=FakeDependencies())
        records = self.read_evidence(output)
        group = records[1:4]

        context = matrix._finalization_proof_context(records[0], group)

        self.assertEqual(context["cellIDs"], [record["cellHash"] for record in group])
        self.assertEqual(context["sequences"], [record["sequence"] for record in group])

    def test_resume_rejects_rehashed_mutation_of_real_finalized_group(self):
        output = self.root / "mutated-finalized-group"
        manifest = matrix.load_manifest(self.write_manifest())
        matrix.execute_matrix(manifest, output, dependencies=FakeDependencies())
        records = self.read_evidence(output)
        records[1].update(
            result="FAIL",
            detail="product-route-failure",
            driverOutcome="launch-error",
            provenance="launch-error",
            receipt=False,
            browserIdentity=False,
        )
        self.write_rehashed_evidence(output, records)
        dependencies = FakeDependencies()
        with self.assertRaises(matrix.MatrixResumeError):
            matrix.execute_matrix(
                manifest, output, dependencies=dependencies, resume=True
            )
        self.assertEqual(dependencies.build_count, 0)
        self.assertEqual(dependencies.driver_calls, [])

    def test_resume_rejects_finalization_proof_reused_across_group_or_run(self):
        chrome = self.edge_application(
            bundleIdentifier="com.google.Chrome",
            applicationPath="/Applications/Google Chrome.app",
            executableRelativePath="Contents/MacOS/Google Chrome",
        )
        manifest = matrix.load_manifest(
            self.write_manifest([chrome, self.edge_application()])
        )
        first_output = self.root / "proof-source"
        second_output = self.root / "proof-other-run"
        matrix.execute_matrix(manifest, first_output, dependencies=FakeDependencies())
        matrix.execute_matrix(manifest, second_output, dependencies=FakeDependencies())

        for case, output, replacement in (
            (
                "group",
                first_output,
                self.read_evidence(first_output)[1]["taskFinalizationProof"],
            ),
            (
                "run",
                second_output,
                self.read_evidence(first_output)[1]["taskFinalizationProof"],
            ),
        ):
            records = self.read_evidence(output)
            target = 4 if case == "group" else 1
            for record in records[target : target + 3]:
                record["taskFinalizationProof"] = replacement
            self.write_rehashed_evidence(output, records)
            dependencies = FakeDependencies()
            with (
                self.subTest(case=case),
                self.assertRaises(matrix.MatrixResumeError),
            ):
                matrix.execute_matrix(
                    manifest, output, dependencies=dependencies, resume=True
                )
            self.assertEqual(dependencies.build_count, 0)
            self.assertEqual(dependencies.driver_calls, [])

    def test_resume_requires_original_safe_finalization_key(self):
        manifest = matrix.load_manifest(self.write_manifest())
        for case in (
            "missing",
            "replaced",
            "same-bytes-replaced",
            "mode",
            "hardlink",
            "generation",
        ):
            output = self.root / f"key-{case}"
            matrix.execute_matrix(manifest, output, dependencies=FakeDependencies())
            key_path = output / ".finalization-key"
            if case == "missing":
                key_path.unlink()
            elif case == "replaced":
                key_path.unlink()
                key_path.write_bytes(os.urandom(32))
                key_path.chmod(0o600)
            elif case == "same-bytes-replaced":
                key = key_path.read_bytes()
                key_path.unlink()
                key_path.write_bytes(key)
                key_path.chmod(0o600)
            elif case == "mode":
                key_path.chmod(0o644)
            elif case == "hardlink":
                os.link(key_path, self.root / "linked-finalization-key")
            dependencies = FakeDependencies()
            if case == "generation":
                real_read = matrix.os.read
                changed = False

                def replace_key_after_read(descriptor, count):
                    nonlocal changed
                    data = real_read(descriptor, count)
                    if not changed and count == matrix._FINALIZATION_KEY_BYTES + 1:
                        changed = True
                        key_path.write_bytes(os.urandom(matrix._FINALIZATION_KEY_BYTES))
                    return data

                read_context = mock.patch.object(
                    matrix.os, "read", side_effect=replace_key_after_read
                )
            else:
                read_context = contextlib.nullcontext()
            with (
                read_context,
                self.subTest(case=case),
                self.assertRaises(matrix.MatrixResumeError),
            ):
                matrix.execute_matrix(
                    manifest, output, dependencies=dependencies, resume=True
                )
            self.assertEqual(dependencies.build_count, 0)
            self.assertEqual(dependencies.driver_calls, [])

    def test_resume_revalidates_key_after_finalization_proof_verification(self):
        output = self.root / "key-post-proof-replacement"
        manifest = matrix.load_manifest(self.write_manifest())
        matrix.execute_matrix(manifest, output, dependencies=FakeDependencies())
        key_path = output / ".finalization-key"
        real_verify = matrix._verify_finalization_proofs

        def replace_after_verify(*args):
            real_verify(*args)
            key_path.write_bytes(os.urandom(matrix._FINALIZATION_KEY_BYTES))

        dependencies = FakeDependencies()
        with (
            mock.patch.object(
                matrix,
                "_verify_finalization_proofs",
                side_effect=replace_after_verify,
            ),
            self.assertRaises(matrix.MatrixResumeError),
        ):
            matrix.execute_matrix(
                manifest, output, dependencies=dependencies, resume=True
            )
        self.assertEqual(dependencies.build_count, 0)
        self.assertEqual(dependencies.driver_calls, [])

    def test_static_identity_digest_detects_same_size_executable_replacement(self):
        application_path = self.root / "Browser.app"
        executable = application_path / "Contents" / "MacOS" / "Browser"
        executable.parent.mkdir(parents=True)
        executable.write_bytes(b"first-static-payload")
        executable.chmod(0o700)
        with (application_path / "Contents" / "Info.plist").open("wb") as handle:
            plistlib.dump(
                {
                    "CFBundleIdentifier": "com.example.Browser",
                    "CFBundleExecutable": "Browser",
                    "CFBundleShortVersionString": "1.0",
                },
                handle,
            )
        application = matrix.MatrixApplication(
            "com.example.Browser",
            application_path,
            pathlib.PurePosixPath("Contents/MacOS/Browser"),
            "none",
            "workspace",
            False,
            False,
            False,
            False,
        )
        dependencies = matrix.SystemDependencies()
        with mock.patch.object(
            matrix.browser_driver,
            "_validate_signed_browser_binding",
            return_value=None,
        ):
            before = dependencies.verify_application(application)
            metadata = executable.stat()
            executable.write_bytes(b"other-static-value!!")
            os.utime(executable, ns=(metadata.st_atime_ns, metadata.st_mtime_ns))
            after = dependencies.verify_application(application)
        self.assertNotEqual(before.identity, after.identity)

    def test_static_identity_ignores_outer_directory_timestamp_only_change(self):
        application_path = self.root / "Browser.app"
        executable = application_path / "Contents" / "MacOS" / "Browser"
        executable.parent.mkdir(parents=True)
        executable.write_bytes(b"stable-static-payload")
        executable.chmod(0o700)
        with (application_path / "Contents" / "Info.plist").open("wb") as handle:
            plistlib.dump(
                {
                    "CFBundleIdentifier": "com.example.Browser",
                    "CFBundleExecutable": "Browser",
                    "CFBundleShortVersionString": "1.0",
                },
                handle,
            )
        application = matrix.MatrixApplication(
            "com.example.Browser",
            application_path,
            pathlib.PurePosixPath("Contents/MacOS/Browser"),
            "none",
            "workspace",
            False,
            False,
            False,
            False,
        )
        dependencies = matrix.SystemDependencies()
        with mock.patch.object(
            matrix.browser_driver,
            "_validate_signed_browser_binding",
            return_value=None,
        ):
            before = dependencies.verify_application(application)
            metadata = application_path.stat()
            os.utime(
                application_path,
                ns=(metadata.st_atime_ns, metadata.st_mtime_ns + 1_000_000),
            )
            after = dependencies.verify_application(application)
        self.assertEqual(before, after)

    def test_static_identity_rejects_named_file_replacement_during_digest(self):
        executable = self.root / "static-executable"
        replacement = self.root / "static-replacement"
        executable.write_bytes(b"a" * (1024 * 1024 + 1))
        replacement.write_bytes(b"b" * (1024 * 1024 + 1))
        real_read = os.read
        attacked = False

        def replace_after_read(descriptor, count):
            nonlocal attacked
            chunk = real_read(descriptor, count)
            if chunk and not attacked:
                attacked = True
                replacement.replace(executable)
            return chunk

        with (
            mock.patch.object(
                matrix.browser_driver.os, "read", side_effect=replace_after_read
            ),
            self.assertRaises(matrix.browser_driver._IdentityError),
        ):
            matrix.browser_driver._stable_static_identity(executable)

    def test_driver_supervision_uses_exact_generation_and_cooperative_term(self):
        executable = pathlib.Path("/usr/bin/python3")
        identity = matrix.browser_driver.ProcessIdentity(9001, 1, 2, 3, executable)

        class CooperativeProcess:
            pid = 9001
            returncode = matrix.browser_driver.DRIVER_PROCESS_ERROR

            def __init__(self):
                self.calls = 0

            def communicate(self, timeout):
                self.calls += 1
                if self.calls == 1:
                    raise matrix.subprocess.TimeoutExpired("driver", timeout)
                return b'{"outcome":"terminal"}\n', b""

        process = CooperativeProcess()
        signals = []
        completed = matrix._supervise_driver_process(
            ["/usr/bin/python3", "driver.py"],
            {},
            popen=lambda *args, **kwargs: process,
            identity_reader=lambda _pid: identity,
            signaler=lambda pid, signum: signals.append((pid, signum)),
            run_timeout=0.1,
            cleanup_timeout=0.1,
        )
        self.assertEqual(signals, [(9001, matrix.signal.SIGTERM)])
        self.assertEqual(completed.stdout, b'{"outcome":"terminal"}\n')
        self.assertEqual(
            completed.returncode, matrix.browser_driver.DRIVER_PROCESS_ERROR
        )

    def test_driver_supervision_never_signals_reused_or_hung_generation_blindly(self):
        executable = pathlib.Path("/usr/bin/python3")
        original = matrix.browser_driver.ProcessIdentity(9001, 1, 2, 3, executable)
        replacement = matrix.browser_driver.ProcessIdentity(9001, 1, 4, 5, executable)

        class HungProcess:
            pid = 9001
            returncode = None

            def communicate(self, timeout):
                raise matrix.subprocess.TimeoutExpired("driver", timeout)

        for identities, expected_signals in (
            ([original, replacement], []),
            ([original, original, original], [(9001, matrix.signal.SIGTERM)]),
        ):
            signals = []

            def identity_reader(_pid):
                return identities.pop(0)

            with (
                self.subTest(expected_signals=expected_signals),
                self.assertRaises(matrix.MatrixIdentityError),
            ):
                matrix._supervise_driver_process(
                    ["/usr/bin/python3", "driver.py"],
                    {},
                    popen=lambda *args, **kwargs: HungProcess(),
                    identity_reader=identity_reader,
                    signaler=lambda pid, signum: signals.append((pid, signum)),
                    run_timeout=0.1,
                    cleanup_timeout=0.1,
                )
            self.assertEqual(signals, expected_signals)

    def test_authenticated_handoff_recovers_only_exact_owned_generations_and_root(self):
        browser_executable = pathlib.Path("/Applications/Fake.app/Browser")
        context = {
            "bundleIdentifier": "com.example.Fake",
            "targetID": "com.example.Fake||normal",
            "capability": "normal",
            "browserAppIdentity": "a" * 64,
            "e2eAppIdentity": "b" * 64,
            "browserExecutable": os.fspath(browser_executable),
            "sessionHashes": ["c" * 64, "d" * 64, "e" * 64],
        }
        handoff = matrix._CleanupHandoff.create(context)
        publisher = matrix.browser_driver._CleanupHandoffPublisher(
            os.dup(handoff.descriptor), handoff.token, context
        )
        driver_identity = matrix.browser_driver._darwin_process_identity(os.getpid())
        owner = matrix.browser_driver._TaskRootOwner()
        root = matrix.browser_driver._make_task_root(owner)
        child = matrix.browser_driver.ProcessIdentity(
            7101, 7000, 11, 12, pathlib.Path("/usr/bin/python3")
        )
        browser = matrix.browser_driver.ProcessIdentity(
            7102, 7000, 13, 14, browser_executable
        )
        publisher.observe_root(root)
        publisher.baseline_empty()
        publisher.observe_child(child)
        publisher.observe_browser(browser)
        publisher.close()
        live = {child.generation_key: child, browser.generation_key: browser}
        terminated = []

        def identity_reader(pid):
            if pid == driver_identity.pid:
                return driver_identity
            for identity in live.values():
                if identity.pid == pid:
                    return identity
            raise matrix.browser_driver._ProcessDisappeared

        def terminate(identity, executable, _deadline):
            self.assertEqual(identity.executable, executable)
            terminated.append(identity.generation_key)
            live.pop(identity.generation_key)
            return True

        clock = [0.0]

        recovered = matrix._recover_cleanup_handoff(
            handoff,
            identity_reader=identity_reader,
            terminator=terminate,
            snapshotter=lambda _executable: frozenset(
                value for value in live.values() if value == browser
            ),
            direct_child_snapshotter=lambda _group: frozenset(
                {driver_identity} | {value for value in live.values() if value == child}
            ),
            static_checker=lambda _context: True,
            root_reopener=lambda record: root,
            root_remover=lambda pinned: pinned.remove(),
            monotonic=lambda: clock[0],
            sleep=lambda seconds: clock.__setitem__(0, clock[0] + seconds),
        )
        self.assertTrue(recovered)
        self.assertEqual(terminated, [child.generation_key, browser.generation_key])
        self.assertFalse(root.path.exists())
        handoff.close()

    def test_nonprofile_sequence_context_matches_driver_ledger_and_exact_recovery(self):
        cases = (
            ("chromium", "normal", "normal"),
            ("firefox", "normal", "normal"),
            ("chromium", "private", "private"),
        )
        for index, (profile_strategy, capability, mode) in enumerate(cases):
            with self.subTest(profile_strategy=profile_strategy, capability=capability):
                bundle_identifier = f"com.example.Browser{index}"
                application = matrix.MatrixApplication(
                    bundle_identifier,
                    pathlib.Path(f"/Applications/Browser{index}.app"),
                    pathlib.PurePosixPath("Contents/MacOS/Browser"),
                    profile_strategy,
                    "workspace" if capability == "normal" else "executable",
                    True,
                    True,
                    False,
                    False,
                )
                cell = matrix.MatrixCell(
                    0, bundle_identifier, capability, "cold", application
                )
                sessions = tuple(
                    f"session_{index}_{state}_0123456789" for state in range(3)
                )
                target_id = f"{bundle_identifier}||{mode}"
                runner_context = matrix._sequence_handoff_context(
                    cell,
                    target_id,
                    sessions,
                    None,
                    "e" * 64,
                    "b" * 64,
                )
                driver_context = matrix.browser_driver._handoff_context(
                    matrix.browser_driver.DriverConfig(
                        e2e_app=pathlib.Path("/Applications/PickVia E2E.app"),
                        browser_app=application.application_path,
                        expected_browser_executable=application.executable_path,
                        target_id=target_id,
                        bundle_identifier=bundle_identifier,
                        mode=mode,
                        expected_mechanism=cell.mechanism,
                        session_nonce=sessions[0],
                        capability=capability,
                        state="sequence",
                        e2e_app_identity="e" * 64,
                        browser_app_identity="b" * 64,
                        sequence_sessions=sessions,
                    )
                )
                self.assertEqual(runner_context, driver_context)
                self.assertEqual(runner_context["profileStrategy"], "none")
                self.assertEqual(runner_context["profileRelativeRoot"], "none")
                self.assertFalse(runner_context["createProfile"])

                handoff = matrix._CleanupHandoff.create(runner_context)
                publisher = matrix.browser_driver._CleanupHandoffPublisher(
                    os.dup(handoff.descriptor), handoff.token, driver_context
                )
                owner = matrix.browser_driver._TaskRootOwner()
                root = matrix.browser_driver._make_task_root(owner)
                browser = matrix.browser_driver.ProcessIdentity(
                    8100 + index,
                    os.getpid(),
                    20 + index,
                    30 + index,
                    application.executable_path,
                )
                publisher.observe_root(root)
                publisher.baseline_empty()
                publisher.observe_browser(browser)
                publisher.close()
                self.assertEqual(handoff.records()[-1][0]["context"], runner_context)
                driver_identity = matrix.browser_driver._darwin_process_identity(
                    os.getpid()
                )
                live = {browser.generation_key: browser}
                terminated = []
                clock = [0.0]

                def identity_reader(pid):
                    if pid == driver_identity.pid:
                        return driver_identity
                    if pid == browser.pid and browser.generation_key in live:
                        return browser
                    raise matrix.browser_driver._ProcessDisappeared

                def terminate(identity, executable, _deadline):
                    self.assertEqual(identity, browser)
                    self.assertEqual(executable, application.executable_path)
                    terminated.append(identity.generation_key)
                    live.pop(identity.generation_key)
                    return True

                self.assertTrue(
                    matrix._recover_cleanup_handoff(
                        handoff,
                        identity_reader=identity_reader,
                        terminator=terminate,
                        snapshotter=lambda _executable: frozenset(live.values()),
                        direct_child_snapshotter=lambda _group: frozenset(
                            {driver_identity}
                        ),
                        static_checker=lambda context: context == runner_context,
                        root_reopener=lambda _record: root,
                        root_remover=lambda pinned: pinned.remove(),
                        monotonic=lambda: clock[0],
                        sleep=lambda seconds: clock.__setitem__(0, clock[0] + seconds),
                    )
                )
                self.assertTrue(handoff.task_root_finalized)
                self.assertEqual(terminated, [browser.generation_key])
                self.assertFalse(root.path.exists())
                handoff.close()

    def test_handoff_context_mismatch_rejects_authenticated_cleanup(self):
        application = matrix.MatrixApplication(
            "com.example.Browser",
            pathlib.Path("/Applications/Browser.app"),
            pathlib.PurePosixPath("Contents/MacOS/Browser"),
            "chromium",
            "workspace",
            True,
            True,
            False,
            False,
        )
        cell = matrix.MatrixCell(
            0, application.bundle_identifier, "normal", "cold", application
        )
        sessions = tuple(f"session_{index}_0123456789" for index in range(3))
        context = matrix._sequence_handoff_context(
            cell,
            "com.example.Browser||normal",
            sessions,
            None,
            "e" * 64,
            "b" * 64,
        )
        mismatched = dict(context, profileStrategy="chromium")
        handoff = matrix._CleanupHandoff.create(context)
        publisher = matrix.browser_driver._CleanupHandoffPublisher(
            os.dup(handoff.descriptor), handoff.token, mismatched
        )
        owner = matrix.browser_driver._TaskRootOwner()
        root = matrix.browser_driver._make_task_root(owner)
        publisher.observe_root(root)
        publisher.baseline_empty()
        publisher.close()
        with self.assertRaises(matrix.MatrixIdentityError):
            handoff.records()
        self.assertTrue(root.path.exists())
        root.remove()
        handoff.mark_recovered()
        handoff.close()

    def test_profile_sequence_context_uses_exact_manifest_strategy(self):
        for index, strategy in enumerate(("chromium", "firefox")):
            with self.subTest(strategy=strategy):
                application = matrix.MatrixApplication(
                    f"com.example.ProfileBrowser{index}",
                    pathlib.Path(f"/Applications/ProfileBrowser{index}.app"),
                    pathlib.PurePosixPath("Contents/MacOS/Browser"),
                    strategy,
                    "executable",
                    True,
                    True,
                    False,
                    False,
                )
                cell = matrix.MatrixCell(
                    0,
                    application.bundle_identifier,
                    "profile",
                    "cold",
                    application,
                )
                sessions = tuple(
                    f"profile_session_{index}_{state}_0123456789" for state in range(3)
                )
                profile_root = f"profiles/profile-{index}"
                context = matrix._sequence_handoff_context(
                    cell,
                    f"{application.bundle_identifier}||normal",
                    sessions,
                    profile_root,
                    "e" * 64,
                    "b" * 64,
                )
                self.assertEqual(context["profileStrategy"], strategy)
                self.assertEqual(context["profileRelativeRoot"], profile_root)
                self.assertTrue(context["createProfile"])

    def test_handoff_rejects_forgery_and_pid_reuse_without_signals_or_root_removal(
        self,
    ):
        context = {
            "bundleIdentifier": "com.example.Fake",
            "targetID": "com.example.Fake||normal",
            "capability": "normal",
            "browserAppIdentity": "a" * 64,
            "e2eAppIdentity": "b" * 64,
            "browserExecutable": "/Applications/Fake.app/Browser",
            "sessionHashes": ["c" * 64, "d" * 64, "e" * 64],
        }
        for attack in ("forgery", "reuse"):
            with self.subTest(attack=attack):
                handoff = matrix._CleanupHandoff.create(context)
                publisher = matrix.browser_driver._CleanupHandoffPublisher(
                    os.dup(handoff.descriptor), handoff.token, context
                )
                owner = matrix.browser_driver._TaskRootOwner()
                root = matrix.browser_driver._make_task_root(owner)
                child = matrix.browser_driver.ProcessIdentity(
                    7201, 7000, 21, 22, pathlib.Path("/usr/bin/python3")
                )
                publisher.observe_root(root)
                publisher.baseline_empty()
                publisher.observe_child(child)
                publisher.close()
                if attack == "forgery":
                    os.lseek(handoff.descriptor, 0, os.SEEK_END)
                    os.write(
                        handoff.descriptor,
                        b'{"payload":{},"authentication":"forged"}\n',
                    )
                signals = []
                if attack == "forgery":
                    with self.assertRaises(matrix.MatrixIdentityError):
                        matrix._recover_cleanup_handoff(
                            handoff,
                            terminator=lambda *args: signals.append(args),
                            root_reopener=lambda _record: root,
                        )
                else:
                    replacement = matrix.dataclasses.replace(child, start_seconds=99)
                    self.assertFalse(
                        matrix._recover_cleanup_handoff(
                            handoff,
                            identity_reader=lambda _pid: replacement,
                            terminator=lambda *args: signals.append(args),
                            root_reopener=lambda _record: root,
                        )
                    )
                self.assertEqual(signals, [])
                self.assertTrue(root.path.exists())
                root.remove()
                handoff.mark_recovered()
                handoff.close()

    def test_handoff_rejects_missing_or_authenticated_out_of_order_transition(self):
        context = {
            "bundleIdentifier": "com.example.Fake",
            "targetID": "com.example.Fake||normal",
            "capability": "normal",
            "browserAppIdentity": "a" * 64,
            "e2eAppIdentity": "b" * 64,
            "browserExecutable": "/Applications/Fake.app/Browser",
            "sessionHashes": ["c" * 64, "d" * 64, "e" * 64],
        }
        handoff = matrix._CleanupHandoff.create(context)
        try:
            self.assertFalse(matrix._recover_cleanup_handoff(handoff))
            payload = {
                "schemaVersion": 1,
                "counter": 1,
                "transition": "child-owned",
                "context": context,
                "taskRoot": None,
                "ownedChildren": [],
                "ownedBrowsers": [],
                "taskRootFinalized": False,
            }
            canonical = json.dumps(
                payload, sort_keys=True, separators=(",", ":"), ensure_ascii=True
            ).encode("ascii")
            record = {
                "payload": payload,
                "authentication": matrix.hmac.new(
                    bytes.fromhex(handoff.token), canonical, hashlib.sha256
                ).hexdigest(),
            }
            os.write(
                handoff.descriptor,
                (
                    json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n"
                ).encode("ascii"),
            )
            with self.assertRaises(matrix.MatrixIdentityError):
                matrix._recover_cleanup_handoff(handoff)
        finally:
            handoff.mark_recovered()
            handoff.close()

    def test_hung_driver_uses_authenticated_recovery_before_exact_kill(self):
        executable = pathlib.Path("/usr/bin/python3")
        identity = matrix.browser_driver.ProcessIdentity(9002, 1, 8, 9, executable)

        class RecoveredHungProcess:
            pid = 9002
            returncode = None

            def __init__(self):
                self.calls = 0

            def communicate(self, timeout):
                self.calls += 1
                if self.calls < 3:
                    raise matrix.subprocess.TimeoutExpired("driver", timeout)
                self.returncode = -matrix.signal.SIGKILL
                return b"", b""

        process = RecoveredHungProcess()
        signals = []
        completed = matrix._supervise_driver_process(
            ["/usr/bin/python3", "driver.py"],
            {},
            popen=lambda *args, **kwargs: process,
            identity_reader=lambda _pid: identity,
            signaler=lambda pid, signum: signals.append((pid, signum)),
            handoff=object(),
            recoverer=lambda _handoff: True,
            run_timeout=0.1,
            cleanup_timeout=0.1,
        )
        self.assertEqual(
            signals,
            [
                (9002, matrix.signal.SIGTERM),
                (9002, matrix.signal.SIGKILL),
            ],
        )
        self.assertEqual(completed.returncode, -matrix.signal.SIGKILL)

    def test_driver_handoff_secret_uses_inherited_pipe_not_argv_or_environment(self):
        executable = pathlib.Path("/usr/bin/python3")
        identity = matrix.browser_driver.ProcessIdentity(9003, 1, 10, 11, executable)
        handoff = matrix._CleanupHandoff.create(
            {"browserExecutable": "/Applications/Fake.app/Browser"}
        )
        captured = {}

        class HungThenRecovered:
            pid = 9003
            returncode = None

            def __init__(self):
                self.calls = 0

            def communicate(self, timeout):
                self.calls += 1
                if self.calls < 3:
                    raise matrix.subprocess.TimeoutExpired("driver", timeout)
                self.returncode = -matrix.signal.SIGKILL
                return b"", b""

        process = HungThenRecovered()

        def popen(arguments, **options):
            captured["arguments"] = tuple(arguments)
            captured["environment"] = dict(options["env"])
            captured["secret"] = os.dup(options["pass_fds"][1])
            return process

        matrix._supervise_driver_process(
            ["/usr/bin/python3", "driver.py", "--cleanup-handoff-secret-fd", "9"],
            {"PATH": "/usr/bin"},
            popen=popen,
            identity_reader=lambda _pid: identity,
            signaler=lambda _pid, _signal: None,
            handoff=handoff,
            recoverer=lambda _handoff: True,
            run_timeout=0.1,
            cleanup_timeout=0.1,
        )
        try:
            self.assertNotIn(handoff.token, " ".join(captured["arguments"]))
            self.assertNotIn(handoff.token, captured["environment"].values())
            self.assertEqual(
                os.read(captured["secret"], 65),
                (handoff.token + "\n").encode("ascii"),
            )
        finally:
            os.close(captured["secret"])
            handoff.mark_recovered()
            handoff.close()

    def test_handoff_child_cleanup_revalidates_before_each_exact_signal(self):
        executable = pathlib.Path("/usr/bin/python3")
        identity = matrix.browser_driver.ProcessIdentity(9301, 1, 30, 31, executable)
        replacement = matrix.dataclasses.replace(identity, start_seconds=32)
        signals = []
        with self.assertRaises(matrix.MatrixIdentityError):
            matrix._terminate_exact_handoff_child(
                identity,
                executable,
                5.0,
                identity_reader=lambda _pid: replacement,
                signaler=lambda pid, signum: signals.append((pid, signum)),
                monotonic=lambda: 0.0,
                sleep=lambda _seconds: None,
            )
        self.assertEqual(signals, [])

        live = [True]
        clock = [0.0]

        def identity_reader(_pid):
            if not live[0]:
                raise matrix.browser_driver._ProcessDisappeared
            return identity

        def signaler(pid, signum):
            signals.append((pid, signum))
            if signum == matrix.signal.SIGKILL:
                live[0] = False

        self.assertTrue(
            matrix._terminate_exact_handoff_child(
                identity,
                executable,
                5.0,
                identity_reader=identity_reader,
                signaler=signaler,
                monotonic=lambda: clock[0],
                sleep=lambda seconds: clock.__setitem__(0, clock[0] + seconds),
            )
        )
        self.assertEqual(
            signals,
            [
                (9301, matrix.signal.SIGTERM),
                (9301, matrix.signal.SIGCONT),
                (9301, matrix.signal.SIGKILL),
            ],
        )

    def test_recovery_rejects_unledgered_browser_without_signal_or_root_removal(self):
        executable = pathlib.Path("/Applications/Fake.app/Browser")
        context = {
            "bundleIdentifier": "com.example.Fake",
            "targetID": "com.example.Fake||normal",
            "capability": "normal",
            "browserAppIdentity": "a" * 64,
            "e2eAppIdentity": "b" * 64,
            "browserExecutable": os.fspath(executable),
            "browserApplication": "/Applications/Fake.app",
            "sessionHashes": ["c" * 64, "d" * 64, "e" * 64],
        }
        handoff = matrix._CleanupHandoff.create(context)
        publisher = matrix.browser_driver._CleanupHandoffPublisher(
            os.dup(handoff.descriptor), handoff.token, context
        )
        owner = matrix.browser_driver._TaskRootOwner()
        root = matrix.browser_driver._make_task_root(owner)
        publisher.observe_root(root)
        publisher.baseline_empty()
        publisher.close()
        driver_identity = matrix.browser_driver._darwin_process_identity(os.getpid())
        unknown = matrix.browser_driver.ProcessIdentity(9401, 1, 41, 42, executable)
        signals = []
        self.assertFalse(
            matrix._recover_cleanup_handoff(
                handoff,
                identity_reader=lambda _pid: driver_identity,
                terminator=lambda *args: signals.append(args),
                snapshotter=lambda _executable: frozenset({unknown}),
                direct_child_snapshotter=lambda _group: frozenset({driver_identity}),
                static_checker=lambda _context: True,
            )
        )
        self.assertEqual(signals, [])
        self.assertTrue(root.path.exists())
        root.remove()
        handoff.mark_recovered()
        handoff.close()

    def test_finalized_handoff_still_proves_root_quiescence_and_static_identity(self):
        context = {
            "bundleIdentifier": "com.example.Fake",
            "targetID": "com.example.Fake||normal",
            "capability": "normal",
            "browserAppIdentity": "a" * 64,
            "e2eAppIdentity": "b" * 64,
            "browserExecutable": "/Applications/Fake.app/Browser",
            "browserApplication": "/Applications/Fake.app",
            "sessionHashes": ["c" * 64, "d" * 64, "e" * 64],
        }
        for root_present, static_ok, expected in (
            (True, True, False),
            (False, False, False),
            (False, True, True),
        ):
            with self.subTest(root_present=root_present, static_ok=static_ok):
                handoff = matrix._CleanupHandoff.create(context)
                publisher = matrix.browser_driver._CleanupHandoffPublisher(
                    os.dup(handoff.descriptor), handoff.token, context
                )
                owner = matrix.browser_driver._TaskRootOwner()
                root = matrix.browser_driver._make_task_root(owner)
                root_path = root.path
                publisher.observe_root(root)
                publisher.baseline_empty()
                publisher.cleanup_progress()
                if not root_present:
                    root.remove()
                publisher.finalized()
                publisher.close()
                driver_identity = matrix.browser_driver._darwin_process_identity(
                    os.getpid()
                )
                clock = [0.0]
                snapshots = [0]
                static_calls = [0]

                def snapshot(_executable):
                    snapshots[0] += 1
                    return frozenset()

                def check_static(_context):
                    static_calls[0] += 1
                    return static_ok

                recovered = matrix._recover_cleanup_handoff(
                    handoff,
                    identity_reader=lambda _pid: driver_identity,
                    snapshotter=snapshot,
                    direct_child_snapshotter=lambda _group: frozenset(
                        {driver_identity}
                    ),
                    static_checker=check_static,
                    monotonic=lambda: clock[0],
                    sleep=lambda seconds: clock.__setitem__(0, clock[0] + seconds),
                )
                self.assertEqual(recovered, expected)
                if expected:
                    self.assertGreaterEqual(snapshots[0], 2)
                    self.assertEqual(clock[0], 2.0)
                    self.assertEqual(static_calls[0], 2)
                if root_path.exists():
                    root.remove()
                handoff.mark_recovered()
                handoff.close()

    def test_recovery_rejects_leftover_driver_process_group_member(self):
        context = {
            "bundleIdentifier": "com.example.Fake",
            "targetID": "com.example.Fake||normal",
            "capability": "normal",
            "browserAppIdentity": "a" * 64,
            "e2eAppIdentity": "b" * 64,
            "browserExecutable": "/Applications/Fake.app/Browser",
            "browserApplication": "/Applications/Fake.app",
            "sessionHashes": ["c" * 64, "d" * 64, "e" * 64],
        }
        handoff = matrix._CleanupHandoff.create(context)
        publisher = matrix.browser_driver._CleanupHandoffPublisher(
            os.dup(handoff.descriptor), handoff.token, context
        )
        owner = matrix.browser_driver._TaskRootOwner()
        root = matrix.browser_driver._make_task_root(owner)
        publisher.observe_root(root)
        publisher.baseline_empty()
        publisher.close()
        driver_identity = matrix.browser_driver._darwin_process_identity(os.getpid())
        leftover = matrix.browser_driver.ProcessIdentity(
            9501, driver_identity.pid, 51, 52, pathlib.Path("/usr/bin/python3")
        )
        group_calls = [0]

        def process_group(_group):
            group_calls[0] += 1
            return frozenset({driver_identity, leftover})

        clock = [0.0]

        self.assertFalse(
            matrix._recover_cleanup_handoff(
                handoff,
                identity_reader=lambda pid: (
                    driver_identity if pid == driver_identity.pid else leftover
                ),
                terminator=lambda *_args: True,
                snapshotter=lambda _executable: frozenset(),
                direct_child_snapshotter=process_group,
                static_checker=lambda _context: True,
                monotonic=lambda: clock[0],
                sleep=lambda seconds: clock.__setitem__(0, clock[0] + seconds),
            )
        )
        self.assertGreaterEqual(group_calls[0], 2)
        self.assertTrue(root.path.exists())
        root.remove()
        handoff.mark_recovered()
        handoff.close()

    def test_unrecoverable_handoff_retains_private_artifact_success_does_not(self):
        context = {"browserExecutable": "/Applications/Fake.app/Browser"}
        handoff = matrix._CleanupHandoff.create(context)
        handoff.close()
        retained = handoff.retained_path
        self.assertEqual(matrix.stat.S_IMODE(retained.stat().st_mode), 0o700)
        self.assertEqual(
            {path.name for path in retained.iterdir()},
            {"authentication-key", "cleanup-ledger.jsonl", "context.json"},
        )
        for path in retained.iterdir():
            self.assertEqual(matrix.stat.S_IMODE(path.stat().st_mode), 0o600)
            path.unlink()
        retained.rmdir()

        successful = matrix._CleanupHandoff.create(context)
        successful.mark_recovered()
        successful.close()
        self.assertFalse(hasattr(successful, "retained_path"))

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

    def test_output_lock_excludes_second_fresh_or_resume_writer_for_lifetime(self):
        output_path = self.root / "locked-output"
        first = matrix._PinnedOutputDirectory.open(output_path, create=True)
        header = matrix._chain_record(
            {
                "recordType": "run",
                "schemaVersion": 1,
                "manifestDigest": "a" * 64,
                "planDigest": "b" * 64,
            },
            "0" * 64,
        )
        matrix._write_records(first, [header])
        original = (output_path / "evidence.jsonl").read_bytes()
        try:
            with self.assertRaises(matrix.MatrixError):
                matrix._PinnedOutputDirectory.open(output_path, create=False)
            with self.assertRaises(matrix.MatrixError):
                matrix._PinnedOutputDirectory.open(output_path, create=True)
            self.assertEqual((output_path / "evidence.jsonl").read_bytes(), original)
            probe = (
                "import pathlib,sys;"
                f"sys.path.insert(0,{str(pathlib.Path(matrix.__file__).parent)!r});"
                "import run_browser_matrix as matrix;"
                "path=pathlib.Path(sys.argv[1]);"
                "\ntry: matrix._PinnedOutputDirectory.open(path,create=False)\n"
                "except matrix.MatrixError: raise SystemExit(0)\n"
                "raise SystemExit(1)"
            )
            completed = matrix.subprocess.run(
                [matrix.sys.executable, "-c", probe, os.fspath(output_path)],
                stdin=matrix.subprocess.DEVNULL,
                stdout=matrix.subprocess.PIPE,
                stderr=matrix.subprocess.PIPE,
                timeout=5,
                check=False,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertEqual((output_path / "evidence.jsonl").read_bytes(), original)
        finally:
            first.close()
        second = matrix._PinnedOutputDirectory.open(output_path, create=False)
        second.close()

    def test_evidence_update_rejects_destination_change_between_check_and_swap(self):
        output_path = self.root / "changed-destination"
        output = matrix._PinnedOutputDirectory.open(output_path, create=True)
        header = matrix._chain_record(
            {
                "recordType": "run",
                "schemaVersion": 1,
                "manifestDigest": "a" * 64,
                "planDigest": "b" * 64,
            },
            "0" * 64,
        )
        matrix._write_records(output, [header])
        cell = matrix._chain_record(
            {
                "recordType": "diagnostic",
                "schemaVersion": 1,
            },
            header["recordHash"],
        )
        real_swap = matrix._rename_at_swap
        attacked = False

        def replace_then_swap(descriptor, source, destination):
            nonlocal attacked
            if not attacked:
                attacked = True
                os.unlink(destination, dir_fd=descriptor)
                forged = os.open(
                    destination,
                    os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                    0o600,
                    dir_fd=descriptor,
                )
                try:
                    os.write(forged, b"concurrent-replacement\n")
                finally:
                    os.close(forged)
            return real_swap(descriptor, source, destination)

        try:
            with (
                mock.patch.object(
                    matrix, "_rename_at_swap", side_effect=replace_then_swap
                ),
                self.assertRaises(matrix.MatrixError),
            ):
                matrix._write_records(output, [header, cell])
            self.assertEqual(
                (output_path / "evidence.jsonl").read_bytes(),
                b"concurrent-replacement\n",
            )
        finally:
            output.close()

    def test_evidence_update_rolls_back_operation_time_staging_replacement(self):
        output_path = self.root / "publication-output"
        output = matrix._PinnedOutputDirectory.open(output_path, create=True)
        header = matrix._chain_record(
            {
                "recordType": "run",
                "schemaVersion": 1,
                "manifestDigest": "a" * 64,
                "planDigest": "b" * 64,
            },
            "0" * 64,
        )
        matrix._write_records(output, [header])
        original = (output_path / "evidence.jsonl").read_bytes()
        diagnostic = matrix._chain_record(
            {"recordType": "diagnostic", "schemaVersion": 1},
            header["recordHash"],
        )
        real_swap = matrix._rename_at_swap
        attacked = False

        def replace_staging_then_swap(descriptor, source, destination):
            nonlocal attacked
            if not attacked:
                attacked = True
                os.unlink(source, dir_fd=descriptor)
                forged = os.open(
                    source,
                    os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                    0o600,
                    dir_fd=descriptor,
                )
                try:
                    os.write(forged, b"forged-after-check\n")
                finally:
                    os.close(forged)
            return real_swap(descriptor, source, destination)

        try:
            with (
                mock.patch.object(
                    matrix,
                    "_rename_at_swap",
                    side_effect=replace_staging_then_swap,
                ),
                self.assertRaises(matrix.MatrixError),
            ):
                matrix._write_records(output, [header, diagnostic])
            self.assertEqual((output_path / "evidence.jsonl").read_bytes(), original)
        finally:
            output.close()

    def test_failed_evidence_rollback_retains_exact_prior_for_recovery(self):
        output_path = self.root / "failed-rollback-output"
        output = matrix._PinnedOutputDirectory.open(output_path, create=True)
        header = matrix._chain_record(
            {
                "recordType": "run",
                "schemaVersion": 1,
                "manifestDigest": "a" * 64,
                "planDigest": "b" * 64,
            },
            "0" * 64,
        )
        matrix._write_records(output, [header])
        original = (output_path / "evidence.jsonl").read_bytes()
        diagnostic = matrix._chain_record(
            {"recordType": "diagnostic", "schemaVersion": 1},
            header["recordHash"],
        )
        real_swap = matrix._rename_at_swap
        swap_count = 0

        def replace_staging_and_fail_rollback(descriptor, source, destination):
            nonlocal swap_count
            swap_count += 1
            if swap_count == 1:
                os.unlink(source, dir_fd=descriptor)
                forged = os.open(
                    source,
                    os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                    0o600,
                    dir_fd=descriptor,
                )
                try:
                    os.write(forged, b"forged-after-check\n")
                finally:
                    os.close(forged)
                return real_swap(descriptor, source, destination)
            raise OSError("synthetic rollback failure")

        try:
            with (
                mock.patch.object(
                    matrix,
                    "_rename_at_swap",
                    side_effect=replace_staging_and_fail_rollback,
                ),
                self.assertRaisesRegex(matrix.MatrixError, "prior retained"),
            ):
                matrix._write_records(output, [header, diagnostic])
            recovery_names = set(os.listdir(output.descriptor)) - {
                ".run.lock",
                ".finalization-key",
                "evidence.jsonl",
            }
            self.assertEqual(len(recovery_names), 1)
            recovery_name = recovery_names.pop()
            recovery_descriptor = os.open(
                recovery_name,
                os.O_RDONLY | os.O_NOFOLLOW,
                dir_fd=output.descriptor,
            )
            try:
                self.assertEqual(
                    os.read(recovery_descriptor, len(original) + 1), original
                )
            finally:
                os.close(recovery_descriptor)
            self.assertEqual(
                (output_path / "evidence.jsonl").read_bytes(),
                b"forged-after-check\n",
            )
        finally:
            output.close()

    def test_replacing_lock_sentinel_does_not_bypass_directory_lock(self):
        output_path = self.root / "replaced-lock"
        first = matrix._PinnedOutputDirectory.open(output_path, create=True)
        header = matrix._chain_record(
            {
                "recordType": "run",
                "schemaVersion": 1,
                "manifestDigest": "a" * 64,
                "planDigest": "b" * 64,
            },
            "0" * 64,
        )
        matrix._write_records(first, [header])
        original = (output_path / "evidence.jsonl").read_bytes()
        os.unlink(".run.lock", dir_fd=first.descriptor)
        replacement = os.open(
            ".run.lock",
            os.O_WRONLY | os.O_CREAT | os.O_EXCL,
            0o600,
            dir_fd=first.descriptor,
        )
        os.close(replacement)
        try:
            with self.assertRaises(matrix.MatrixError):
                first.require_current()
            with self.assertRaises(matrix.MatrixError):
                matrix._PinnedOutputDirectory.open(output_path, create=False)
            self.assertEqual((output_path / "evidence.jsonl").read_bytes(), original)
        finally:
            first.close()

    def test_removing_lock_sentinel_is_typed_and_preserves_evidence(self):
        output_path = self.root / "removed-lock"
        output = matrix._PinnedOutputDirectory.open(output_path, create=True)
        header = matrix._chain_record(
            {
                "recordType": "run",
                "schemaVersion": 1,
                "manifestDigest": "a" * 64,
                "planDigest": "b" * 64,
            },
            "0" * 64,
        )
        matrix._write_records(output, [header])
        original = (output_path / "evidence.jsonl").read_bytes()
        os.unlink(".run.lock", dir_fd=output.descriptor)
        try:
            with self.assertRaisesRegex(
                matrix.MatrixError, "output directory identity changed"
            ):
                output.require_current()
            self.assertEqual((output_path / "evidence.jsonl").read_bytes(), original)
        finally:
            output.close()

    def test_output_rejects_symlinked_parent_without_outside_write(self):
        outside = self.root / "outside"
        outside.mkdir(mode=0o700)
        linked_parent = self.root / "linked-parent"
        linked_parent.symlink_to(outside, target_is_directory=True)
        output = linked_parent / "output"
        with self.assertRaises(matrix.MatrixError):
            matrix.execute_matrix(
                matrix.load_manifest(self.write_manifest()),
                output,
                dependencies=FakeDependencies(),
            )
        self.assertEqual(list(outside.iterdir()), [])

    def test_output_rejects_parent_replacement_before_creation_without_write(self):
        parent = self.root / "preopen-parent"
        parent.mkdir(mode=0o700)
        displaced = self.root / "preopen-parent-displaced"
        output = parent / "output"
        real_open = os.open
        attacked = False

        def replace_before_open(path, *args, **kwargs):
            nonlocal attacked
            if pathlib.Path(path) == parent and not attacked:
                attacked = True
                parent.rename(displaced)
                parent.mkdir(mode=0o700)
            return real_open(path, *args, **kwargs)

        with (
            mock.patch.object(matrix.os, "open", side_effect=replace_before_open),
            self.assertRaises(matrix.MatrixError),
        ):
            matrix.execute_matrix(
                matrix.load_manifest(self.write_manifest()),
                output,
                dependencies=FakeDependencies(),
            )
        self.assertEqual(list(parent.iterdir()), [])
        self.assertEqual(list(displaced.iterdir()), [])

    def test_pinned_output_rejects_parent_or_output_replacement_without_outside_write(
        self,
    ):
        for attack in ("parent", "output"):
            base = self.root / attack
            base.mkdir(mode=0o700)
            output_path = base / "output"
            pinned = matrix._PinnedOutputDirectory.open(output_path, create=True)
            held = base.with_name(f"{base.name}-held")
            try:
                if attack == "parent":
                    base.rename(held)
                    base.mkdir(mode=0o700)
                    replacement = base / "output"
                    replacement.mkdir(mode=0o700)
                else:
                    output_path.rename(held)
                    replacement = output_path
                    replacement.mkdir(mode=0o700)
                sentinel = replacement / "outside-must-survive"
                sentinel.write_text("preserved", encoding="utf-8")
                with (
                    self.subTest(attack=attack),
                    self.assertRaises(matrix.MatrixError),
                ):
                    matrix._write_records(
                        pinned,
                        [
                            {
                                "recordType": "run",
                                "schemaVersion": 1,
                                "manifestDigest": "m" * 64,
                                "planDigest": "p" * 64,
                                "previousHash": "0" * 64,
                                "recordHash": "r" * 64,
                            }
                        ],
                    )
                self.assertEqual(sentinel.read_text(encoding="utf-8"), "preserved")
                self.assertFalse((replacement / "evidence.jsonl").exists())
            finally:
                pinned.close()

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
            "sessionHashes": [
                hashlib.sha256(expectation.session.encode("ascii")).hexdigest()
            ],
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
                    "session": expectation.session,
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
            lambda report: report.update(sessionHashes=["0" * 64]),
            lambda report: report["stateProofs"][0].update(
                session="forged_session_012345"
            ),
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
                candidate = json.loads(json.dumps(valid))
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
        sessions = (
            "session_cold_0123456789",
            "session_running_01234567",
            "session_reopen_012345678",
        )
        requests = (
            "request_cold_0123456789",
            "request_running_01234567",
            "request_reopen_012345678",
        )
        dependencies = FakeDependencies()
        valid = dependencies.sequence_report(
            cells, sessions, requests, "e" * 64, "b" * 64
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
            for cell, session, request in zip(cells, sessions, requests)
        )
        self.assertEqual(
            matrix.validate_driver_sequence_report(valid, 0, expectations),
            (("PASS", "proven-route"),) * 3,
        )
        mutations = (
            lambda report: report["stateProofs"][1].update(
                request="forged_request_0000"
            ),
            lambda report: report["stateProofs"][1].update(
                session="forged_session_0000"
            ),
            lambda report: report.update(sessionHashes=["0" * 64] * 3),
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

        receipt_failure = json.loads(json.dumps(valid))
        receipt_failure["stateProofs"] = receipt_failure["stateProofs"][:2]
        receipt_failure["stateProofs"][-1].update(
            outcome="receipt-timeout",
            receipt=False,
        )
        receipt_failure.update(
            outcome="receipt-timeout",
            token_received=False,
            exact_browser_process_identity=True,
            launch_provenance="launch-observed",
        )
        self.assertEqual(
            matrix.validate_driver_sequence_report(
                receipt_failure,
                matrix.browser_driver.DRIVER_RECEIPT_TIMEOUT,
                expectations,
            ),
            (
                ("PASS", "proven-route"),
                ("FAIL", "product-receipt-failure"),
                ("NOT RUN", "blocked-after-sequence-failure"),
            ),
        )
        for mutate, return_code in (
            (lambda report: report.update(token_received=True), 12),
            (lambda report: report.update(exact_browser_process_identity=False), 12),
            (lambda report: report.update(launch_provenance="none"), 12),
            (lambda report: None, 10),
        ):
            candidate = json.loads(json.dumps(receipt_failure))
            mutate(candidate)
            with (
                self.subTest(receipt_failure_mutation=mutate),
                self.assertRaises(matrix.DriverProofError),
            ):
                matrix.validate_driver_sequence_report(
                    candidate, return_code, expectations
                )

        for refusal_outcome in (
            "target-disabled",
            "target-missing",
            "target-mode-mismatch",
        ):
            refusal = json.loads(json.dumps(valid))
            refusal["stateProofs"] = refusal["stateProofs"][:1]
            refusal["stateProofs"][0].update(
                outcome=refusal_outcome,
                receipt=False,
                browserIdentity=False,
                provenance="none",
                processIdentifier=None,
                processStartSeconds=None,
                processStartMicroseconds=None,
            )
            refusal.update(
                outcome=refusal_outcome,
                token_received=False,
                exact_browser_process_identity=False,
                launch_provenance="none",
            )
            with self.subTest(refusal_outcome=refusal_outcome):
                self.assertEqual(
                    matrix.validate_driver_sequence_report(
                        refusal,
                        matrix.browser_driver.DRIVER_SELECTION_REJECTED,
                        expectations,
                    ),
                    (
                        ("UNSUPPORTED", "catalog-capability-refused"),
                        ("NOT RUN", "blocked-after-sequence-refusal"),
                        ("NOT RUN", "blocked-after-sequence-refusal"),
                    ),
                )

        incoherent_refusal = json.loads(json.dumps(refusal))
        incoherent_refusal["stateProofs"][0]["browserIdentity"] = True
        with self.assertRaises(matrix.DriverProofError):
            matrix.validate_driver_sequence_report(
                incoherent_refusal,
                matrix.browser_driver.DRIVER_SELECTION_REJECTED,
                expectations,
            )

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

    def test_edge_pilot_receipt_failure_is_product_fail_and_stops(self):
        dependencies = FakeDependencies(
            receipt_fail_on=("com.microsoft.edgemac", "running")
        )
        result = matrix.execute_matrix(
            matrix.load_manifest(self.write_manifest()),
            self.root / "output",
            dependencies=dependencies,
        )
        self.assertEqual(result.exit_code, matrix.MATRIX_PRODUCT_FAILURE)
        self.assertEqual(
            [(record["result"], record["detail"]) for record in result.records[:3]],
            [
                ("PASS", "proven-route"),
                ("FAIL", "product-receipt-failure"),
                ("NOT RUN", "blocked-after-sequence-failure"),
            ],
        )

    def test_catalog_refusal_is_unsupported_and_nonpilot_matrix_continues(self):
        chrome = self.edge_application(
            bundleIdentifier="com.google.Chrome",
            applicationPath="/Applications/Google Chrome.app",
            executableRelativePath="Contents/MacOS/Google Chrome",
        )
        dependencies = FakeDependencies(
            unsupported_on=("com.google.Chrome", "normal", "cold")
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
        self.assertEqual(chrome_records[0]["result"], "UNSUPPORTED")
        self.assertEqual(chrome_records[0]["detail"], "catalog-capability-refused")
        self.assertEqual(chrome_records[0]["driverOutcome"], "target-missing")
        self.assertRegex(
            chrome_records[0]["taskFinalizationProof"], r"\A[0-9a-f]{64}\Z"
        )
        self.assertEqual(
            [record["result"] for record in chrome_records[1:3]],
            ["NOT RUN", "NOT RUN"],
        )
        self.assertTrue(
            all("taskFinalizationProof" not in record for record in chrome_records[1:3])
        )
        self.assertTrue(
            any(record["result"] == "PASS" for record in chrome_records[3:])
        )
        self.assertEqual(result.exit_code, matrix.MATRIX_BLOCKED)

    def test_edge_pilot_catalog_refusal_blocks_without_product_failure(self):
        dependencies = FakeDependencies(
            unsupported_on=("com.microsoft.edgemac", "normal", "cold")
        )
        result = matrix.execute_matrix(
            matrix.load_manifest(self.write_manifest()),
            self.root / "output",
            dependencies=dependencies,
        )
        self.assertEqual(result.records[0]["result"], "UNSUPPORTED")
        self.assertEqual(result.exit_code, matrix.MATRIX_BLOCKED)

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

    def test_harness_ambiguity_preserves_independent_task_finalization(self):
        class FinalizedAmbiguousDependencies(FakeDependencies):
            def run_sequence(self, *args, **kwargs):
                report, return_code = super().run_sequence(*args, **kwargs)
                return report, return_code, True

        dependencies = FinalizedAmbiguousDependencies(
            ambiguous_on=("com.microsoft.edgemac", "cold")
        )
        result = matrix.execute_matrix(
            matrix.load_manifest(self.write_manifest()),
            self.root / "output",
            dependencies=dependencies,
        )
        pilot = result.records[:3]
        tail = result.records[3:]
        self.assertTrue(
            all(record["detail"] == "harness-ambiguity" for record in pilot)
        )
        self.assertTrue(all(record["cleanupSuccess"] is False for record in pilot))
        self.assertTrue(all(record["taskRootFinalized"] is True for record in pilot))
        self.assertTrue(all(record["taskRootFinalized"] is False for record in tail))

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
        self.assertTrue(
            all(record["sessionHash"] == "not-invoked" for record in result.records)
        )

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
        key_path = output / ".finalization-key"
        key = key_path.read_bytes()
        self.assertEqual(len(key), matrix._FINALIZATION_KEY_BYTES)
        self.assertEqual(key_path.stat().st_uid, os.getuid())
        self.assertEqual(matrix.stat.S_IMODE(key_path.stat().st_mode), 0o600)
        self.assertNotIn(key.hex(), evidence)
        self.assertNotIn(key.hex(), json.dumps(first.records))
        for forbidden in (
            "/Applications/",
            "/private/tmp/",
            "token",
            "fifo",
            "pid",
        ):
            self.assertNotIn(forbidden, evidence.lower())
        records = [json.loads(line) for line in evidence.splitlines()]
        self.assertEqual(records[0]["recordType"], "run")
        self.assertRegex(records[0]["finalizationKeyProof"], r"\A[0-9a-f]{64}\Z")
        self.assertTrue(all("recordHash" in record for record in records))
        session_hashes = [record["sessionHash"] for record in records[1:]]
        self.assertTrue(all(len(value) == 64 for value in session_hashes))
        self.assertEqual(len(session_hashes), len(set(session_hashes)))
        self.assertTrue(all(record["cleanupSuccess"] for record in records[1:]))
        self.assertTrue(all(record["taskRootFinalized"] for record in records[1:]))
        for call in first_dependencies.driver_calls:
            self.assertNotIn(call["session"], evidence)

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

    def test_resume_rejects_rehashed_reused_or_forged_session_hash(self):
        for case in ("reused", "forged"):
            output = self.root / case
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
            records[2]["sessionHash"] = (
                records[1]["sessionHash"] if case == "reused" else "z" * 64
            )
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
            with (
                self.subTest(case=case),
                self.assertRaises(matrix.MatrixResumeError),
            ):
                matrix.execute_matrix(
                    matrix.load_manifest(self.manifest_path),
                    output,
                    dependencies=FakeDependencies(),
                    resume=True,
                )

    def test_resume_rejects_rehashed_semantic_contradictions(self):
        mutations = (
            lambda record: record.update(result="FAIL"),
            lambda record: record.update(detail="product-route-failure"),
            lambda record: record.update(driverOutcome="launch-error"),
            lambda record: record.update(provenance="none"),
            lambda record: record.update(receipt=False),
            lambda record: record.update(browserIdentity=False),
        )
        for index, mutate in enumerate(mutations):
            output = self.root / f"semantic-{index}"
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
            mutate(records[1])
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
            with (
                self.subTest(index=index),
                self.assertRaises(matrix.MatrixResumeError),
            ):
                matrix.execute_matrix(
                    matrix.load_manifest(self.manifest_path),
                    output,
                    dependencies=FakeDependencies(),
                    resume=True,
                )

    def test_resume_incomplete_edge_pilot_blocks_without_execution(self):
        output = self.root / "incomplete-edge"
        matrix.execute_matrix(
            matrix.load_manifest(self.write_manifest()),
            output,
            dependencies=FakeDependencies(),
        )
        evidence_path = output / "evidence.jsonl"
        lines = evidence_path.read_text(encoding="utf-8").splitlines()
        evidence_path.write_text("\n".join(lines[:3]) + "\n", encoding="utf-8")

        resumed_dependencies = FakeDependencies()
        with self.assertRaises(matrix.MatrixResumeError):
            matrix.execute_matrix(
                matrix.load_manifest(self.manifest_path),
                output,
                dependencies=resumed_dependencies,
                resume=True,
            )
        self.assertEqual(resumed_dependencies.build_count, 0)
        self.assertEqual(resumed_dependencies.driver_calls, [])

    def test_resume_after_edge_stop_never_executes_later_cells(self):
        chrome = self.edge_application(
            bundleIdentifier="com.google.Chrome",
            applicationPath="/Applications/Google Chrome.app",
            executableRelativePath="Contents/MacOS/Google Chrome",
        )
        cases = (
            (
                "not-run",
                FakeDependencies(ambiguous_on=("com.microsoft.edgemac", "cold")),
                4,
                matrix.MATRIX_BLOCKED,
            ),
            (
                "edge-unsupported",
                FakeDependencies(
                    unsupported_on=("com.microsoft.edgemac", "normal", "cold")
                ),
                4,
                matrix.MATRIX_BLOCKED,
            ),
        )
        for case, initial_dependencies, prefix_lines, expected_exit in cases:
            output = self.root / case
            manifest = matrix.load_manifest(
                self.write_manifest([chrome, self.edge_application()])
            )
            matrix.execute_matrix(
                output=output, manifest=manifest, dependencies=initial_dependencies
            )
            evidence_path = output / "evidence.jsonl"
            lines = evidence_path.read_text(encoding="utf-8").splitlines()
            evidence_path.write_text(
                "\n".join(lines[:prefix_lines]) + "\n", encoding="utf-8"
            )

            resumed_dependencies = FakeDependencies()
            resumed = matrix.execute_matrix(
                matrix.load_manifest(self.manifest_path),
                output,
                dependencies=resumed_dependencies,
                resume=True,
            )
            with self.subTest(case=case):
                self.assertEqual(resumed.exit_code, expected_exit)
                self.assertEqual(resumed_dependencies.build_count, 0)
                self.assertEqual(resumed_dependencies.driver_calls, [])

    def test_resume_continues_after_complete_nonedge_outcomes_with_aggregate_status(
        self,
    ):
        chrome = self.edge_application(
            bundleIdentifier="com.google.Chrome",
            applicationPath="/Applications/Google Chrome.app",
            executableRelativePath="Contents/MacOS/Google Chrome",
        )
        opera = self.edge_application(
            bundleIdentifier="com.operasoftware.Opera",
            applicationPath="/Applications/Opera.app",
            executableRelativePath="Contents/MacOS/Opera",
            profileStrategy="none",
            browserPrivate=False,
            profile=False,
            profilePrivate=False,
        )
        manifest = matrix.load_manifest(
            self.write_manifest([chrome, opera, self.edge_application()])
        )
        cases = (
            (
                "product-fail",
                FakeDependencies(fail_on=("com.google.Chrome", "cold")),
                FakeDependencies(),
                matrix.MATRIX_PRODUCT_FAILURE,
            ),
            (
                "unsupported",
                FakeDependencies(
                    unsupported_on=("com.google.Chrome", "normal", "cold")
                ),
                FakeDependencies(),
                matrix.MATRIX_BLOCKED,
            ),
            (
                "signature",
                FakeDependencies(blocked_bundles={"com.google.Chrome"}),
                FakeDependencies(blocked_bundles={"com.google.Chrome"}),
                matrix.MATRIX_BLOCKED,
            ),
            (
                "absence",
                FakeDependencies(absent_bundles={"com.google.Chrome"}),
                FakeDependencies(absent_bundles={"com.google.Chrome"}),
                matrix.MATRIX_BLOCKED,
            ),
        )
        for case, initial, resumed_dependencies, expected_exit in cases:
            output = self.root / f"continue-{case}"
            matrix.execute_matrix(manifest, output, dependencies=initial)
            evidence = output / "evidence.jsonl"
            lines = evidence.read_text(encoding="utf-8").splitlines()
            evidence.write_text("\n".join(lines[:7]) + "\n", encoding="utf-8")
            resumed = matrix.execute_matrix(
                manifest,
                output,
                dependencies=resumed_dependencies,
                resume=True,
            )
            with self.subTest(case=case):
                self.assertEqual(resumed.exit_code, expected_exit)
                self.assertEqual(resumed_dependencies.build_count, 1)
                self.assertTrue(
                    any(
                        call["bundle_identifier"] == "com.operasoftware.Opera"
                        for call in resumed_dependencies.driver_calls
                    )
                )

    def test_resume_mixed_nonedge_results_preserves_product_failure_precedence(self):
        chrome = self.edge_application(
            bundleIdentifier="com.google.Chrome",
            applicationPath="/Applications/Google Chrome.app",
            executableRelativePath="Contents/MacOS/Google Chrome",
        )
        opera = self.edge_application(
            bundleIdentifier="com.operasoftware.Opera",
            applicationPath="/Applications/Opera.app",
            executableRelativePath="Contents/MacOS/Opera",
            profileStrategy="none",
            browserPrivate=False,
            profile=False,
            profilePrivate=False,
        )
        manifest = matrix.load_manifest(
            self.write_manifest([chrome, opera, self.edge_application()])
        )

        class MixedDependencies(FakeDependencies):
            def run_sequence(self, *args, **kwargs):
                group = args[1]
                capability = group[0].capability
                self.fail_on = (
                    ("com.google.Chrome", "cold") if capability == "normal" else None
                )
                self.unsupported_on = (
                    ("com.google.Chrome", "private", "cold")
                    if capability == "private"
                    else None
                )
                return super().run_sequence(*args, **kwargs)

        output = self.root / "mixed-resume"
        matrix.execute_matrix(manifest, output, dependencies=MixedDependencies())
        evidence = output / "evidence.jsonl"
        lines = evidence.read_text(encoding="utf-8").splitlines()
        evidence.write_text("\n".join(lines[:10]) + "\n", encoding="utf-8")
        dependencies = FakeDependencies()
        resumed = matrix.execute_matrix(
            manifest, output, dependencies=dependencies, resume=True
        )
        self.assertEqual(resumed.exit_code, matrix.MATRIX_PRODUCT_FAILURE)
        self.assertTrue(dependencies.driver_calls)
        self.assertTrue(
            any(
                call["bundle_identifier"] == "com.operasoftware.Opera"
                for call in dependencies.driver_calls
            )
        )

    def test_resume_stops_incomplete_or_ambiguous_nonedge_group(self):
        chrome = self.edge_application(
            bundleIdentifier="com.google.Chrome",
            applicationPath="/Applications/Google Chrome.app",
            executableRelativePath="Contents/MacOS/Google Chrome",
        )
        manifest = matrix.load_manifest(
            self.write_manifest([chrome, self.edge_application()])
        )
        for case, initial, prefix in (
            ("incomplete", FakeDependencies(), 5),
            (
                "ambiguous",
                FakeDependencies(ambiguous_on=("com.google.Chrome", "cold")),
                7,
            ),
        ):
            output = self.root / f"stop-{case}"
            matrix.execute_matrix(manifest, output, dependencies=initial)
            evidence = output / "evidence.jsonl"
            lines = evidence.read_text(encoding="utf-8").splitlines()
            evidence.write_text("\n".join(lines[:prefix]) + "\n", encoding="utf-8")
            dependencies = FakeDependencies()
            if case == "incomplete":
                with (
                    self.subTest(case=case),
                    self.assertRaises(matrix.MatrixResumeError),
                ):
                    matrix.execute_matrix(
                        manifest, output, dependencies=dependencies, resume=True
                    )
            else:
                resumed = matrix.execute_matrix(
                    manifest, output, dependencies=dependencies, resume=True
                )
                with self.subTest(case=case):
                    self.assertEqual(resumed.exit_code, matrix.MATRIX_BLOCKED)
            self.assertEqual(dependencies.build_count, 0)
            self.assertEqual(dependencies.driver_calls, [])

    def test_resume_rejects_same_version_static_identity_replacement(self):
        chrome = self.edge_application(
            bundleIdentifier="com.google.Chrome",
            applicationPath="/Applications/Google Chrome.app",
            executableRelativePath="Contents/MacOS/Google Chrome",
        )
        manifest = matrix.load_manifest(
            self.write_manifest([chrome, self.edge_application()])
        )
        output = self.root / "resume-static-change"
        matrix.execute_matrix(manifest, output, dependencies=FakeDependencies())
        evidence = output / "evidence.jsonl"
        lines = evidence.read_text(encoding="utf-8").splitlines()
        evidence.write_text("\n".join(lines[:4]) + "\n", encoding="utf-8")

        class ReplacedDependencies(FakeDependencies):
            def verify_application(self, application):
                verification = super().verify_application(application)
                if application.bundle_identifier == "com.microsoft.edgemac":
                    return matrix.VerifiedApplication(verification.version, "d" * 64)
                return verification

        dependencies = ReplacedDependencies()
        result = matrix.execute_matrix(
            manifest, output, dependencies=dependencies, resume=True
        )
        self.assertEqual(result.exit_code, matrix.MATRIX_BLOCKED)
        self.assertEqual(dependencies.build_count, 0)
        self.assertEqual(dependencies.driver_calls, [])
        self.assertTrue(
            all(record["result"] == "NOT RUN" for record in result.records[3:])
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
        absent_bundles=frozenset(),
        receipt_fail_on=None,
        unsupported_on=None,
        static_change_phase=None,
        verification_failure_phase=None,
        raise_on=None,
        unsafe_outcome=None,
        unsafe_version=None,
        omit_provenance=False,
    ):
        self.signature_ok = signature_ok
        self.fail_on = fail_on
        self.ambiguous_on = ambiguous_on
        self.blocked_bundles = set(blocked_bundles)
        self.absent_bundles = set(absent_bundles)
        self.receipt_fail_on = receipt_fail_on
        self.unsupported_on = unsupported_on
        self.static_change_phase = static_change_phase
        self.verification_failure_phase = verification_failure_phase
        self.raise_on = raise_on
        self.unsafe_outcome = unsafe_outcome
        self.unsafe_version = unsafe_version
        self.omit_provenance = omit_provenance
        self.build_count = 0
        self.driver_calls = []
        self.active_drivers = 0
        self.max_active_drivers = 0
        self.created_paths = []
        self.verification_counts = {}

    def is_installed(self, application):
        return application.bundle_identifier not in self.absent_bundles

    def verify_application(self, _application):
        count = self.verification_counts.get(_application.bundle_identifier, 0) + 1
        self.verification_counts[_application.bundle_identifier] = count
        if (
            not self.signature_ok
            or _application.bundle_identifier in self.blocked_bundles
        ):
            raise matrix.MatrixIdentityError("blocked")
        if (
            self.verification_failure_phase == "pre"
            and count == 2
            or self.verification_failure_phase == "post"
            and count == 3
        ):
            raise matrix.MatrixIdentityError("transient verification failure")
        changed = (
            self.static_change_phase == "pre"
            and count == 2
            or (self.static_change_phase == "post" and count == 3)
        )
        return matrix.VerifiedApplication(
            "152.0" if changed else self.unsafe_version or "151.0",
            "c" * 64 if changed else "b" * 64,
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
        sessions,
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
            for item, session, request in zip(group, sessions, requests):
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
                group, sessions, requests, e2e_app_identity, browser_app_identity
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
            receipt_failure_index = next(
                (
                    index
                    for index, item in enumerate(group)
                    if (item.bundle_identifier, item.state) == self.receipt_fail_on
                ),
                None,
            )
            if receipt_failure_index is not None:
                report["stateProofs"] = report["stateProofs"][
                    : receipt_failure_index + 1
                ]
                report["stateProofs"][-1].update(
                    outcome="receipt-timeout",
                    receipt=False,
                )
                report.update(
                    outcome="receipt-timeout",
                    token_received=False,
                    exact_browser_process_identity=True,
                    launch_provenance="launch-observed",
                )
                return report, matrix.browser_driver.DRIVER_RECEIPT_TIMEOUT
            unsupported_index = next(
                (
                    index
                    for index, item in enumerate(group)
                    if (item.bundle_identifier, item.capability, item.state)
                    == self.unsupported_on
                ),
                None,
            )
            if unsupported_index is not None:
                report["stateProofs"] = report["stateProofs"][: unsupported_index + 1]
                report["stateProofs"][-1].update(
                    outcome="target-missing",
                    receipt=False,
                    browserIdentity=False,
                    provenance="none",
                    processIdentifier=None,
                    processStartSeconds=None,
                    processStartMicroseconds=None,
                )
                report.update(
                    outcome="target-missing",
                    token_received=False,
                    exact_browser_process_identity=False,
                    launch_provenance="none",
                )
                return report, matrix.browser_driver.DRIVER_SELECTION_REJECTED
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
        self, group, sessions, requests, e2e_app_identity, browser_app_identity
    ):
        cell = group[0]
        target_id = (
            f"{cell.bundle_identifier}|PickVia E2E|{cell.mode}"
            if cell.has_profile and cell.profile_strategy == "chromium"
            else f"{cell.bundle_identifier}||{cell.mode}"
        )
        return {
            "schemaVersion": 1,
            "session": sessions[0],
            "sessionHashes": [
                hashlib.sha256(session.encode("ascii")).hexdigest()
                for session in sessions
            ],
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
                    "session": session,
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
                for item, session, request in zip(group, sessions, requests)
            ],
        }


if __name__ == "__main__":
    unittest.main()
