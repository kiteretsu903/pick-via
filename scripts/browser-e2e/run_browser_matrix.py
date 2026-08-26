#!/usr/bin/env python3

import argparse
import ctypes
import dataclasses
import fcntl
import hashlib
import hmac
import json
import math
import os
import pathlib
import plistlib
import re
import secrets
import signal
import stat
import subprocess
import sys
import tempfile
import time

import pickvia_e2e_driver as browser_driver
import smoke_e2e_runtime


MATRIX_SUCCESS = 0
MATRIX_PRODUCT_FAILURE = 1
MATRIX_USAGE = 2
MATRIX_BLOCKED = 3
DRIVER_AMBIGUOUS = browser_driver.DRIVER_BROWSER_IDENTITY_AMBIGUOUS

_SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
_REPOSITORY_ROOT = _SCRIPT_DIR.parent.parent
_MANIFEST_KEYS = frozenset({"schemaVersion", "applications"})
_APPLICATION_KEYS = frozenset(
    {
        "bundleIdentifier",
        "applicationPath",
        "executableRelativePath",
        "profileStrategy",
        "normalStrategy",
        "browserPrivate",
        "profile",
        "profilePrivate",
        "skip",
    }
)
_APPLE_SKIPPED = frozenset({"com.apple.Safari", "com.apple.SafariTechnologyPreview"})
_PROFILE_STRATEGIES = frozenset({"none", "chromium", "firefox"})
_NORMAL_STRATEGIES = frozenset({"unsupported", "workspace", "executable", "duckduckgo"})
_STATES = ("cold", "running", "reopen")
_RESULTS = frozenset({"PASS", "FAIL", "UNSUPPORTED", "NOT RUN"})
_MAXIMUM_MANIFEST_BYTES = 256 * 1024
_MAXIMUM_EVIDENCE_BYTES = 8 * 1024 * 1024
_EVIDENCE_NAME = "evidence.jsonl"
_FINALIZATION_KEY_NAME = ".finalization-key"
_FINALIZATION_KEY_BYTES = 32
_FINALIZATION_PROOF_DOMAIN = b"pickvia-browser-matrix-finalization-v1\0"
_RUN_KEY_PROOF_DOMAIN = b"pickvia-browser-matrix-run-key-v1\0"
_REQUIRED_APPLICATIONS = {
    "com.google.Chrome": (
        "/Applications/Google Chrome.app",
        "Contents/MacOS/Google Chrome",
        "chromium",
        "workspace",
        True,
        True,
        False,
        False,
    ),
    "com.google.Chrome.beta": (
        "/Applications/Google Chrome Beta.app",
        "Contents/MacOS/Google Chrome Beta",
        "chromium",
        "workspace",
        True,
        True,
        False,
        False,
    ),
    "com.google.Chrome.dev": (
        "/Applications/Google Chrome Dev.app",
        "Contents/MacOS/Google Chrome Dev",
        "chromium",
        "workspace",
        True,
        True,
        False,
        False,
    ),
    "com.google.Chrome.canary": (
        "/Applications/Google Chrome Canary.app",
        "Contents/MacOS/Google Chrome Canary",
        "chromium",
        "workspace",
        True,
        True,
        False,
        False,
    ),
    "com.microsoft.edgemac": (
        "/Applications/Microsoft Edge.app",
        "Contents/MacOS/Microsoft Edge",
        "chromium",
        "workspace",
        True,
        True,
        False,
        False,
    ),
    "com.microsoft.edgemac.Beta": (
        "/Applications/Microsoft Edge Beta.app",
        "Contents/MacOS/Microsoft Edge Beta",
        "chromium",
        "workspace",
        True,
        True,
        False,
        False,
    ),
    "com.microsoft.edgemac.Dev": (
        "/Applications/Microsoft Edge Dev.app",
        "Contents/MacOS/Microsoft Edge Dev",
        "chromium",
        "workspace",
        True,
        True,
        False,
        False,
    ),
    "com.microsoft.edgemac.Canary": (
        "/Applications/Microsoft Edge Canary.app",
        "Contents/MacOS/Microsoft Edge Canary",
        "chromium",
        "workspace",
        True,
        True,
        False,
        False,
    ),
    "com.brave.Browser": (
        "/Applications/Brave Browser.app",
        "Contents/MacOS/Brave Browser",
        "chromium",
        "workspace",
        True,
        True,
        False,
        False,
    ),
    "com.brave.Browser.beta": (
        "/Applications/Brave Browser Beta.app",
        "Contents/MacOS/Brave Browser Beta",
        "chromium",
        "workspace",
        True,
        True,
        False,
        False,
    ),
    "com.brave.Browser.nightly": (
        "/Applications/Brave Browser Nightly.app",
        "Contents/MacOS/Brave Browser Nightly",
        "chromium",
        "workspace",
        True,
        True,
        False,
        False,
    ),
    "com.vivaldi.Vivaldi": (
        "/Applications/Vivaldi.app",
        "Contents/MacOS/Vivaldi",
        "chromium",
        "workspace",
        True,
        True,
        False,
        False,
    ),
    "com.vivaldi.Vivaldi.snapshot": (
        "/Applications/Vivaldi Snapshot.app",
        "Contents/MacOS/Vivaldi Snapshot",
        "chromium",
        "workspace",
        True,
        True,
        False,
        False,
    ),
    "org.mozilla.firefox": (
        "/Applications/Firefox.app",
        "Contents/MacOS/firefox",
        "firefox",
        "executable",
        True,
        True,
        False,
        False,
    ),
    "org.mozilla.firefoxdeveloperedition": (
        "/Applications/Firefox Developer Edition.app",
        "Contents/MacOS/firefox",
        "firefox",
        "executable",
        True,
        True,
        False,
        False,
    ),
    "org.mozilla.nightly": (
        "/Applications/Firefox Nightly.app",
        "Contents/MacOS/firefox",
        "firefox",
        "executable",
        True,
        True,
        False,
        False,
    ),
    "com.operasoftware.Opera": (
        "/Applications/Opera.app",
        "Contents/MacOS/Opera",
        "none",
        "workspace",
        False,
        False,
        False,
        False,
    ),
    "company.thebrowser.Browser": (
        "/Applications/Arc.app",
        "Contents/MacOS/Arc",
        "none",
        "workspace",
        False,
        False,
        False,
        False,
    ),
    "com.kagi.kagimacOS": (
        "/Applications/Orion.app",
        "Contents/MacOS/Orion",
        "none",
        "workspace",
        False,
        False,
        False,
        False,
    ),
    "com.duckduckgo.macos.browser": (
        "/Applications/DuckDuckGo.app",
        "Contents/MacOS/DuckDuckGo",
        "none",
        "duckduckgo",
        True,
        False,
        False,
        False,
    ),
    "com.apple.Safari": (
        "/Applications/Safari.app",
        "Contents/MacOS/Safari",
        "none",
        "workspace",
        False,
        False,
        False,
        True,
    ),
    "com.apple.SafariTechnologyPreview": (
        "/Applications/Safari Technology Preview.app",
        "Contents/MacOS/Safari Technology Preview",
        "none",
        "workspace",
        False,
        False,
        False,
        True,
    ),
}
_SAFE_VERSION = re.compile(r"\A[A-Za-z0-9][A-Za-z0-9._+()-]{0,127}\Z")
_SAFE_HASH = re.compile(r"\A[0-9a-f]{64}\Z")
_SAFE_DRIVER_OUTCOMES = frozenset(
    {
        "selected",
        "launch-error",
        "receipt-timeout",
        "target-disabled",
        "target-missing",
        "target-mode-mismatch",
        "identity-ambiguous",
        "identity-inspection-error",
        "provenance-error",
        "invalid-status",
        "invalid-receipt",
        "browser-identity-timeout",
        "helper-error",
        "helper-exit-timeout",
        "readiness-error",
        "identity-error",
        "process-error",
        "driver-error",
        "timeout",
        "cleanup-error",
        "cleanup-interrupted",
        "privacy-failure",
        "not-invoked",
        "invalid-driver-report",
    }
)
_SAFE_PROVENANCE = frozenset(
    {"none", "launch-observed", "launch-error", "launch-unproven", "invalid"}
)
_SAFE_DETAILS = frozenset(
    {
        "proven-route",
        "product-route-failure",
        "product-receipt-failure",
        "catalog-capability-refused",
        "harness-ambiguity",
        "signature-blocker",
        "installed-absence",
        "blocked-before-run",
        "blocked-after-ambiguity",
        "edge-pilot-failed",
        "build-blocker",
        "blocked-after-sequence-failure",
        "blocked-after-sequence-refusal",
        "browser-identity-changed",
    }
)
_CELL_REQUIRED_KEYS = frozenset(
    {
        "recordType",
        "schemaVersion",
        "sequence",
        "cellHash",
        "bundleIdentifier",
        "capability",
        "state",
        "installedVersion",
        "browserStaticHash",
        "result",
        "detail",
        "driverOutcome",
        "provenance",
        "receipt",
        "e2eIdentity",
        "browserIdentity",
        "sessionHash",
        "cleanupSuccess",
        "taskRootFinalized",
        "previousHash",
        "recordHash",
    }
)
_CELL_OPTIONAL_KEYS = frozenset({"taskFinalizationSource", "taskFinalizationProof"})

_NONINVOKED_DETAILS = frozenset(
    {
        "harness-ambiguity",
        "signature-blocker",
        "installed-absence",
        "blocked-before-run",
        "blocked-after-ambiguity",
        "edge-pilot-failed",
        "build-blocker",
        "blocked-after-sequence-failure",
        "blocked-after-sequence-refusal",
        "browser-identity-changed",
    }
)
_FINALIZED_NONINVOKED_DETAILS = frozenset(
    {
        "harness-ambiguity",
        "signature-blocker",
        "blocked-after-sequence-failure",
        "blocked-after-sequence-refusal",
        "browser-identity-changed",
    }
)
_AUTHENTICATED_FINALIZATION_SOURCE = "authenticated-handoff"
_CELL_TIMING_KEYS = frozenset(
    {
        "totalElapsedSeconds",
        "routeTimeoutSeconds",
        "cleanupGraceSeconds",
        "quiescenceSeconds",
    }
)


class MatrixError(RuntimeError):
    pass


class MatrixManifestError(MatrixError):
    pass


class MatrixIdentityError(MatrixError):
    pass


class MatrixResumeError(MatrixError):
    pass


class DriverProofError(MatrixError):
    pass


@dataclasses.dataclass(frozen=True)
class DriverProofExpectation:
    session: str
    request: str
    bundle_identifier: str
    target_id: str
    capability: str
    state: str
    mode: str
    mechanism: str
    e2e_app_identity: str
    browser_app_identity: str


_DRIVER_REPORT_KEYS = frozenset(
    {
        "schemaVersion",
        "session",
        "sessionHashes",
        "request",
        "bundleIdentifier",
        "targetID",
        "capability",
        "state",
        "mode",
        "mechanism",
        "e2eAppIdentity",
        "browserAppIdentity",
        "outcome",
        "token_received",
        "exact_process_identity",
        "exact_browser_process_identity",
        "launch_provenance",
        "total_elapsed_seconds",
        "route_timeout_seconds",
        "browser_cleanup_grace_seconds",
        "browser_quiescence_seconds",
        "provenance_settle_seconds",
        "provenance_status_grace_seconds",
        "cleanup_success",
        "task_root_finalized",
        "stateProofs",
    }
)
_STATE_PROOF_KEYS = frozenset(
    {
        "state",
        "session",
        "request",
        "outcome",
        "receipt",
        "e2eIdentity",
        "browserIdentity",
        "provenance",
        "processIdentifier",
        "processStartSeconds",
        "processStartMicroseconds",
        "routeElapsedSeconds",
    }
)


def _session_hash(session):
    return hashlib.sha256(session.encode("ascii")).hexdigest()


def _valid_process_generation_proof(proof):
    return (
        type(proof.get("processIdentifier")) is int
        and proof["processIdentifier"] > 0
        and type(proof.get("processStartSeconds")) is int
        and proof["processStartSeconds"] > 0
        and type(proof.get("processStartMicroseconds")) is int
        and 0 <= proof["processStartMicroseconds"] < 1_000_000
    )


def validate_driver_report(report, return_code, expected):
    if not isinstance(report, dict) or set(report) != _DRIVER_REPORT_KEYS:
        raise DriverProofError("driver report schema mismatch")
    exact_fields = {
        "schemaVersion": 1,
        "session": expected.session,
        "sessionHashes": [_session_hash(expected.session)],
        "request": expected.request,
        "bundleIdentifier": expected.bundle_identifier,
        "capability": expected.capability,
        "state": expected.state,
        "mode": expected.mode,
        "mechanism": expected.mechanism,
        "e2eAppIdentity": expected.e2e_app_identity,
        "browserAppIdentity": expected.browser_app_identity,
        "browser_cleanup_grace_seconds": 5.0,
        "browser_quiescence_seconds": 2.0,
        "provenance_settle_seconds": 0.25,
        "provenance_status_grace_seconds": 1.0,
        "cleanup_success": True,
        "task_root_finalized": True,
    }
    if expected.target_id == "firefox-derived":
        target_matches = (
            re.fullmatch(
                re.escape(expected.bundle_identifier)
                + r"\|firefox-profile-v1:[0-9a-f]{64}\|"
                + re.escape(expected.mode),
                report.get("targetID", ""),
            )
            is not None
        )
    else:
        target_matches = report.get("targetID") == expected.target_id
    if not target_matches or any(
        report.get(key) != value for key, value in exact_fields.items()
    ):
        raise DriverProofError("driver proof identity mismatch")
    state_proofs = report["stateProofs"]
    if not isinstance(state_proofs, list) or len(state_proofs) != 1:
        raise DriverProofError("driver state proof count mismatch")
    state_proof = state_proofs[0]
    if (
        not isinstance(state_proof, dict)
        or set(state_proof) != _STATE_PROOF_KEYS
        or state_proof["state"] != expected.state
        or state_proof["session"] != expected.session
        or state_proof["request"] != expected.request
        or state_proof["outcome"] != report["outcome"]
        or state_proof["receipt"] != report["token_received"]
        or state_proof["browserIdentity"] != report["exact_browser_process_identity"]
        or state_proof["provenance"] != report["launch_provenance"]
        or state_proof["e2eIdentity"] is not True
        or type(state_proof["routeElapsedSeconds"]) not in {int, float}
        or not math.isfinite(state_proof["routeElapsedSeconds"])
        or state_proof["routeElapsedSeconds"] < 0
    ):
        raise DriverProofError("driver state proof mismatch")
    for key in (
        "token_received",
        "exact_process_identity",
        "exact_browser_process_identity",
        "cleanup_success",
        "task_root_finalized",
    ):
        if type(report[key]) is not bool:
            raise DriverProofError("driver proof boolean mismatch")
    for key in (
        "total_elapsed_seconds",
        "route_timeout_seconds",
        "browser_cleanup_grace_seconds",
        "browser_quiescence_seconds",
        "provenance_settle_seconds",
        "provenance_status_grace_seconds",
    ):
        value = report[key]
        if type(value) not in {int, float} or not math.isfinite(value) or value < 0:
            raise DriverProofError("driver proof timing mismatch")
    if report["route_timeout_seconds"] <= 0 or report["total_elapsed_seconds"] < 0:
        raise DriverProofError("driver proof timing mismatch")
    if report["total_elapsed_seconds"] + 0.00001 < state_proof["routeElapsedSeconds"]:
        raise DriverProofError("driver proof timing coherence mismatch")
    if (
        return_code == 0
        and report["outcome"] == "selected"
        and report["token_received"] is True
        and report["exact_process_identity"] is True
        and report["exact_browser_process_identity"] is True
        and report["launch_provenance"] == "launch-observed"
        and _valid_process_generation_proof(state_proof)
    ):
        return "PASS", "proven-route", False
    if (
        return_code == browser_driver.DRIVER_SELECTION_REJECTED
        and report["outcome"] == "launch-error"
        and report["token_received"] is False
        and report["exact_process_identity"] is True
        and report["exact_browser_process_identity"] is False
        and report["launch_provenance"] == "launch-error"
        and state_proof["browserIdentity"] is False
        and all(
            state_proof[key] is None
            for key in (
                "processIdentifier",
                "processStartSeconds",
                "processStartMicroseconds",
            )
        )
    ):
        return "FAIL", "product-route-failure", False
    if (
        return_code == browser_driver.DRIVER_SELECTION_REJECTED
        and report["outcome"] in {"target-disabled", "target-mode-mismatch"}
        and report["token_received"] is False
        and report["exact_process_identity"] is True
        and report["exact_browser_process_identity"] is False
        and report["launch_provenance"] == "none"
        and state_proof["receipt"] is False
        and state_proof["browserIdentity"] is False
        and all(
            state_proof[key] is None
            for key in (
                "processIdentifier",
                "processStartSeconds",
                "processStartMicroseconds",
            )
        )
    ):
        return "UNSUPPORTED", "catalog-capability-refused", False
    raise DriverProofError("driver proof outcome mismatch")


def validate_driver_sequence_report(report, return_code, expectations):
    if len(expectations) != 3 or len({item.session for item in expectations}) != 3:
        raise DriverProofError("sequence expectation mismatch")
    first = expectations[0]
    if not isinstance(report, dict) or set(report) != _DRIVER_REPORT_KEYS:
        raise DriverProofError("driver report schema mismatch")
    exact = {
        "schemaVersion": 1,
        "session": first.session,
        "sessionHashes": [_session_hash(item.session) for item in expectations],
        "request": first.request,
        "bundleIdentifier": first.bundle_identifier,
        "capability": first.capability,
        "state": "sequence",
        "mode": first.mode,
        "mechanism": first.mechanism,
        "e2eAppIdentity": first.e2e_app_identity,
        "browserAppIdentity": first.browser_app_identity,
        "browser_cleanup_grace_seconds": 5.0,
        "browser_quiescence_seconds": 2.0,
        "provenance_settle_seconds": 0.25,
        "provenance_status_grace_seconds": 1.0,
        "cleanup_success": True,
        "task_root_finalized": True,
    }
    target = report.get("targetID", "")
    target_ok = all(
        expectation.target_id == target
        or expectation.target_id == "firefox-derived"
        and re.fullmatch(
            re.escape(expectation.bundle_identifier)
            + r"\|firefox-profile-v1:[0-9a-f]{64}\|"
            + re.escape(expectation.mode),
            target,
        )
        is not None
        for expectation in expectations
    )
    if not target_ok or any(report.get(key) != value for key, value in exact.items()):
        raise DriverProofError("sequence report identity mismatch")
    for key in (
        "token_received",
        "exact_process_identity",
        "exact_browser_process_identity",
        "cleanup_success",
        "task_root_finalized",
    ):
        if type(report.get(key)) is not bool:
            raise DriverProofError("sequence report boolean mismatch")
    for key in (
        "total_elapsed_seconds",
        "route_timeout_seconds",
        "browser_cleanup_grace_seconds",
        "browser_quiescence_seconds",
        "provenance_settle_seconds",
        "provenance_status_grace_seconds",
    ):
        value = report.get(key)
        if type(value) not in {int, float} or not math.isfinite(value) or value < 0:
            raise DriverProofError("sequence report timing mismatch")
    if (
        report["route_timeout_seconds"] <= 0
        or report["exact_process_identity"] is not True
    ):
        raise DriverProofError("sequence report prerequisite mismatch")
    proofs = report["stateProofs"]
    if not isinstance(proofs, list) or not 1 <= len(proofs) <= 3:
        raise DriverProofError("sequence proof count mismatch")
    generations = []
    results = []
    for index, proof in enumerate(proofs):
        expectation = expectations[index]
        if (
            not isinstance(proof, dict)
            or set(proof) != _STATE_PROOF_KEYS
            or proof.get("state") != expectation.state
            or proof.get("session") != expectation.session
            or proof.get("request") != expectation.request
            or proof.get("e2eIdentity") is not True
            or type(proof.get("routeElapsedSeconds")) not in {int, float}
            or not math.isfinite(proof["routeElapsedSeconds"])
            or proof["routeElapsedSeconds"] < 0
        ):
            raise DriverProofError("sequence state proof mismatch")
        if (
            proof.get("outcome") == "selected"
            and proof.get("receipt") is True
            and proof.get("browserIdentity") is True
            and proof.get("provenance") == "launch-observed"
            and _valid_process_generation_proof(proof)
        ):
            generations.append(
                (
                    proof["processIdentifier"],
                    proof["processStartSeconds"],
                    proof["processStartMicroseconds"],
                )
            )
            results.append(("PASS", "proven-route"))
            continue
        if (
            proof.get("outcome") == "launch-error"
            and proof.get("receipt") is False
            and proof.get("browserIdentity") is False
            and proof.get("provenance") in {"none", "launch-error"}
            and all(
                proof.get(key) is None
                for key in (
                    "processIdentifier",
                    "processStartSeconds",
                    "processStartMicroseconds",
                )
            )
        ):
            results.append(("FAIL", "product-route-failure"))
            break
        if (
            proof.get("outcome") == "receipt-timeout"
            and proof.get("receipt") is False
            and proof.get("browserIdentity") is True
            and proof.get("provenance") == "launch-observed"
            and _valid_process_generation_proof(proof)
        ):
            generations.append(
                (
                    proof["processIdentifier"],
                    proof["processStartSeconds"],
                    proof["processStartMicroseconds"],
                )
            )
            results.append(("FAIL", "product-receipt-failure"))
            break
        if (
            proof.get("outcome")
            in {"target-disabled", "target-missing", "target-mode-mismatch"}
            and proof.get("receipt") is False
            and proof.get("browserIdentity") is False
            and proof.get("provenance") == "none"
            and all(
                proof.get(key) is None
                for key in (
                    "processIdentifier",
                    "processStartSeconds",
                    "processStartMicroseconds",
                )
            )
        ):
            results.append(("UNSUPPORTED", "catalog-capability-refused"))
            break
        raise DriverProofError("sequence state proof incoherent")
    if report["total_elapsed_seconds"] + 0.00001 < sum(
        proof["routeElapsedSeconds"] for proof in proofs
    ):
        raise DriverProofError("sequence timing coherence mismatch")
    if len(generations) >= 2 and generations[0] != generations[1]:
        raise DriverProofError("running generation changed")
    if len(generations) == 3 and generations[2] == generations[0]:
        raise DriverProofError("reopen generation was reused")
    if len(results) == 3 and all(result == "PASS" for result, _ in results):
        if (
            return_code != 0
            or report["outcome"] != "selected"
            or report["token_received"] is not True
            or report["exact_browser_process_identity"] is not True
            or report["launch_provenance"] != "launch-observed"
        ):
            raise DriverProofError("sequence success mismatch")
    elif results and results[-1] == ("FAIL", "product-route-failure"):
        if (
            return_code != browser_driver.DRIVER_SELECTION_REJECTED
            or report["outcome"] != "launch-error"
            or report["token_received"] is not False
            or report["exact_browser_process_identity"] is not False
            or report["launch_provenance"] not in {"none", "launch-error"}
        ):
            raise DriverProofError("sequence product failure mismatch")
    elif results and results[-1] == ("FAIL", "product-receipt-failure"):
        if (
            return_code != browser_driver.DRIVER_RECEIPT_TIMEOUT
            or report["outcome"] != "receipt-timeout"
            or report["token_received"] is not False
            or report["exact_browser_process_identity"] is not True
            or report["launch_provenance"] != "launch-observed"
        ):
            raise DriverProofError("sequence product receipt failure mismatch")
    elif results and results[-1] == (
        "UNSUPPORTED",
        "catalog-capability-refused",
    ):
        if (
            return_code != browser_driver.DRIVER_SELECTION_REJECTED
            or report["outcome"]
            not in {"target-disabled", "target-missing", "target-mode-mismatch"}
            or report["outcome"] != proofs[-1]["outcome"]
            or report["token_received"] is not False
            or report["exact_browser_process_identity"] is not False
            or report["launch_provenance"] != "none"
        ):
            raise DriverProofError("sequence capability refusal mismatch")
    else:
        raise DriverProofError("incomplete sequence proof")
    blocked_detail = (
        "blocked-after-sequence-refusal"
        if results[-1][0] == "UNSUPPORTED"
        else "blocked-after-sequence-failure"
    )
    while len(results) < 3:
        results.append(("NOT RUN", blocked_detail))
    return tuple(results)


@dataclasses.dataclass(frozen=True)
class MatrixApplication:
    bundle_identifier: str
    application_path: pathlib.Path
    executable_relative_path: pathlib.PurePosixPath
    profile_strategy: str
    normal_strategy: str
    browser_private: bool
    profile: bool
    profile_private: bool
    skip: bool

    @property
    def executable_path(self):
        return self.application_path.joinpath(*self.executable_relative_path.parts)


@dataclasses.dataclass(frozen=True)
class MatrixManifest:
    schema_version: int
    applications: tuple
    digest: str


@dataclasses.dataclass(frozen=True)
class VerifiedApplication:
    version: str
    identity: str


@dataclasses.dataclass(frozen=True)
class MatrixCell:
    sequence: int
    bundle_identifier: str
    capability: str
    state: str
    application: MatrixApplication
    installed: bool = True

    @property
    def has_profile(self):
        return self.capability in {"profile", "profile-private"}

    @property
    def mode(self):
        return (
            "private" if self.capability in {"private", "profile-private"} else "normal"
        )

    @property
    def profile_strategy(self):
        return self.application.profile_strategy

    @property
    def mechanism(self):
        if self.application.normal_strategy == "duckduckgo":
            return "duckduckgo"
        if (
            self.capability == "normal"
            and self.application.normal_strategy == "workspace"
        ):
            return "workspace"
        return "process"

    @property
    def identifier(self):
        return f"{self.bundle_identifier}|{self.capability}|{self.state}"

    @property
    def specification_hash(self):
        return _digest_json(
            {
                "bundleIdentifier": self.bundle_identifier,
                "capability": self.capability,
                "mechanism": self.mechanism,
                "profileStrategy": self.profile_strategy
                if self.has_profile
                else "none",
                "state": self.state,
            }
        )


@dataclasses.dataclass(frozen=True)
class MatrixExecutionResult:
    exit_code: int
    records: tuple


def _unique_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise MatrixManifestError("duplicate key")
        value[key] = item
    return value


def _reject_constant(_value):
    raise MatrixManifestError("nonfinite JSON value")


def _load_strict_json(path, maximum_bytes, error_type):
    try:
        path = pathlib.Path(os.path.abspath(os.fspath(path)))
        if not path.name or path.parent == path:
            raise error_type("unsafe JSON path")
        parent_components = (path.parent, *tuple(path.parent.parents)[:-1])
        for component in reversed(parent_components):
            metadata = component.lstat()
            if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
                raise error_type("unsafe JSON parent")
        initial_parent = path.parent.lstat()
        parent_descriptor = os.open(
            path.parent,
            os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | getattr(os, "O_NOFOLLOW", 0),
        )
        try:
            opened_parent = os.fstat(parent_descriptor)
            if _entry_generation(initial_parent) != _entry_generation(opened_parent):
                raise error_type("JSON parent changed")
            descriptor = os.open(
                path.name,
                os.O_RDONLY | os.O_CLOEXEC | getattr(os, "O_NOFOLLOW", 0),
                dir_fd=parent_descriptor,
            )
            try:
                before = os.fstat(descriptor)
                named = os.stat(
                    path.name, dir_fd=parent_descriptor, follow_symlinks=False
                )
                if (
                    not stat.S_ISREG(before.st_mode)
                    or stat.S_ISLNK(named.st_mode)
                    or before.st_uid != os.getuid()
                    or before.st_nlink != 1
                    or _entry_generation(before) != _entry_generation(named)
                    or before.st_size <= 0
                    or before.st_size > maximum_bytes
                ):
                    raise error_type("unsafe JSON file")
                chunks = bytearray()
                while len(chunks) <= maximum_bytes:
                    chunk = os.read(
                        descriptor, min(65_536, maximum_bytes + 1 - len(chunks))
                    )
                    if not chunk:
                        break
                    chunks.extend(chunk)
                after = os.fstat(descriptor)
                if (
                    len(chunks) != before.st_size
                    or _entry_generation(after) != _entry_generation(before)
                    or after.st_size != before.st_size
                    or after.st_mtime_ns != before.st_mtime_ns
                    or after.st_ctime_ns != before.st_ctime_ns
                ):
                    raise error_type("JSON changed while reading")
                data = bytes(chunks)
                final_named = os.stat(
                    path.name, dir_fd=parent_descriptor, follow_symlinks=False
                )
                if browser_driver._EntryIdentity.from_stat(
                    final_named
                ) != browser_driver._EntryIdentity.from_stat(before):
                    raise error_type("JSON name changed while reading")
            finally:
                os.close(descriptor)
            final_parent = path.parent.lstat()
            if _entry_generation(os.fstat(parent_descriptor)) != _entry_generation(
                opened_parent
            ) or _entry_generation(final_parent) != _entry_generation(opened_parent):
                raise error_type("JSON parent changed")
        finally:
            os.close(parent_descriptor)
        if not data or len(data) > maximum_bytes or not data.endswith(b"\n"):
            raise error_type("invalid JSON framing")
        text = data.decode("utf-8")
        decoder = json.JSONDecoder(
            object_pairs_hook=_unique_object,
            parse_constant=_reject_constant,
        )
        value, end = decoder.raw_decode(text)
        if text[end:] != "\n":
            raise error_type("trailing JSON content")
        return value, data
    except error_type:
        raise
    except (
        OSError,
        UnicodeDecodeError,
        json.JSONDecodeError,
        MatrixManifestError,
    ) as error:
        raise error_type("invalid JSON") from error


def _valid_bundle_identifier(value):
    if not isinstance(value, str) or not 3 <= len(value) <= 255:
        return False
    allowed = frozenset(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-"
    )
    return value[0].isalnum() and all(character in allowed for character in value)


def _parse_absolute_application_path(value):
    if not isinstance(value, str) or not value.startswith("/Applications/"):
        raise MatrixManifestError("unsafe application path")
    path = pathlib.Path(value)
    if (
        not path.is_absolute()
        or path.suffix != ".app"
        or pathlib.Path(os.path.normpath(value)) != path
        or any(part in {"", ".", ".."} for part in path.parts[1:])
    ):
        raise MatrixManifestError("unsafe application path")
    return path


def _parse_executable_relative_path(value):
    if not isinstance(value, str) or not value:
        raise MatrixManifestError("unsafe executable path")
    path = pathlib.PurePosixPath(value)
    if (
        path.is_absolute()
        or path.as_posix() != value
        or len(path.parts) < 3
        or path.parts[:2] != ("Contents", "MacOS")
        or any(part in {"", ".", ".."} for part in path.parts)
    ):
        raise MatrixManifestError("unsafe executable path")
    return path


def load_manifest(path, *, enforce_required=False):
    document, data = _load_strict_json(
        path, _MAXIMUM_MANIFEST_BYTES, MatrixManifestError
    )
    if not isinstance(document, dict) or set(document) != _MANIFEST_KEYS:
        raise MatrixManifestError("invalid manifest shape")
    if type(document["schemaVersion"]) is not int or document["schemaVersion"] != 1:
        raise MatrixManifestError("unsupported schema")
    raw_applications = document["applications"]
    if not isinstance(raw_applications, list) or not raw_applications:
        raise MatrixManifestError("empty application list")
    applications = []
    seen = set()
    for raw in raw_applications:
        if not isinstance(raw, dict) or set(raw) != _APPLICATION_KEYS:
            raise MatrixManifestError("invalid application shape")
        bundle_identifier = raw["bundleIdentifier"]
        if not _valid_bundle_identifier(bundle_identifier) or bundle_identifier in seen:
            raise MatrixManifestError("invalid or duplicate bundle identifier")
        seen.add(bundle_identifier)
        application_path = _parse_absolute_application_path(raw["applicationPath"])
        executable = _parse_executable_relative_path(raw["executableRelativePath"])
        profile_strategy = raw["profileStrategy"]
        normal_strategy = raw["normalStrategy"]
        flags = (
            raw["browserPrivate"],
            raw["profile"],
            raw["profilePrivate"],
            raw["skip"],
        )
        if (
            profile_strategy not in _PROFILE_STRATEGIES
            or normal_strategy not in _NORMAL_STRATEGIES
            or any(type(flag) is not bool for flag in flags)
            or (raw["profile"] or raw["profilePrivate"])
            and profile_strategy == "none"
            or raw["profilePrivate"]
            and not raw["profile"]
            or bundle_identifier in _APPLE_SKIPPED
            and not raw["skip"]
            or bundle_identifier in _APPLE_SKIPPED
            and any(flags[:3])
            or bundle_identifier not in _APPLE_SKIPPED
            and raw["skip"]
        ):
            raise MatrixManifestError("inconsistent capability policy")
        applications.append(
            MatrixApplication(
                bundle_identifier,
                application_path,
                executable,
                profile_strategy,
                normal_strategy,
                raw["browserPrivate"],
                raw["profile"],
                raw["profilePrivate"],
                raw["skip"],
            )
        )
    if enforce_required:
        observed = {
            application.bundle_identifier: (
                os.fspath(application.application_path),
                application.executable_relative_path.as_posix(),
                application.profile_strategy,
                application.normal_strategy,
                application.browser_private,
                application.profile,
                application.profile_private,
                application.skip,
            )
            for application in applications
        }
        if observed != _REQUIRED_APPLICATIONS:
            raise MatrixManifestError("required application identity set mismatch")
    return MatrixManifest(1, tuple(applications), hashlib.sha256(data).hexdigest())


def _application_capabilities(application):
    capabilities = []
    if application.normal_strategy != "unsupported":
        capabilities.append("normal")
    if application.browser_private:
        capabilities.append("private")
    if application.profile:
        capabilities.append("profile")
    if application.profile_private:
        capabilities.append("profile-private")
    return capabilities


def plan_cells(manifest, is_installed):
    eligible = [
        (application, is_installed(application))
        for application in manifest.applications
        if not application.skip and application.bundle_identifier not in _APPLE_SKIPPED
    ]
    edge = next(
        (
            (application, installed)
            for application, installed in eligible
            if application.bundle_identifier == "com.microsoft.edgemac"
        ),
        None,
    )
    ordered = []
    if edge is None or "normal" not in _application_capabilities(edge[0]):
        raise MatrixManifestError("eligible Edge Stable pilot is required")
    edge_application, edge_installed = edge
    ordered.extend(
        (edge_application, edge_installed, "normal", state) for state in _STATES
    )
    for application, installed in eligible:
        for capability in _application_capabilities(application):
            if application is edge_application and capability == "normal":
                continue
            ordered.extend(
                (application, installed, capability, state) for state in _STATES
            )
    return tuple(
        MatrixCell(
            index,
            application.bundle_identifier,
            capability,
            state,
            application,
            installed,
        )
        for index, (application, installed, capability, state) in enumerate(ordered)
    )


def _digest_json(value):
    encoded = json.dumps(
        value, allow_nan=False, ensure_ascii=True, separators=(",", ":"), sort_keys=True
    ).encode("ascii")
    return hashlib.sha256(encoded).hexdigest()


def _hmac_json(key, domain, value):
    encoded = json.dumps(
        value, allow_nan=False, ensure_ascii=True, separators=(",", ":"), sort_keys=True
    ).encode("ascii")
    return hmac.new(key, domain + encoded, hashlib.sha256).hexdigest()


def _plan_digest(cells):
    return _digest_json([cell.specification_hash for cell in cells])


def _chain_record(record, previous_hash):
    if record.get("recordType") == "cell" and not _valid_cell_evidence_semantics(
        record
    ):
        raise MatrixError("invalid fresh cell evidence semantics")
    chained = dict(record)
    chained["previousHash"] = previous_hash
    chained["recordHash"] = _digest_json(chained)
    return chained


def _valid_cell_evidence_semantics(record):
    if (
        not isinstance(record.get("browserStaticHash"), str)
        or _SAFE_HASH.fullmatch(record["browserStaticHash"]) is None
    ):
        return False
    timing_keys = set(record) & _CELL_TIMING_KEYS
    result = record.get("result")
    detail = record.get("detail")
    task_root_finalized = record.get("taskRootFinalized")
    finalization_source = record.get("taskFinalizationSource")
    finalization_proof = record.get("taskFinalizationProof")
    if (
        task_root_finalized is True
        and (
            not isinstance(finalization_proof, str)
            or _SAFE_HASH.fullmatch(finalization_proof) is None
        )
        or task_root_finalized is False
        and (finalization_source is not None or finalization_proof is not None)
    ):
        return False
    common_invoked = (
        record.get("e2eIdentity") is True
        and record.get("cleanupSuccess") is True
        and record.get("taskRootFinalized") is True
        and isinstance(record.get("sessionHash"), str)
        and _SAFE_HASH.fullmatch(record["sessionHash"]) is not None
        and timing_keys == _CELL_TIMING_KEYS
        and record.get("cleanupGraceSeconds") == 5.0
        and record.get("quiescenceSeconds") == 2.0
        and type(record.get("routeTimeoutSeconds")) in {int, float}
        and record["routeTimeoutSeconds"] > 0
    )
    if result == "PASS" and detail == "proven-route":
        return (
            common_invoked
            and record.get("driverOutcome") == "selected"
            and record.get("provenance") == "launch-observed"
            and record.get("receipt") is True
            and record.get("browserIdentity") is True
        )
    if result == "FAIL" and detail == "product-route-failure":
        return (
            common_invoked
            and record.get("driverOutcome") == "launch-error"
            and record.get("provenance") in {"none", "launch-error"}
            and record.get("receipt") is False
            and record.get("browserIdentity") is False
        )
    if result == "FAIL" and detail == "product-receipt-failure":
        return (
            common_invoked
            and record.get("driverOutcome") == "receipt-timeout"
            and record.get("provenance") == "launch-observed"
            and record.get("receipt") is False
            and record.get("browserIdentity") is True
        )
    if result == "UNSUPPORTED" and detail == "catalog-capability-refused":
        return (
            common_invoked
            and record.get("driverOutcome")
            in {"target-disabled", "target-missing", "target-mode-mismatch"}
            and record.get("provenance") == "none"
            and record.get("receipt") is False
            and record.get("browserIdentity") is False
        )
    if result == "NOT RUN" and detail in _NONINVOKED_DETAILS:
        return (
            record.get("driverOutcome") == "not-invoked"
            and record.get("provenance") == "none"
            and record.get("receipt") is False
            and record.get("e2eIdentity") is False
            and record.get("browserIdentity") is False
            and record.get("sessionHash") == "not-invoked"
            and record.get("cleanupSuccess") is False
            and type(task_root_finalized) is bool
            and (
                task_root_finalized is False
                and finalization_source is None
                or task_root_finalized is True
                and detail in _FINALIZED_NONINVOKED_DETAILS
                and finalization_source == _AUTHENTICATED_FINALIZATION_SOURCE
            )
            and not timing_keys
        )
    return False


def _valid_resume_finalization_sources(completed):
    for offset in range(0, len(completed), len(_STATES)):
        group = completed[offset : offset + len(_STATES)]
        sourced = [
            index
            for index, record in enumerate(group)
            if record.get("taskFinalizationSource")
            == _AUTHENTICATED_FINALIZATION_SOURCE
        ]
        if not sourced:
            continue
        if (
            len(group) != len(_STATES)
            or sourced != list(range(len(_STATES)))
            or not all(record.get("taskRootFinalized") is True for record in group)
        ):
            return False
        if all(record["result"] == "NOT RUN" for record in group):
            if len({record["detail"] for record in group}) != 1 or group[0][
                "detail"
            ] not in {
                "harness-ambiguity",
                "signature-blocker",
                "browser-identity-changed",
            }:
                return False
    return True


def _run_key_proof(key, key_identity, manifest_digest, plan_digest):
    return _hmac_json(
        key,
        _RUN_KEY_PROOF_DOMAIN,
        {
            "keyGeneration": list(key_identity),
            "manifestHash": manifest_digest,
            "planHash": plan_digest,
        },
    )


def _finalization_proof_context(header, group):
    return {
        "runHash": header["recordHash"],
        "manifestHash": header["manifestDigest"],
        "planHash": header["planDigest"],
        "cellIDs": [record["cellHash"] for record in group],
        "sequences": [record["sequence"] for record in group],
        "sessionHashes": [record["sessionHash"] for record in group],
        "browserStaticHashes": [record["browserStaticHash"] for record in group],
        "results": [record["result"] for record in group],
        "details": [record["detail"] for record in group],
        "finalization": [
            {
                "source": record.get("taskFinalizationSource", "none"),
                "value": record["taskRootFinalized"],
            }
            for record in group
        ],
    }


def _authenticate_finalized_group(header, key, group):
    if len(group) != len(_STATES):
        raise MatrixError("invalid finalization proof group")
    finalized = [record.get("taskRootFinalized") is True for record in group]
    sourced = [record.get("taskFinalizationSource") is not None for record in group]
    if not any(finalized) and not any(sourced):
        if any(record.get("taskFinalizationProof") is not None for record in group):
            raise MatrixError("unexpected finalization proof")
        return tuple(group)
    proof = _hmac_json(
        key,
        _FINALIZATION_PROOF_DOMAIN,
        _finalization_proof_context(header, group),
    )
    return tuple(
        dict(record, taskFinalizationProof=proof)
        if record.get("taskRootFinalized") is True
        or record.get("taskFinalizationSource") is not None
        else record
        for record in group
    )


def _verify_finalization_proofs(header, key, completed):
    for offset in range(0, len(completed), len(_STATES)):
        group = completed[offset : offset + len(_STATES)]
        claimed = any(
            record.get("taskRootFinalized") is True
            or record.get("taskFinalizationSource") is not None
            or record.get("taskFinalizationProof") is not None
            for record in group
        )
        if not claimed:
            continue
        if len(group) != len(_STATES):
            raise MatrixResumeError("invalid finalization proof group")
        expected = _hmac_json(
            key,
            _FINALIZATION_PROOF_DOMAIN,
            _finalization_proof_context(header, group),
        )
        if any(
            (
                not isinstance(record.get("taskFinalizationProof"), str)
                or not hmac.compare_digest(record["taskFinalizationProof"], expected)
            )
            if record.get("taskRootFinalized") is True
            or record.get("taskFinalizationSource") is not None
            else record.get("taskFinalizationProof") is not None
            for record in group
        ):
            raise MatrixResumeError("finalization proof mismatch")


class _PinnedOutputDirectory:
    def __init__(self, path, parent_descriptor, descriptor, parent_identity, identity):
        self.path = pathlib.Path(path)
        self.parent_descriptor = parent_descriptor
        self.descriptor = descriptor
        self.parent_identity = parent_identity
        self.identity = identity
        self.lock_descriptor = -1
        self.lock_identity = None
        self.finalization_key_descriptor = -1
        self.finalization_key_identity = None
        self.finalization_key = None
        self.evidence_identity = None
        self.evidence_digest = None
        self.evidence_head = None
        self.evidence_record_count = 0
        self.closed = False

    @classmethod
    def open(cls, output, *, create):
        output = pathlib.Path(output)
        if not output.is_absolute() or output.parent == output or not output.name:
            raise MatrixError("unsafe output directory")
        try:
            parent_components = (
                output.parent,
                *tuple(output.parent.parents)[:-1],
            )
            for component in reversed(parent_components):
                metadata = component.lstat()
                if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
                    raise MatrixError("unsafe output parent component")
            initial_parent = output.parent.lstat()
            parent_descriptor = os.open(
                output.parent,
                os.O_RDONLY
                | getattr(os, "O_DIRECTORY", 0)
                | getattr(os, "O_NOFOLLOW", 0)
                | os.O_CLOEXEC,
            )
            descriptor = -1
            try:
                parent_metadata = os.fstat(parent_descriptor)
                named_parent = output.parent.lstat()
                if _entry_generation(parent_metadata) != _entry_generation(
                    initial_parent
                ) or _entry_generation(named_parent) != _entry_generation(
                    initial_parent
                ):
                    raise MatrixError("output parent changed before creation")
                if create:
                    try:
                        os.mkdir(output.name, 0o700, dir_fd=parent_descriptor)
                    except FileExistsError:
                        pass
                descriptor = os.open(
                    output.name,
                    os.O_RDONLY
                    | getattr(os, "O_DIRECTORY", 0)
                    | getattr(os, "O_NOFOLLOW", 0)
                    | os.O_CLOEXEC,
                    dir_fd=parent_descriptor,
                )
                metadata = os.fstat(descriptor)
                named = os.stat(
                    output.name, dir_fd=parent_descriptor, follow_symlinks=False
                )
                identity = (metadata.st_dev, metadata.st_ino)
                if (
                    not stat.S_ISDIR(metadata.st_mode)
                    or stat.S_ISLNK(named.st_mode)
                    or metadata.st_uid != os.getuid()
                    or stat.S_IMODE(metadata.st_mode) != 0o700
                    or identity != (named.st_dev, named.st_ino)
                ):
                    raise MatrixError("unsafe output directory")
                pinned = cls(
                    output,
                    parent_descriptor,
                    descriptor,
                    _entry_generation(parent_metadata),
                    _entry_generation(metadata),
                )
                parent_descriptor = -1
                descriptor = -1
                try:
                    entries = set(os.listdir(pinned.descriptor))
                    if create and entries:
                        raise MatrixError("fresh output directory is not empty")
                    if not create and entries not in (
                        {_EVIDENCE_NAME, _FINALIZATION_KEY_NAME},
                        {_EVIDENCE_NAME, _FINALIZATION_KEY_NAME, ".run.lock"},
                    ):
                        raise MatrixResumeError(
                            "resume directory contains unexpected entries"
                        )
                    pinned._acquire_lock()
                    if create:
                        pinned._create_finalization_key()
                        expected_entries = {".run.lock", _FINALIZATION_KEY_NAME}
                    else:
                        pinned._open_finalization_key(MatrixResumeError)
                        expected_entries = {
                            _EVIDENCE_NAME,
                            ".run.lock",
                            _FINALIZATION_KEY_NAME,
                        }
                    if set(os.listdir(pinned.descriptor)) != expected_entries:
                        raise MatrixError("output directory changed while locking")
                    pinned.require_current()
                    return pinned
                except BaseException:
                    pinned.close()
                    raise
            finally:
                if descriptor >= 0:
                    os.close(descriptor)
                if parent_descriptor >= 0:
                    os.close(parent_descriptor)
        except MatrixError:
            raise
        except OSError as error:
            if create:
                raise MatrixError("unsafe output directory") from error
            raise MatrixResumeError("missing or unsafe output directory") from error

    def _acquire_lock(self):
        try:
            fcntl.flock(self.descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise MatrixError("output is already locked") from error
        descriptor = os.open(
            ".run.lock",
            os.O_RDWR | os.O_CREAT | os.O_CLOEXEC | getattr(os, "O_NOFOLLOW", 0),
            0o600,
            dir_fd=self.descriptor,
        )
        try:
            opened = os.fstat(descriptor)
            named = os.stat(".run.lock", dir_fd=self.descriptor, follow_symlinks=False)
            if (
                not stat.S_ISREG(opened.st_mode)
                or opened.st_uid != os.getuid()
                or stat.S_IMODE(opened.st_mode) != 0o600
                or opened.st_nlink != 1
                or browser_driver._EntryIdentity.from_stat(opened)
                != browser_driver._EntryIdentity.from_stat(named)
            ):
                raise MatrixError("unsafe output lock")
            self.lock_identity = _publication_identity(opened)
            self.lock_descriptor = descriptor
            descriptor = -1
        except BaseException:
            fcntl.flock(self.descriptor, fcntl.LOCK_UN)
            raise
        finally:
            if descriptor >= 0:
                os.close(descriptor)

    def _create_finalization_key(self):
        key = secrets.token_bytes(_FINALIZATION_KEY_BYTES)
        descriptor = os.open(
            _FINALIZATION_KEY_NAME,
            os.O_RDWR
            | os.O_CREAT
            | os.O_EXCL
            | os.O_CLOEXEC
            | getattr(os, "O_NOFOLLOW", 0),
            0o600,
            dir_fd=self.descriptor,
        )
        try:
            os.fchmod(descriptor, 0o600)
            offset = 0
            while offset < len(key):
                written = os.write(descriptor, key[offset:])
                if written <= 0:
                    raise MatrixError("finalization key write failed")
                offset += written
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        os.fsync(self.descriptor)
        self._open_finalization_key(MatrixError)
        if not hmac.compare_digest(self.finalization_key, key):
            raise MatrixError("finalization key changed during creation")

    def _open_finalization_key(self, error_type):
        descriptor = -1
        try:
            descriptor = os.open(
                _FINALIZATION_KEY_NAME,
                os.O_RDONLY | os.O_CLOEXEC | getattr(os, "O_NOFOLLOW", 0),
                dir_fd=self.descriptor,
            )
            before = os.fstat(descriptor)
            named = os.stat(
                _FINALIZATION_KEY_NAME,
                dir_fd=self.descriptor,
                follow_symlinks=False,
            )
            if (
                not stat.S_ISREG(before.st_mode)
                or stat.S_ISLNK(named.st_mode)
                or before.st_uid != os.getuid()
                or stat.S_IMODE(before.st_mode) != 0o600
                or before.st_nlink != 1
                or before.st_size != _FINALIZATION_KEY_BYTES
                or _publication_identity(before) != _publication_identity(named)
            ):
                raise error_type("unsafe finalization key")
            key = bytearray()
            while len(key) <= _FINALIZATION_KEY_BYTES:
                chunk = os.read(
                    descriptor,
                    _FINALIZATION_KEY_BYTES + 1 - len(key),
                )
                if not chunk:
                    break
                key.extend(chunk)
            after = os.fstat(descriptor)
            named_after = os.stat(
                _FINALIZATION_KEY_NAME,
                dir_fd=self.descriptor,
                follow_symlinks=False,
            )
            if (
                len(key) != _FINALIZATION_KEY_BYTES
                or _publication_identity(after) != _publication_identity(before)
                or _publication_identity(named_after) != _publication_identity(before)
            ):
                raise error_type("finalization key changed while reading")
            self.finalization_key_descriptor = descriptor
            self.finalization_key_identity = _publication_identity(before)
            self.finalization_key = bytes(key)
            descriptor = -1
        except error_type:
            raise
        except OSError as error:
            raise error_type("missing or unsafe finalization key") from error
        finally:
            if descriptor >= 0:
                os.close(descriptor)

    def pin_evidence(self, metadata, data, records):
        if not records or not isinstance(records[-1].get("recordHash"), str):
            raise MatrixError("invalid evidence head")
        self.evidence_identity = _publication_identity(metadata)
        self.evidence_digest = hashlib.sha256(data).hexdigest()
        self.evidence_head = records[-1]["recordHash"]
        self.evidence_record_count = len(records)

    def require_expected_evidence(self, records):
        self.require_current()
        if self.evidence_identity is None:
            try:
                os.stat(
                    _EVIDENCE_NAME,
                    dir_fd=self.descriptor,
                    follow_symlinks=False,
                )
            except FileNotFoundError:
                return
            raise MatrixError("unexpected evidence destination")
        if (
            len(records) < self.evidence_record_count
            or records[self.evidence_record_count - 1].get("recordHash")
            != self.evidence_head
        ):
            raise MatrixError("evidence chain head changed")
        descriptor = os.open(
            _EVIDENCE_NAME,
            os.O_RDONLY | os.O_CLOEXEC | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=self.descriptor,
        )
        try:
            opened = os.fstat(descriptor)
            if _publication_identity(opened) != self.evidence_identity:
                raise MatrixError("evidence destination changed")
            digest = hashlib.sha256()
            total = 0
            while total <= _MAXIMUM_EVIDENCE_BYTES:
                chunk = os.read(descriptor, 1024 * 1024)
                if not chunk:
                    break
                digest.update(chunk)
                total += len(chunk)
            named = os.stat(
                _EVIDENCE_NAME,
                dir_fd=self.descriptor,
                follow_symlinks=False,
            )
            if (
                total > _MAXIMUM_EVIDENCE_BYTES
                or digest.hexdigest() != self.evidence_digest
                or _publication_identity(os.fstat(descriptor)) != self.evidence_identity
                or _publication_identity(named) != self.evidence_identity
            ):
                raise MatrixError("evidence destination changed")
        finally:
            os.close(descriptor)

    def require_prior_at(self, name):
        descriptor = os.open(
            name,
            os.O_RDONLY | os.O_CLOEXEC | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=self.descriptor,
        )
        try:
            opened = os.fstat(descriptor)
            if _rename_identity(opened) != _rename_identity_from_full(
                self.evidence_identity
            ):
                raise MatrixError("prior evidence changed at publication")
            digest = hashlib.sha256()
            total = 0
            while total <= _MAXIMUM_EVIDENCE_BYTES:
                chunk = os.read(descriptor, 1024 * 1024)
                if not chunk:
                    break
                digest.update(chunk)
                total += len(chunk)
            named = os.stat(name, dir_fd=self.descriptor, follow_symlinks=False)
            if (
                total > _MAXIMUM_EVIDENCE_BYTES
                or digest.hexdigest() != self.evidence_digest
                or _rename_identity(os.fstat(descriptor))
                != _rename_identity_from_full(self.evidence_identity)
                or _rename_identity(named)
                != _rename_identity_from_full(self.evidence_identity)
            ):
                raise MatrixError("prior evidence changed at publication")
        finally:
            os.close(descriptor)

    def require_current(self):
        if self.closed:
            raise MatrixError("output directory pin is closed")
        try:
            metadata = os.fstat(self.descriptor)
            parent = os.fstat(self.parent_descriptor)
            named_parent = self.path.parent.lstat()
            named = os.stat(
                self.path.name,
                dir_fd=self.parent_descriptor,
                follow_symlinks=False,
            )
            lock_named = os.stat(
                ".run.lock", dir_fd=self.descriptor, follow_symlinks=False
            )
            key_named = os.stat(
                _FINALIZATION_KEY_NAME,
                dir_fd=self.descriptor,
                follow_symlinks=False,
            )
        except OSError as error:
            raise MatrixError("output directory identity changed") from error
        if (
            _entry_generation(metadata) != self.identity
            or _entry_generation(named) != self.identity
            or _entry_generation(parent) != self.parent_identity
            or _entry_generation(named_parent) != self.parent_identity
            or stat.S_ISLNK(named_parent.st_mode)
            or not stat.S_ISDIR(metadata.st_mode)
            or stat.S_ISLNK(named.st_mode)
            or metadata.st_uid != os.getuid()
            or stat.S_IMODE(metadata.st_mode) != 0o700
            or self.lock_descriptor < 0
            or _publication_identity(os.fstat(self.lock_descriptor))
            != self.lock_identity
            or _publication_identity(lock_named) != self.lock_identity
            or self.finalization_key_descriptor < 0
            or _publication_identity(os.fstat(self.finalization_key_descriptor))
            != self.finalization_key_identity
            or _publication_identity(key_named) != self.finalization_key_identity
        ):
            raise MatrixError("output directory identity changed")

    def close(self):
        if self.closed:
            return
        self.closed = True
        if self.finalization_key_descriptor >= 0:
            os.close(self.finalization_key_descriptor)
            self.finalization_key_descriptor = -1
        if self.lock_descriptor >= 0:
            os.close(self.lock_descriptor)
            self.lock_descriptor = -1
        fcntl.flock(self.descriptor, fcntl.LOCK_UN)
        os.close(self.descriptor)
        os.close(self.parent_descriptor)

    def __del__(self):
        try:
            self.close()
        except OSError:
            pass


def _publication_identity(metadata):
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_uid,
        metadata.st_mode,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
        metadata.st_nlink,
    )


def _rename_identity(metadata):
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_uid,
        metadata.st_mode,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_nlink,
    )


def _rename_identity_from_full(identity):
    return (*identity[:6], identity[7])


def _rename_at(descriptor, source, destination, flag):
    library = ctypes.CDLL(None, use_errno=True)
    library.renameatx_np.argtypes = [
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_uint,
    ]
    library.renameatx_np.restype = ctypes.c_int
    ctypes.set_errno(0)
    if (
        library.renameatx_np(
            descriptor,
            os.fsencode(source),
            descriptor,
            os.fsencode(destination),
            flag,
        )
        != 0
    ):
        error_number = ctypes.get_errno()
        raise OSError(error_number, os.strerror(error_number), destination)


def _rename_at_exclusive(descriptor, source, destination):
    _rename_at(descriptor, source, destination, 0x00000004)


def _rename_at_swap(descriptor, source, destination):
    _rename_at(descriptor, source, destination, 0x00000002)


def _require_publication_candidate(output, name, expected_identity, data):
    descriptor = os.open(
        name,
        os.O_RDONLY | os.O_CLOEXEC | getattr(os, "O_NOFOLLOW", 0),
        dir_fd=output.descriptor,
    )
    try:
        opened = os.fstat(descriptor)
        if _rename_identity(opened) != expected_identity:
            raise MatrixError("published evidence identity changed")
        stable_identity = _publication_identity(opened)
        contents = bytearray()
        while len(contents) <= len(data):
            chunk = os.read(
                descriptor,
                min(65_536, len(data) + 1 - len(contents)),
            )
            if not chunk:
                break
            contents.extend(chunk)
        after = os.fstat(descriptor)
        named = os.stat(name, dir_fd=output.descriptor, follow_symlinks=False)
        if (
            bytes(contents) != data
            or _publication_identity(after) != stable_identity
            or _publication_identity(named) != stable_identity
        ):
            raise MatrixError("published evidence changed")
        return after
    finally:
        os.close(descriptor)


def _write_records(output, records):
    output.require_expected_evidence(records)
    data = b"".join(
        (
            json.dumps(record, allow_nan=False, separators=(",", ":"), sort_keys=True)
            + "\n"
        ).encode("ascii")
        for record in records
    )
    if len(data) > _MAXIMUM_EVIDENCE_BYTES:
        raise MatrixError("evidence limit exceeded")
    temporary = f".{_EVIDENCE_NAME}.{secrets.token_hex(8)}"
    staging_identity = None
    cleanup_identity = None
    cleanup_unswapped_staging = True
    descriptor = os.open(
        temporary,
        os.O_WRONLY
        | os.O_CREAT
        | os.O_EXCL
        | os.O_CLOEXEC
        | getattr(os, "O_NOFOLLOW", 0),
        0o600,
        dir_fd=output.descriptor,
    )
    try:
        offset = 0
        while offset < len(data):
            written = os.write(descriptor, data[offset:])
            if written <= 0:
                raise MatrixError("evidence write failed")
            offset += written
        opened = os.fstat(descriptor)
        named = os.stat(temporary, dir_fd=output.descriptor, follow_symlinks=False)
        if (
            not stat.S_ISREG(opened.st_mode)
            or opened.st_uid != os.getuid()
            or stat.S_IMODE(opened.st_mode) != 0o600
            or opened.st_nlink != 1
            or _entry_generation(opened) != _entry_generation(named)
        ):
            raise MatrixError("evidence staging identity changed")
        staging_identity = _publication_identity(opened)
        staging_rename_identity = _rename_identity(opened)
        os.fsync(descriptor)
        os.close(descriptor)
        descriptor = -1
        output.require_current()
        named = os.stat(temporary, dir_fd=output.descriptor, follow_symlinks=False)
        if _publication_identity(named) != staging_identity:
            raise MatrixError("evidence staging identity changed")
        output.require_expected_evidence(records)
        if output.evidence_identity is None:
            cleanup_unswapped_staging = False
            _rename_at_exclusive(output.descriptor, temporary, _EVIDENCE_NAME)
            published_metadata = _require_publication_candidate(
                output, _EVIDENCE_NAME, staging_rename_identity, data
            )
            os.fsync(output.descriptor)
            output.require_current()
            published_metadata = _require_publication_candidate(
                output, _EVIDENCE_NAME, staging_rename_identity, data
            )
            output.pin_evidence(published_metadata, data, records)
        else:
            cleanup_unswapped_staging = False
            swap_completed = False
            prior_is_exact = False
            candidate_is_exact = False
            try:
                _rename_at_swap(output.descriptor, temporary, _EVIDENCE_NAME)
                swap_completed = True
                published_metadata = _require_publication_candidate(
                    output, _EVIDENCE_NAME, staging_rename_identity, data
                )
                candidate_is_exact = True
                output.require_prior_at(temporary)
                prior_is_exact = True
                os.fsync(output.descriptor)
                output.require_current()
                output.require_prior_at(temporary)
                published_metadata = _require_publication_candidate(
                    output, _EVIDENCE_NAME, staging_rename_identity, data
                )
            except BaseException as publication_error:
                if swap_completed:
                    if not prior_is_exact:
                        try:
                            output.require_prior_at(temporary)
                            prior_is_exact = True
                        except BaseException:
                            pass
                    if not candidate_is_exact:
                        try:
                            _require_publication_candidate(
                                output,
                                _EVIDENCE_NAME,
                                staging_rename_identity,
                                data,
                            )
                            candidate_is_exact = True
                        except BaseException:
                            pass
                if prior_is_exact or candidate_is_exact:
                    try:
                        if prior_is_exact:
                            output.require_prior_at(temporary)
                        if candidate_is_exact:
                            _require_publication_candidate(
                                output,
                                _EVIDENCE_NAME,
                                staging_rename_identity,
                                data,
                            )
                        _rename_at_swap(output.descriptor, temporary, _EVIDENCE_NAME)
                        if prior_is_exact:
                            output.require_prior_at(_EVIDENCE_NAME)
                        if candidate_is_exact:
                            _require_publication_candidate(
                                output,
                                temporary,
                                staging_rename_identity,
                                data,
                            )
                        os.fsync(output.descriptor)
                    except BaseException as rollback_error:
                        retained = (
                            "prior retained"
                            if prior_is_exact
                            else "swapped entries retained"
                        )
                        raise MatrixError(
                            f"evidence rollback failed; {retained}"
                        ) from rollback_error
                raise publication_error
            output.require_prior_at(temporary)
            published_metadata = _require_publication_candidate(
                output, _EVIDENCE_NAME, staging_rename_identity, data
            )
            output.pin_evidence(published_metadata, data, records)
            try:
                os.unlink(temporary, dir_fd=output.descriptor)
            except OSError as error:
                raise MatrixError(
                    "prior evidence cleanup failed; prior retained"
                ) from error
    except BaseException:
        if descriptor >= 0:
            try:
                cleanup_identity = _publication_identity(os.fstat(descriptor))
            except OSError:
                cleanup_identity = None
            os.close(descriptor)
            descriptor = -1
        if cleanup_unswapped_staging:
            try:
                named = os.stat(
                    temporary,
                    dir_fd=output.descriptor,
                    follow_symlinks=False,
                )
                expected_cleanup_identity = staging_identity or cleanup_identity
                if (
                    expected_cleanup_identity is not None
                    and _publication_identity(named) == expected_cleanup_identity
                ):
                    os.unlink(temporary, dir_fd=output.descriptor)
            except (FileNotFoundError, OSError):
                pass
        raise
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def _read_resume(output, manifest, cells):
    try:
        output.require_current()
        descriptor = os.open(
            _EVIDENCE_NAME,
            os.O_RDONLY | os.O_CLOEXEC | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=output.descriptor,
        )
        try:
            before = os.fstat(descriptor)
            named = os.stat(
                _EVIDENCE_NAME, dir_fd=output.descriptor, follow_symlinks=False
            )
            if (
                not stat.S_ISREG(before.st_mode)
                or before.st_uid != os.getuid()
                or stat.S_IMODE(before.st_mode) != 0o600
                or before.st_nlink != 1
                or (before.st_dev, before.st_ino) != (named.st_dev, named.st_ino)
            ):
                raise MatrixResumeError("resume evidence identity is invalid")
            chunks = bytearray()
            while True:
                chunk = os.read(descriptor, 1024 * 1024)
                if not chunk:
                    break
                chunks.extend(chunk)
                if len(chunks) > _MAXIMUM_EVIDENCE_BYTES:
                    raise MatrixResumeError("invalid evidence framing")
            after = os.fstat(descriptor)
            if (
                before.st_dev,
                before.st_ino,
                before.st_size,
                before.st_mtime_ns,
                before.st_ctime_ns,
            ) != (
                after.st_dev,
                after.st_ino,
                after.st_size,
                after.st_mtime_ns,
                after.st_ctime_ns,
            ):
                raise MatrixResumeError("resume evidence changed while reading")
            named_after = os.stat(
                _EVIDENCE_NAME,
                dir_fd=output.descriptor,
                follow_symlinks=False,
            )
            if browser_driver._EntryIdentity.from_stat(
                named_after
            ) != browser_driver._EntryIdentity.from_stat(before):
                raise MatrixResumeError("resume evidence name changed while reading")
            data = bytes(chunks)
        finally:
            os.close(descriptor)
        output.require_current()
        if not data or len(data) > _MAXIMUM_EVIDENCE_BYTES or not data.endswith(b"\n"):
            raise MatrixResumeError("invalid evidence framing")
        lines = data.splitlines(keepends=True)
        records = []
        for line in lines:
            # Decode each line with the same duplicate/nonfinite policy without creating a file.
            decoder = json.JSONDecoder(
                object_pairs_hook=_unique_object, parse_constant=_reject_constant
            )
            text = line.decode("utf-8")
            value, end = decoder.raw_decode(text)
            if text[end:] != "\n" or not isinstance(value, dict):
                raise MatrixResumeError("invalid evidence record")
            records.append(value)
    except MatrixResumeError:
        raise
    except (
        OSError,
        UnicodeDecodeError,
        json.JSONDecodeError,
        MatrixManifestError,
    ) as error:
        raise MatrixResumeError("invalid evidence") from error
    if not records:
        raise MatrixResumeError("empty evidence")
    header = records[0]
    expected_header_fields = {
        "recordType",
        "schemaVersion",
        "manifestDigest",
        "planDigest",
        "finalizationKeyProof",
        "previousHash",
        "recordHash",
    }
    if (
        set(header) != expected_header_fields
        or header["recordType"] != "run"
        or header["schemaVersion"] != 1
        or header["manifestDigest"] != manifest.digest
        or header["planDigest"] != _plan_digest(cells)
        or not isinstance(header["finalizationKeyProof"], str)
        or _SAFE_HASH.fullmatch(header["finalizationKeyProof"]) is None
        or not hmac.compare_digest(
            header["finalizationKeyProof"],
            _run_key_proof(
                output.finalization_key,
                output.finalization_key_identity,
                header["manifestDigest"],
                header["planDigest"],
            ),
        )
    ):
        raise MatrixResumeError("run manifest mismatch")
    previous_hash = "0" * 64
    completed = []
    seen_session_hashes = set()
    for index, record in enumerate(records):
        observed_hash = record.get("recordHash")
        unhashed = dict(record)
        unhashed.pop("recordHash", None)
        if record.get("previousHash") != previous_hash or observed_hash != _digest_json(
            unhashed
        ):
            raise MatrixResumeError("evidence hash mismatch")
        previous_hash = observed_hash
        if index == 0:
            continue
        cell_index = index - 1
        if cell_index >= len(cells):
            raise MatrixResumeError("extra completed cell")
        cell = cells[cell_index]
        keys = set(record)
        optional_keys = keys & _CELL_OPTIONAL_KEYS
        timing_keys = keys - _CELL_REQUIRED_KEYS - optional_keys
        timings_are_valid = timing_keys.issubset(_CELL_TIMING_KEYS) and all(
            type(record[key]) in {int, float}
            and math.isfinite(record[key])
            and record[key] >= 0
            for key in timing_keys
        )
        if (
            not _CELL_REQUIRED_KEYS.issubset(keys)
            or not timings_are_valid
            or record.get("recordType") != "cell"
            or record.get("schemaVersion") != 1
            or record.get("sequence") != cell.sequence
            or record.get("cellHash") != cell.specification_hash
            or record.get("bundleIdentifier") != cell.bundle_identifier
            or record.get("capability") != cell.capability
            or record.get("state") != cell.state
            or record.get("result") not in _RESULTS
            or record.get("detail") not in _SAFE_DETAILS
            or record.get("driverOutcome") not in _SAFE_DRIVER_OUTCOMES
            or record.get("provenance") not in _SAFE_PROVENANCE
            or _SAFE_VERSION.fullmatch(record.get("installedVersion", "")) is None
            or any(
                type(record.get(key)) is not bool
                for key in ("receipt", "e2eIdentity", "browserIdentity")
            )
            or record.get("sessionHash") != "not-invoked"
            and _SAFE_HASH.fullmatch(record.get("sessionHash", "")) is None
            or not _valid_cell_evidence_semantics(record)
        ):
            raise MatrixResumeError("completed cell mismatch")
        session_hash = record["sessionHash"]
        if session_hash != "not-invoked":
            if session_hash in seen_session_hashes:
                raise MatrixResumeError("reused session hash")
            seen_session_hashes.add(session_hash)
        completed.append(record)
    if not _valid_resume_finalization_sources(completed):
        raise MatrixResumeError("completed finalization source mismatch")
    _verify_finalization_proofs(header, output.finalization_key, completed)
    try:
        output.require_current()
    except MatrixError as error:
        raise MatrixResumeError(
            "finalization key changed after verification"
        ) from error
    output.pin_evidence(before, data, records)
    return records, completed


def _expected_target_id(cell):
    if not cell.has_profile:
        return f"{cell.bundle_identifier}||{cell.mode}"
    if cell.profile_strategy == "chromium":
        return f"{cell.bundle_identifier}|PickVia E2E|{cell.mode}"
    if cell.profile_strategy == "firefox":
        return "firefox-derived"
    raise DriverProofError("unsupported profile target")


def _sequence_handoff_context(
    cell,
    target_id,
    sessions,
    profile_relative_root,
    e2e_app_identity,
    browser_app_identity,
):
    return browser_driver._cleanup_handoff_context(
        bundle_identifier=cell.bundle_identifier,
        target_id=target_id,
        capability=cell.capability,
        browser_app_identity=browser_app_identity,
        e2e_app_identity=e2e_app_identity,
        browser_executable=cell.application.executable_path,
        browser_application=cell.application.application_path,
        profile_strategy=(
            cell.profile_strategy if profile_relative_root is not None else None
        ),
        profile_relative_root=profile_relative_root,
        create_profile=profile_relative_root is not None,
        sessions=sessions,
    )


def _sanitized_record(cell, version, browser_app_identity, report, result, detail):
    timings = {}
    for source, target in (
        ("total_elapsed_seconds", "totalElapsedSeconds"),
        ("route_timeout_seconds", "routeTimeoutSeconds"),
        ("browser_cleanup_grace_seconds", "cleanupGraceSeconds"),
        ("browser_quiescence_seconds", "quiescenceSeconds"),
    ):
        value = report.get(source)
        if type(value) in {int, float} and math.isfinite(value) and value >= 0:
            timings[target] = value
    safe_version = (
        version
        if isinstance(version, str) and _SAFE_VERSION.fullmatch(version)
        else "unavailable"
    )
    outcome = report.get("outcome")
    safe_outcome = (
        outcome if outcome in _SAFE_DRIVER_OUTCOMES else "invalid-driver-report"
    )
    provenance = report.get("launch_provenance", "none")
    safe_provenance = provenance if provenance in _SAFE_PROVENANCE else "invalid"
    session_hash = report.get("session_hash", "not-invoked")
    safe_session_hash = (
        session_hash
        if isinstance(session_hash, str) and _SAFE_HASH.fullmatch(session_hash)
        else "not-invoked"
    )
    record = {
        "recordType": "cell",
        "schemaVersion": 1,
        "sequence": cell.sequence,
        "cellHash": cell.specification_hash,
        "bundleIdentifier": cell.bundle_identifier,
        "capability": cell.capability,
        "state": cell.state,
        "installedVersion": safe_version,
        "browserStaticHash": (
            browser_app_identity
            if isinstance(browser_app_identity, str)
            and _SAFE_HASH.fullmatch(browser_app_identity)
            else "0" * 64
        ),
        "result": result,
        "detail": detail,
        "driverOutcome": safe_outcome,
        "provenance": safe_provenance,
        "receipt": report.get("token_received") is True,
        "e2eIdentity": report.get("exact_process_identity") is True,
        "browserIdentity": report.get("exact_browser_process_identity") is True,
        "sessionHash": safe_session_hash,
        "cleanupSuccess": report.get("cleanup_success") is True,
        "taskRootFinalized": report.get("task_root_finalized") is True,
        **timings,
    }
    if report.get("task_finalization_source") == _AUTHENTICATED_FINALIZATION_SOURCE:
        record["taskFinalizationSource"] = _AUTHENTICATED_FINALIZATION_SOURCE
    return record


def _not_run_record(
    cell,
    version,
    detail,
    browser_app_identity="0" * 64,
    *,
    authenticated_task_root_finalized=False,
):
    return _sanitized_record(
        cell,
        version,
        browser_app_identity,
        {
            "outcome": "not-invoked",
            "task_root_finalized": authenticated_task_root_finalized,
            "task_finalization_source": (
                _AUTHENTICATED_FINALIZATION_SOURCE
                if authenticated_task_root_finalized
                else "none"
            ),
        },
        "NOT RUN",
        detail,
    )


def _append_finalized_group(header, key, chained_records, completed, records):
    for record in _authenticate_finalized_group(header, key, records):
        chained_records.append(_chain_record(record, chained_records[-1]["recordHash"]))
        completed.append(chained_records[-1])


def _aggregate_completed_exit(completed):
    if any(record["result"] == "FAIL" for record in completed):
        return MATRIX_PRODUCT_FAILURE
    if any(
        record["result"] == "UNSUPPORTED"
        or record["result"] == "NOT RUN"
        and record["detail"] in {"installed-absence", "signature-blocker"}
        for record in completed
    ):
        return MATRIX_BLOCKED
    return MATRIX_SUCCESS


def _resume_terminal(completed):
    if not completed:
        return None
    aggregate = _aggregate_completed_exit(completed)
    if len(completed) < 3:
        return (
            MATRIX_PRODUCT_FAILURE
            if aggregate == MATRIX_PRODUCT_FAILURE
            else MATRIX_BLOCKED,
            "edge-pilot-failed",
        )
    edge_pilot = completed[:3]
    if any(record["result"] != "PASS" for record in edge_pilot):
        return (
            MATRIX_PRODUCT_FAILURE
            if aggregate == MATRIX_PRODUCT_FAILURE
            else MATRIX_BLOCKED,
            "edge-pilot-failed",
        )
    if len(completed) % 3:
        return (
            MATRIX_PRODUCT_FAILURE
            if aggregate == MATRIX_PRODUCT_FAILURE
            else MATRIX_BLOCKED,
            "blocked-after-ambiguity",
        )
    for offset in range(3, len(completed), 3):
        group = completed[offset : offset + 3]
        results = [record["result"] for record in group]
        if results == ["PASS", "PASS", "PASS"]:
            continue
        decisive = next(
            (
                index
                for index, result in enumerate(results)
                if result in {"FAIL", "UNSUPPORTED"}
            ),
            None,
        )
        if decisive is not None:
            expected_detail = (
                "blocked-after-sequence-failure"
                if results[decisive] == "FAIL"
                else "blocked-after-sequence-refusal"
            )
            if (
                all(result == "PASS" for result in results[:decisive])
                and all(result == "NOT RUN" for result in results[decisive + 1 :])
                and all(
                    record["detail"] == expected_detail
                    for record in group[decisive + 1 :]
                )
            ):
                continue
        if all(
            record["result"] == "NOT RUN"
            and record["detail"] in {"installed-absence", "signature-blocker"}
            for record in group
        ):
            continue
        return (
            MATRIX_PRODUCT_FAILURE
            if aggregate == MATRIX_PRODUCT_FAILURE
            else MATRIX_BLOCKED,
            "blocked-after-ambiguity",
        )
    return None


def execute_matrix(manifest, output, *, dependencies=None, resume=False):
    dependencies = dependencies or SystemDependencies()
    pinned_output = _PinnedOutputDirectory.open(output, create=not resume)
    try:
        return _execute_matrix_with_output(
            manifest, pinned_output, dependencies=dependencies, resume=resume
        )
    finally:
        pinned_output.close()


def _execute_matrix_with_output(manifest, output, *, dependencies, resume):
    cells = plan_cells(manifest, dependencies.is_installed)
    if not cells:
        raise MatrixError("no installed eligible cells")
    evidence_path = output
    prior_exit_code = MATRIX_SUCCESS
    if resume:
        chained_records, completed = _read_resume(evidence_path, manifest, cells)
        prior_exit_code = _aggregate_completed_exit(completed)
        terminal = _resume_terminal(completed)
        if terminal is not None:
            exit_code, detail = terminal
            persisted_versions = {
                record["bundleIdentifier"]: record["installedVersion"]
                for record in completed
            }
            for cell in cells[len(completed) :]:
                record = _not_run_record(
                    cell,
                    persisted_versions.get(cell.bundle_identifier, "unverified"),
                    detail,
                )
                chained_records.append(
                    _chain_record(record, chained_records[-1]["recordHash"])
                )
                completed.append(chained_records[-1])
            _write_records(evidence_path, chained_records)
            return MatrixExecutionResult(exit_code, tuple(completed))
        if len(completed) == len(cells):
            return MatrixExecutionResult(prior_exit_code, tuple(completed))
    else:
        plan_digest = _plan_digest(cells)
        header = _chain_record(
            {
                "recordType": "run",
                "schemaVersion": 1,
                "manifestDigest": manifest.digest,
                "planDigest": plan_digest,
                "finalizationKeyProof": _run_key_proof(
                    output.finalization_key,
                    output.finalization_key_identity,
                    manifest.digest,
                    plan_digest,
                ),
            },
            "0" * 64,
        )
        chained_records = [header]
        completed = []
        _write_records(evidence_path, chained_records)

    versions = {}
    application_identities = {}
    application_verifications = {}
    absent_bundles = set()
    identity_blocked_bundles = set()
    for cell in cells:
        if cell.bundle_identifier in versions:
            continue
        if not cell.installed:
            versions[cell.bundle_identifier] = "unavailable"
            application_identities[cell.bundle_identifier] = "0" * 64
            absent_bundles.add(cell.bundle_identifier)
            continue
        try:
            verification = dependencies.verify_application(cell.application)
            application_verifications[cell.bundle_identifier] = verification
            versions[cell.bundle_identifier] = verification.version
            application_identities[cell.bundle_identifier] = verification.identity
        except MatrixIdentityError:
            versions[cell.bundle_identifier] = "unavailable"
            application_identities[cell.bundle_identifier] = "0" * 64
            identity_blocked_bundles.add(cell.bundle_identifier)
    if resume and any(
        record["result"] != "NOT RUN"
        and (
            record["installedVersion"]
            != versions.get(record["bundleIdentifier"], "unavailable")
            or record["browserStaticHash"]
            != application_identities.get(record["bundleIdentifier"], "0" * 64)
        )
        for record in completed
    ):
        for pending in cells[len(completed) :]:
            pending_record = _not_run_record(
                pending,
                versions.get(pending.bundle_identifier, "unavailable"),
                "browser-identity-changed",
                application_identities.get(pending.bundle_identifier, "0" * 64),
            )
            chained_records.append(
                _chain_record(pending_record, chained_records[-1]["recordHash"])
            )
            completed.append(chained_records[-1])
        _write_records(evidence_path, chained_records)
        return MatrixExecutionResult(
            MATRIX_PRODUCT_FAILURE
            if prior_exit_code == MATRIX_PRODUCT_FAILURE
            else MATRIX_BLOCKED,
            tuple(completed),
        )
    blocked_bundles = absent_bundles | identity_blocked_bundles
    if "com.microsoft.edgemac" in blocked_bundles:
        for cell in cells[len(completed) :]:
            detail = (
                "installed-absence"
                if cell.bundle_identifier in absent_bundles
                else "signature-blocker"
                if cell.bundle_identifier == "com.microsoft.edgemac"
                else "blocked-before-run"
            )
            record = _not_run_record(
                cell, versions.get(cell.bundle_identifier, "unverified"), detail
            )
            chained_records.append(
                _chain_record(record, chained_records[-1]["recordHash"])
            )
            completed.append(chained_records[-1])
        _write_records(evidence_path, chained_records)
        return MatrixExecutionResult(MATRIX_BLOCKED, tuple(completed))

    if completed:
        remaining = cells[len(completed) :]
    else:
        remaining = cells
    if not remaining:
        return MatrixExecutionResult(prior_exit_code, tuple(completed))
    try:
        pinned_app = dependencies.build_and_pin()
    except Exception:
        for cell in remaining:
            record = _not_run_record(
                cell,
                versions.get(cell.bundle_identifier, "unverified"),
                "build-blocker",
            )
            chained_records.append(
                _chain_record(record, chained_records[-1]["recordHash"])
            )
            completed.append(chained_records[-1])
        _write_records(evidence_path, chained_records)
        return MatrixExecutionResult(
            MATRIX_PRODUCT_FAILURE
            if prior_exit_code == MATRIX_PRODUCT_FAILURE
            else MATRIX_BLOCKED,
            tuple(completed),
        )
    try:
        e2e_app_identity = dependencies.e2e_identity(pinned_app)
    except Exception:
        close = getattr(pinned_app, "close", None)
        if callable(close):
            close()
        for cell in remaining:
            record = _not_run_record(
                cell,
                versions.get(cell.bundle_identifier, "unverified"),
                "build-blocker",
            )
            chained_records.append(
                _chain_record(record, chained_records[-1]["recordHash"])
            )
            completed.append(chained_records[-1])
        _write_records(evidence_path, chained_records)
        return MatrixExecutionResult(
            MATRIX_PRODUCT_FAILURE
            if prior_exit_code == MATRIX_PRODUCT_FAILURE
            else MATRIX_BLOCKED,
            tuple(completed),
        )
    exit_code = (
        MATRIX_PRODUCT_FAILURE
        if prior_exit_code == MATRIX_PRODUCT_FAILURE
        else MATRIX_BLOCKED
        if prior_exit_code == MATRIX_BLOCKED or blocked_bundles
        else MATRIX_SUCCESS
    )
    try:
        offset = 0
        while offset < len(remaining):
            group = remaining[offset : offset + 3]
            if (
                len(group) != 3
                or [cell.state for cell in group] != list(_STATES)
                or len({(cell.bundle_identifier, cell.capability) for cell in group})
                != 1
            ):
                raise MatrixError("invalid state sequence plan")
            cell = group[0]
            if cell.bundle_identifier in blocked_bundles:
                for blocked_cell in group:
                    record = _not_run_record(
                        blocked_cell,
                        versions[blocked_cell.bundle_identifier],
                        "installed-absence"
                        if blocked_cell.bundle_identifier in absent_bundles
                        else "signature-blocker",
                    )
                    chained_records.append(
                        _chain_record(record, chained_records[-1]["recordHash"])
                    )
                    completed.append(chained_records[-1])
                _write_records(evidence_path, chained_records)
                offset += 3
                continue
            try:
                current_verification = dependencies.verify_application(cell.application)
            except MatrixIdentityError:
                current_verification = None
            if current_verification is None:
                versions[cell.bundle_identifier] = "unavailable"
                blocked_bundles.add(cell.bundle_identifier)
                for blocked_cell in group:
                    record = _not_run_record(
                        blocked_cell,
                        "unavailable",
                        "signature-blocker",
                    )
                    chained_records.append(
                        _chain_record(record, chained_records[-1]["recordHash"])
                    )
                    completed.append(chained_records[-1])
                _write_records(evidence_path, chained_records)
                if cell.sequence == 0:
                    for pending in remaining[offset + 3 :]:
                        record = _not_run_record(
                            pending,
                            versions.get(pending.bundle_identifier, "unverified"),
                            "blocked-before-run",
                        )
                        chained_records.append(
                            _chain_record(record, chained_records[-1]["recordHash"])
                        )
                        completed.append(chained_records[-1])
                    _write_records(evidence_path, chained_records)
                    if exit_code != MATRIX_PRODUCT_FAILURE:
                        exit_code = MATRIX_BLOCKED
                    break
                offset += 3
                continue
            if (
                current_verification
                != application_verifications[cell.bundle_identifier]
            ):
                versions[cell.bundle_identifier] = "unavailable"
                for pending in remaining[offset:]:
                    record = _not_run_record(
                        pending,
                        "unavailable"
                        if pending.bundle_identifier == cell.bundle_identifier
                        else versions.get(pending.bundle_identifier, "unverified"),
                        "browser-identity-changed",
                    )
                    chained_records.append(
                        _chain_record(record, chained_records[-1]["recordHash"])
                    )
                    completed.append(chained_records[-1])
                _write_records(evidence_path, chained_records)
                if exit_code != MATRIX_PRODUCT_FAILURE:
                    exit_code = MATRIX_BLOCKED
                break
            sessions = tuple(secrets.token_hex(24) for _ in _STATES)
            requests = tuple(secrets.token_hex(24) for _ in _STATES)
            profile_relative_root = (
                f"profiles/{cell.specification_hash[:24]}" if cell.has_profile else None
            )
            independently_finalized_task_root = False
            has_independent_task_finalization = False
            try:
                driver_execution = dependencies.run_sequence(
                    pinned_app,
                    group,
                    sessions,
                    requests,
                    profile_relative_root,
                    e2e_app_identity,
                    application_identities[cell.bundle_identifier],
                )
                if not isinstance(driver_execution, tuple) or len(
                    driver_execution
                ) not in {2, 3}:
                    raise ValueError("invalid driver execution result")
                report, driver_code = driver_execution[:2]
                if len(driver_execution) == 3:
                    has_independent_task_finalization = True
                    independently_finalized_task_root = driver_execution[2]
                    if type(independently_finalized_task_root) is not bool:
                        raise ValueError("invalid task finalization result")
            except Exception:
                report = {"outcome": "invalid-driver-report"}
                driver_code = browser_driver.DRIVER_PROCESS_ERROR
                independently_finalized_task_root = False
                has_independent_task_finalization = False
            try:
                post_verification = dependencies.verify_application(cell.application)
            except MatrixIdentityError:
                post_verification = None
            if post_verification is None:
                versions[cell.bundle_identifier] = "unavailable"
                finalized_group = [
                    _not_run_record(
                        blocked_cell,
                        "unavailable",
                        "signature-blocker",
                        authenticated_task_root_finalized=(
                            independently_finalized_task_root
                        ),
                    )
                    for blocked_cell in group
                ]
                _append_finalized_group(
                    chained_records[0],
                    output.finalization_key,
                    chained_records,
                    completed,
                    finalized_group,
                )
                for pending in remaining[offset + 3 :]:
                    record = _not_run_record(
                        pending,
                        versions.get(pending.bundle_identifier, "unverified"),
                        "blocked-after-ambiguity",
                    )
                    chained_records.append(
                        _chain_record(record, chained_records[-1]["recordHash"])
                    )
                    completed.append(chained_records[-1])
                _write_records(evidence_path, chained_records)
                if exit_code != MATRIX_PRODUCT_FAILURE:
                    exit_code = MATRIX_BLOCKED
                break
            if post_verification != application_verifications[cell.bundle_identifier]:
                versions[cell.bundle_identifier] = "unavailable"
                finalized_group = [
                    _not_run_record(
                        invoked_cell,
                        "unavailable",
                        "browser-identity-changed",
                        authenticated_task_root_finalized=(
                            independently_finalized_task_root
                        ),
                    )
                    for invoked_cell in group
                ]
                _append_finalized_group(
                    chained_records[0],
                    output.finalization_key,
                    chained_records,
                    completed,
                    finalized_group,
                )
                for pending in remaining[offset + 3 :]:
                    record = _not_run_record(
                        pending,
                        versions.get(pending.bundle_identifier, "unverified"),
                        "browser-identity-changed",
                    )
                    chained_records.append(
                        _chain_record(record, chained_records[-1]["recordHash"])
                    )
                    completed.append(chained_records[-1])
                _write_records(evidence_path, chained_records)
                if exit_code != MATRIX_PRODUCT_FAILURE:
                    exit_code = MATRIX_BLOCKED
                break
            expectations = tuple(
                DriverProofExpectation(
                    session=session,
                    request=request,
                    bundle_identifier=state_cell.bundle_identifier,
                    target_id=_expected_target_id(state_cell),
                    capability=state_cell.capability,
                    state=state_cell.state,
                    mode=state_cell.mode,
                    mechanism=state_cell.mechanism,
                    e2e_app_identity=e2e_app_identity,
                    browser_app_identity=application_identities[
                        state_cell.bundle_identifier
                    ],
                )
                for state_cell, session, request in zip(group, sessions, requests)
            )
            try:
                sequence_results = validate_driver_sequence_report(
                    report, driver_code, expectations
                )
                proof_contract_valid = True
            except DriverProofError:
                sequence_results = tuple(
                    ("NOT RUN", "harness-ambiguity") for _ in _STATES
                )
                proof_contract_valid = False
            proofs = report.get("stateProofs", []) if isinstance(report, dict) else []
            finalized_group = []
            for index, (state_cell, (result, detail)) in enumerate(
                zip(group, sequence_results)
            ):
                if result == "NOT RUN":
                    record = _not_run_record(
                        state_cell,
                        versions[state_cell.bundle_identifier],
                        detail,
                        authenticated_task_root_finalized=(
                            independently_finalized_task_root
                        ),
                    )
                    finalized_group.append(record)
                    continue
                proof = proofs[index] if index < len(proofs) else {}
                cell_report = {
                    "outcome": proof.get("outcome", "not-invoked"),
                    "token_received": proof.get("receipt") is True,
                    "exact_process_identity": proof.get("e2eIdentity") is True,
                    "exact_browser_process_identity": proof.get("browserIdentity")
                    is True,
                    "launch_provenance": proof.get("provenance", "none"),
                    "total_elapsed_seconds": proof.get("routeElapsedSeconds", 0.0),
                    "route_timeout_seconds": report.get("route_timeout_seconds", 0.0),
                    "browser_cleanup_grace_seconds": report.get(
                        "browser_cleanup_grace_seconds", 0.0
                    ),
                    "browser_quiescence_seconds": report.get(
                        "browser_quiescence_seconds", 0.0
                    ),
                    "session_hash": report.get("sessionHashes", [])[index]
                    if proof_contract_valid
                    and index < len(proofs)
                    and isinstance(report.get("sessionHashes"), list)
                    and index < len(report["sessionHashes"])
                    else "not-invoked",
                    "cleanup_success": report.get("cleanup_success") is True,
                    "task_root_finalized": (
                        independently_finalized_task_root
                        if has_independent_task_finalization
                        else report.get("task_root_finalized") is True
                    ),
                    "task_finalization_source": (
                        _AUTHENTICATED_FINALIZATION_SOURCE
                        if has_independent_task_finalization
                        and independently_finalized_task_root
                        else "none"
                    ),
                }
                record = _sanitized_record(
                    state_cell,
                    versions[state_cell.bundle_identifier],
                    application_identities[state_cell.bundle_identifier],
                    cell_report,
                    result,
                    detail,
                )
                finalized_group.append(record)
                if result == "FAIL":
                    exit_code = MATRIX_PRODUCT_FAILURE
                elif result == "UNSUPPORTED" and exit_code == MATRIX_SUCCESS:
                    exit_code = MATRIX_BLOCKED
            _append_finalized_group(
                chained_records[0],
                output.finalization_key,
                chained_records,
                completed,
                finalized_group,
            )
            _write_records(evidence_path, chained_records)
            must_stop = any(
                result == "NOT RUN" and detail == "harness-ambiguity"
                for result, detail in sequence_results
            )
            edge_pilot = cell.sequence == 0
            if (
                must_stop
                or edge_pilot
                and any(result != "PASS" for result, _ in sequence_results)
            ):
                if must_stop:
                    if exit_code != MATRIX_PRODUCT_FAILURE:
                        exit_code = MATRIX_BLOCKED
                    stop_detail = "blocked-after-ambiguity"
                else:
                    exit_code = (
                        MATRIX_PRODUCT_FAILURE
                        if any(result == "FAIL" for result, _ in sequence_results)
                        else MATRIX_BLOCKED
                    )
                    stop_detail = "edge-pilot-failed"
                remaining_tail = remaining[offset + 3 :]
                for pending in remaining_tail:
                    pending_record = _not_run_record(
                        pending,
                        versions.get(pending.bundle_identifier, "unverified"),
                        stop_detail,
                    )
                    chained_records.append(
                        _chain_record(pending_record, chained_records[-1]["recordHash"])
                    )
                    completed.append(chained_records[-1])
                _write_records(evidence_path, chained_records)
                break
            offset += 3
    finally:
        close = getattr(pinned_app, "close", None)
        if callable(close):
            close()
    return MatrixExecutionResult(exit_code, tuple(completed))


def dry_run(manifest, *, dependencies=None):
    dependencies = dependencies or SystemDependencies()
    cells = plan_cells(manifest, dependencies.is_installed)
    for cell in cells:
        if not cell.installed:
            continue
        print(cell.identifier)
    return MATRIX_SUCCESS if any(cell.installed for cell in cells) else MATRIX_BLOCKED


_HANDOFF_FILE = "cleanup-ledger.jsonl"
_HANDOFF_TRANSITIONS = frozenset(
    {
        "initialized",
        "root-owned",
        "baseline-empty",
        "child-owned",
        "browser-owned",
        "cleanup-progress",
        "finalized",
    }
)


def _handoff_process_identity(record):
    if not isinstance(record, dict) or set(record) != {
        "pid",
        "parentPid",
        "startSeconds",
        "startMicroseconds",
        "executable",
    }:
        raise MatrixIdentityError("invalid cleanup process identity")
    if (
        any(
            not isinstance(record[key], int) or isinstance(record[key], bool)
            for key in ("pid", "parentPid", "startSeconds", "startMicroseconds")
        )
        or record["pid"] <= 0
        or record["parentPid"] < 0
        or record["startSeconds"] < 0
        or not 0 <= record["startMicroseconds"] < 1_000_000
        or not isinstance(record["executable"], str)
        or not pathlib.Path(record["executable"]).is_absolute()
    ):
        raise MatrixIdentityError("invalid cleanup process identity")
    return browser_driver.ProcessIdentity(
        record["pid"],
        record["parentPid"],
        record["startSeconds"],
        record["startMicroseconds"],
        pathlib.Path(record["executable"]),
    )


def _validate_handoff_root_record(record):
    if not isinstance(record, dict) or set(record) != {
        "path",
        "device",
        "inode",
        "owner",
        "mode",
    }:
        raise MatrixIdentityError("invalid cleanup task root")
    if (
        not isinstance(record["path"], str)
        or any(
            not isinstance(record[key], int) or isinstance(record[key], bool)
            for key in ("device", "inode", "owner", "mode")
        )
        or record["device"] < 0
        or record["inode"] <= 0
        or record["owner"] != os.getuid()
        or record["mode"] != 0o700
    ):
        raise MatrixIdentityError("invalid cleanup task root")
    path = pathlib.Path(record["path"])
    if (
        not path.is_absolute()
        or path.parent != pathlib.Path("/private/tmp")
        or not path.name.startswith("pickvia-e2e-")
    ):
        raise MatrixIdentityError("invalid cleanup task root")
    return record


class _CleanupHandoff:
    def __init__(
        self,
        descriptor,
        token,
        context,
        secret_reader,
        secret_writer,
    ):
        self.descriptor = descriptor
        self.token = token
        self.context = context
        self.secret_reader = secret_reader
        self.secret_writer = secret_writer
        self._retained = True
        self.driver_identity = None
        self.task_root_finalized = False

    @classmethod
    def create(cls, context, *, temporary_parent="/private/tmp"):
        directory = pathlib.Path(
            tempfile.mkdtemp(
                prefix="pickvia-matrix-handoff-", dir=os.fspath(temporary_parent)
            )
        )
        os.chmod(directory, 0o700)
        path = directory / _HANDOFF_FILE
        descriptor = os.open(
            path,
            os.O_RDWR
            | os.O_APPEND
            | os.O_CREAT
            | os.O_EXCL
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0),
            0o600,
        )
        os.fchmod(descriptor, 0o600)
        os.unlink(path)
        os.rmdir(directory)
        secret_reader, secret_writer = os.pipe()
        return cls(
            descriptor,
            secrets.token_hex(32),
            context,
            secret_reader,
            secret_writer,
        )

    def child_secret_descriptor(self):
        if self.secret_reader is None:
            raise MatrixIdentityError("cleanup secret reader is unavailable")
        return self.secret_reader

    def child_ledger_descriptor(self):
        return self.descriptor

    def deliver_secret(self):
        if self.secret_writer is None:
            raise MatrixIdentityError("cleanup secret was already delivered")
        try:
            payload = (self.token + "\n").encode("ascii")
            offset = 0
            while offset < len(payload):
                written = os.write(self.secret_writer, payload[offset:])
                if written <= 0:
                    raise MatrixIdentityError("cleanup secret delivery failed")
                offset += written
        finally:
            os.close(self.secret_writer)
            self.secret_writer = None
            os.close(self.secret_reader)
            self.secret_reader = None

    def _require_current(self):
        opened = os.fstat(self.descriptor)
        if (
            not stat.S_ISREG(opened.st_mode)
            or opened.st_uid != os.getuid()
            or stat.S_IMODE(opened.st_mode) != 0o600
            or opened.st_nlink != 0
        ):
            raise MatrixIdentityError("cleanup handoff identity changed")

    def records(self):
        self._require_current()
        metadata = os.fstat(self.descriptor)
        maximum = (
            browser_driver.MAXIMUM_HANDOFF_RECORD_BYTES
            * browser_driver.MAXIMUM_HANDOFF_RECORDS
        )
        if metadata.st_size > maximum:
            raise MatrixIdentityError("cleanup handoff is oversized")
        contents = b""
        offset = 0
        while len(contents) <= maximum:
            chunk = os.pread(
                self.descriptor,
                min(65_536, maximum + 1 - len(contents)),
                offset,
            )
            if not chunk:
                break
            contents += chunk
            offset += len(chunk)
        after = os.fstat(self.descriptor)
        if (
            len(contents) != metadata.st_size
            or after.st_size != metadata.st_size
            or after.st_mtime_ns != metadata.st_mtime_ns
            or after.st_ctime_ns != metadata.st_ctime_ns
            or (contents and not contents.endswith(b"\n"))
        ):
            raise MatrixIdentityError("cleanup handoff is incomplete")
        self._require_current()
        records = []
        previous_children = set()
        previous_browsers = set()
        root_record = None
        cleanup_started = False
        baseline_empty = False
        driver_identity = None
        for counter, line in enumerate(contents.splitlines(), 1):
            if len(line) + 1 > browser_driver.MAXIMUM_HANDOFF_RECORD_BYTES:
                raise MatrixIdentityError("cleanup handoff record is oversized")
            try:
                record = json.loads(
                    line,
                    object_pairs_hook=_unique_object,
                    parse_constant=_reject_constant,
                )
            except (
                UnicodeDecodeError,
                json.JSONDecodeError,
                MatrixManifestError,
            ) as error:
                raise MatrixIdentityError("cleanup handoff is malformed") from error
            if not isinstance(record, dict) or set(record) != {
                "payload",
                "authentication",
            }:
                raise MatrixIdentityError("cleanup handoff schema mismatch")
            payload = record["payload"]
            authentication = record["authentication"]
            canonical = json.dumps(
                payload, sort_keys=True, separators=(",", ":"), ensure_ascii=True
            ).encode("ascii")
            expected = hmac.new(
                bytes.fromhex(self.token), canonical, hashlib.sha256
            ).hexdigest()
            if not isinstance(authentication, str) or not hmac.compare_digest(
                authentication, expected
            ):
                raise MatrixIdentityError("cleanup handoff authentication failed")
            if not isinstance(payload, dict) or set(payload) != {
                "schemaVersion",
                "counter",
                "transition",
                "context",
                "driverProcess",
                "baselineEmpty",
                "taskRoot",
                "ownedChildren",
                "ownedBrowsers",
                "taskRootFinalized",
            }:
                raise MatrixIdentityError("cleanup handoff payload mismatch")
            transition = payload["transition"]
            current_driver = _handoff_process_identity(payload["driverProcess"])
            if (
                payload["schemaVersion"] != 1
                or payload["counter"] != counter
                or transition not in _HANDOFF_TRANSITIONS
                or payload["context"] != self.context
                or not isinstance(payload["baselineEmpty"], bool)
                or not isinstance(payload["taskRootFinalized"], bool)
                or not isinstance(payload["ownedChildren"], list)
                or not isinstance(payload["ownedBrowsers"], list)
            ):
                raise MatrixIdentityError("cleanup handoff invariant failed")
            if driver_identity is None:
                driver_identity = current_driver
            elif current_driver.generation_key != driver_identity.generation_key:
                raise MatrixIdentityError("cleanup driver identity changed")
            if (
                self.driver_identity is not None
                and current_driver.generation_key != self.driver_identity.generation_key
            ):
                raise MatrixIdentityError("cleanup driver identity mismatch")
            children = tuple(
                _handoff_process_identity(value) for value in payload["ownedChildren"]
            )
            browsers = tuple(
                _handoff_process_identity(value) for value in payload["ownedBrowsers"]
            )
            child_keys = {value.generation_key for value in children}
            browser_keys = {value.generation_key for value in browsers}
            if len(child_keys) != len(children) or len(browser_keys) != len(browsers):
                raise MatrixIdentityError("duplicate cleanup ownership")
            current_root = payload["taskRoot"]
            if transition == "initialized":
                if (
                    counter != 1
                    or current_root is not None
                    or children
                    or browsers
                    or payload["baselineEmpty"]
                ):
                    raise MatrixIdentityError("invalid cleanup initialization")
            elif transition == "root-owned":
                if counter != 2 or root_record is not None or children or browsers:
                    raise MatrixIdentityError("invalid cleanup root transition")
                root_record = _validate_handoff_root_record(current_root)
            elif transition == "baseline-empty":
                if (
                    baseline_empty
                    or root_record is None
                    or current_root != root_record
                    or children
                    or browsers
                    or not payload["baselineEmpty"]
                ):
                    raise MatrixIdentityError("invalid baseline transition")
                baseline_empty = True
            elif transition in {"child-owned", "browser-owned"}:
                if (
                    cleanup_started
                    or current_root != root_record
                    or root_record is None
                    or not baseline_empty
                ):
                    raise MatrixIdentityError("late cleanup ownership transition")
                if transition == "child-owned" and not (
                    previous_children < child_keys and previous_browsers == browser_keys
                ):
                    raise MatrixIdentityError("invalid child ownership transition")
                if transition == "browser-owned" and not (
                    previous_browsers < browser_keys and previous_children == child_keys
                ):
                    raise MatrixIdentityError("invalid browser ownership transition")
            elif transition == "cleanup-progress":
                cleanup_started = True
                if (
                    current_root != root_record
                    or not child_keys.issubset(previous_children)
                    or not browser_keys.issubset(previous_browsers)
                ):
                    raise MatrixIdentityError("invalid cleanup progress")
            elif transition == "finalized":
                if (
                    counter == 1
                    or not cleanup_started
                    or root_record is None
                    or current_root is not None
                    or children
                    or browsers
                    or not payload["taskRootFinalized"]
                ):
                    raise MatrixIdentityError("invalid cleanup finalization")
            if transition != "finalized" and payload["taskRootFinalized"]:
                raise MatrixIdentityError("premature cleanup finalization")
            if payload["baselineEmpty"] != baseline_empty:
                raise MatrixIdentityError("cleanup baseline changed")
            previous_children = child_keys
            previous_browsers = browser_keys
            records.append((payload, children, browsers))
        if len(records) > browser_driver.MAXIMUM_HANDOFF_RECORDS:
            raise MatrixIdentityError("too many cleanup transitions")
        return tuple(records)

    def mark_recovered(self):
        self._retained = False

    def _persist_retained(self):
        maximum = (
            browser_driver.MAXIMUM_HANDOFF_RECORD_BYTES
            * browser_driver.MAXIMUM_HANDOFF_RECORDS
        )
        metadata = os.fstat(self.descriptor)
        if metadata.st_size > maximum:
            raise MatrixIdentityError("cleanup ledger cannot be retained safely")
        ledger = os.pread(self.descriptor, metadata.st_size, 0)
        directory = pathlib.Path(
            tempfile.mkdtemp(prefix="pickvia-matrix-retained-", dir="/private/tmp")
        )
        os.chmod(directory, 0o700)
        initial_directory = directory.lstat()
        directory_descriptor = os.open(
            directory,
            os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | getattr(os, "O_NOFOLLOW", 0),
        )
        try:
            if (
                not stat.S_ISDIR(initial_directory.st_mode)
                or stat.S_ISLNK(initial_directory.st_mode)
                or initial_directory.st_uid != os.getuid()
                or stat.S_IMODE(initial_directory.st_mode) != 0o700
                or _entry_generation(os.fstat(directory_descriptor))
                != _entry_generation(initial_directory)
                or directory.parent != pathlib.Path("/private/tmp")
            ):
                raise MatrixIdentityError("retained evidence directory is unsafe")
            artifacts = {
                "cleanup-ledger.jsonl": ledger,
                "authentication-key": (self.token + "\n").encode("ascii"),
                "context.json": (
                    json.dumps(
                        self.context,
                        sort_keys=True,
                        separators=(",", ":"),
                        ensure_ascii=True,
                    )
                    + "\n"
                ).encode("ascii"),
            }
            for name, contents in artifacts.items():
                descriptor = os.open(
                    name,
                    os.O_WRONLY
                    | os.O_CREAT
                    | os.O_EXCL
                    | os.O_CLOEXEC
                    | getattr(os, "O_NOFOLLOW", 0),
                    0o600,
                    dir_fd=directory_descriptor,
                )
                try:
                    offset = 0
                    while offset < len(contents):
                        written = os.write(descriptor, contents[offset:])
                        if written <= 0:
                            raise OSError("retained evidence write failed")
                        offset += written
                    os.fsync(descriptor)
                    opened = os.fstat(descriptor)
                    named = os.stat(
                        name,
                        dir_fd=directory_descriptor,
                        follow_symlinks=False,
                    )
                    if (
                        not stat.S_ISREG(opened.st_mode)
                        or opened.st_uid != os.getuid()
                        or stat.S_IMODE(opened.st_mode) != 0o600
                        or opened.st_nlink != 1
                        or _entry_generation(opened) != _entry_generation(named)
                        or opened.st_size != len(contents)
                    ):
                        raise MatrixIdentityError("retained evidence file is unsafe")
                finally:
                    os.close(descriptor)
            os.fsync(directory_descriptor)
            if _entry_generation(directory.lstat()) != _entry_generation(
                initial_directory
            ):
                raise MatrixIdentityError("retained evidence directory changed")
            self.retained_path = directory
        finally:
            os.close(directory_descriptor)

    def close(self):
        if self._retained:
            self._persist_retained()
        for attribute in ("secret_reader", "secret_writer"):
            descriptor = getattr(self, attribute)
            if descriptor is not None:
                try:
                    os.close(descriptor)
                except OSError:
                    pass
                setattr(self, attribute, None)
        try:
            os.close(self.descriptor)
        except OSError:
            pass


def _entry_generation(metadata):
    return (metadata.st_dev, metadata.st_ino, metadata.st_uid, metadata.st_mode)


def _reopen_handoff_task_root(record):
    record = _validate_handoff_root_record(record)
    path = pathlib.Path(record["path"])
    parent_descriptor = os.open(
        "/private/tmp",
        os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_CLOEXEC", 0),
    )
    try:
        descriptor = os.open(
            path.name,
            os.O_RDONLY
            | os.O_DIRECTORY
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=parent_descriptor,
        )
    except Exception:
        os.close(parent_descriptor)
        raise
    metadata = os.fstat(descriptor)
    identity = browser_driver._DirectoryIdentity.from_stat(metadata)
    expected = browser_driver._DirectoryIdentity(
        record["device"], record["inode"], record["owner"], record["mode"]
    )
    if identity != expected:
        os.close(descriptor)
        os.close(parent_descriptor)
        raise MatrixIdentityError("cleanup task root changed")
    return browser_driver._PinnedTaskRoot(
        path,
        descriptor,
        identity,
        parent_descriptor,
        browser_driver._DirectoryIdentity.from_stat(os.fstat(parent_descriptor)),
    )


def _terminate_exact_handoff_child(
    identity,
    executable,
    cleanup_deadline,
    *,
    identity_reader=browser_driver._darwin_process_identity,
    signaler=os.kill,
    monotonic=time.monotonic,
    sleep=time.sleep,
):
    def current_generation():
        try:
            current = identity_reader(identity.pid)
        except browser_driver._ProcessDisappeared:
            return None
        if (
            current.generation_key != identity.generation_key
            or current.executable != pathlib.Path(executable)
        ):
            raise MatrixIdentityError("owned child generation changed")
        return current

    if current_generation() is None:
        return True
    if monotonic() >= cleanup_deadline:
        return False
    try:
        signaler(identity.pid, signal.SIGTERM)
        if current_generation() is not None:
            signaler(identity.pid, signal.SIGCONT)
    except ProcessLookupError:
        return True
    term_deadline = min(cleanup_deadline, monotonic() + 0.5)
    while monotonic() < term_deadline:
        if current_generation() is None:
            return True
        sleep(min(0.02, term_deadline - monotonic()))
    if current_generation() is None:
        return True
    try:
        signaler(identity.pid, signal.SIGKILL)
    except ProcessLookupError:
        return True
    while monotonic() < cleanup_deadline:
        if current_generation() is None:
            return True
        sleep(min(0.02, cleanup_deadline - monotonic()))
    return current_generation() is None


def _recover_cleanup_handoff(
    handoff,
    *,
    identity_reader=browser_driver._darwin_process_identity,
    terminator=None,
    snapshotter=browser_driver._snapshot_exact_browser_processes,
    direct_child_snapshotter=browser_driver._snapshot_process_group,
    static_checker=None,
    root_reopener=_reopen_handoff_task_root,
    root_remover=browser_driver._remove_task_root,
    monotonic=time.monotonic,
    sleep=time.sleep,
):
    records = handoff.records()
    if not records:
        return False
    payload, children, browsers = records[-1]
    root_records = [
        record_payload["taskRoot"]
        for record_payload, _record_children, _record_browsers in records
        if record_payload["taskRoot"] is not None
    ]
    if not root_records or any(record != root_records[0] for record in root_records):
        return False
    root_record = root_records[0]
    finalized = payload["transition"] == "finalized"
    if not any(record_payload["baselineEmpty"] for record_payload, _, _ in records):
        return False
    driver_identity = handoff.driver_identity or _handoff_process_identity(
        payload["driverProcess"]
    )
    try:
        current_driver = identity_reader(driver_identity.pid)
        process_group = direct_child_snapshotter(driver_identity.pid)
    except (
        browser_driver._ProcessDisappeared,
        browser_driver._IdentityInspectionError,
    ):
        return False
    if current_driver.generation_key != driver_identity.generation_key:
        return False
    child_map = {value.generation_key: value for value in children}
    for group_process in process_group:
        if group_process.generation_key == driver_identity.generation_key:
            continue
        child_map[group_process.generation_key] = group_process
    children = tuple(child_map.values())
    browser_executable = pathlib.Path(handoff.context["browserExecutable"])
    try:
        current_browsers = snapshotter(browser_executable)
    except browser_driver._IdentityInspectionError:
        return False
    browser_map = {value.generation_key: value for value in browsers}
    for current_browser in current_browsers:
        if current_browser.generation_key not in browser_map:
            return False
    browsers = tuple(browser_map.values())

    def static_matches():
        if static_checker is not None:
            return static_checker(handoff.context)
        try:
            return (
                browser_driver._browser_static_identity(
                    pathlib.Path(handoff.context["browserApplication"]),
                    browser_executable,
                    handoff.context["bundleIdentifier"],
                )[1]
                == handoff.context["browserAppIdentity"]
            )
        except (OSError, browser_driver._IdentityError):
            return False

    if not static_matches():
        return False
    owned = (*children, *browsers)
    for expected in owned:
        try:
            current = identity_reader(expected.pid)
        except browser_driver._ProcessDisappeared:
            continue
        if current.generation_key != expected.generation_key:
            return False
    deadline = monotonic() + browser_driver.BROWSER_CLEANUP_GRACE_SECONDS
    child_terminator = terminator or _terminate_exact_handoff_child
    browser_terminator = terminator or browser_driver._terminate_exact_browser_process
    for expected in children:
        if not child_terminator(expected, expected.executable, deadline):
            return False
    for expected in browsers:
        if expected.executable != browser_executable or not browser_terminator(
            expected, browser_executable, deadline
        ):
            return False
    quiescence_deadline = monotonic() + browser_driver.BROWSER_QUIESCENCE_SECONDS
    while True:
        try:
            if snapshotter(browser_executable):
                return False
        except browser_driver._IdentityInspectionError:
            return False
        now = monotonic()
        if now >= quiescence_deadline:
            break
        sleep(
            min(
                browser_driver.BROWSER_QUIESCENCE_POLL_SECONDS,
                quiescence_deadline - now,
            )
        )
    try:
        remaining_group = direct_child_snapshotter(driver_identity.pid)
        if any(
            value.generation_key != driver_identity.generation_key
            for value in remaining_group
        ):
            return False
    except browser_driver._IdentityInspectionError:
        return False
    root_path = pathlib.Path(root_record["path"])
    if finalized:
        if root_path.exists() or root_path.is_symlink():
            return False
    else:
        root = root_reopener(root_record)
        if not root_remover(root) or root_path.exists() or root_path.is_symlink():
            return False
    if not static_matches():
        return False
    handoff.task_root_finalized = True
    handoff.mark_recovered()
    return True


def _supervise_driver_process(
    arguments,
    environment,
    *,
    popen=subprocess.Popen,
    identity_reader=browser_driver._darwin_process_identity,
    signaler=os.kill,
    run_timeout=150.0,
    cleanup_timeout=15.0,
    handoff=None,
    recoverer=_recover_cleanup_handoff,
):
    independently_recovered = False
    try:
        popen_options = {
            "cwd": _REPOSITORY_ROOT,
            "env": environment,
            "stdin": subprocess.DEVNULL,
            "stdout": subprocess.PIPE,
            "stderr": subprocess.PIPE,
            "start_new_session": True,
        }
        if isinstance(handoff, _CleanupHandoff):
            popen_options["pass_fds"] = (
                handoff.child_ledger_descriptor(),
                handoff.child_secret_descriptor(),
            )
        process = popen(arguments, **popen_options)
        if isinstance(handoff, _CleanupHandoff):
            handoff.deliver_secret()
        identity = identity_reader(process.pid)
        if identity.pid != process.pid or identity.executable != pathlib.Path(
            arguments[0]
        ):
            raise MatrixIdentityError("driver process identity mismatch")
        if isinstance(handoff, _CleanupHandoff):
            handoff.driver_identity = identity
        try:
            stdout, stderr = process.communicate(timeout=run_timeout)
        except subprocess.TimeoutExpired:
            current = identity_reader(process.pid)
            if current.generation_key != identity.generation_key:
                raise MatrixIdentityError("driver generation changed before TERM")
            signaler(identity.pid, signal.SIGTERM)
            try:
                stdout, stderr = process.communicate(timeout=cleanup_timeout)
            except subprocess.TimeoutExpired as error:
                current = identity_reader(process.pid)
                if current.generation_key != identity.generation_key:
                    raise MatrixIdentityError(
                        "driver generation changed during cleanup"
                    ) from error
                if handoff is None or not recoverer(handoff):
                    raise MatrixIdentityError(
                        "driver did not prove independent cleanup"
                    ) from error
                independently_recovered = True
                current = identity_reader(process.pid)
                if current.generation_key != identity.generation_key:
                    raise MatrixIdentityError(
                        "driver generation changed after cleanup"
                    ) from error
                signaler(identity.pid, signal.SIGKILL)
                try:
                    stdout, stderr = process.communicate(timeout=cleanup_timeout)
                except subprocess.TimeoutExpired as final_error:
                    raise MatrixIdentityError(
                        "recovered driver generation did not exit"
                    ) from final_error
        if process.returncode is None:
            raise MatrixIdentityError("driver completion status is unavailable")
        if handoff is not None and not independently_recovered:
            records = handoff.records()
            if not records or records[-1][0]["transition"] != "finalized":
                raise MatrixIdentityError("driver cleanup handoff is not terminal")
            handoff.task_root_finalized = True
            handoff.mark_recovered()
        return subprocess.CompletedProcess(
            arguments,
            process.returncode,
            stdout=stdout,
            stderr=stderr,
        )
    except (
        OSError,
        browser_driver._ProcessDisappeared,
        browser_driver._IdentityInspectionError,
    ) as error:
        raise MatrixIdentityError("driver supervision failed") from error


class SystemDependencies:
    def is_installed(self, application):
        path = application.application_path
        try:
            metadata = path.lstat()
            return (
                stat.S_ISDIR(metadata.st_mode)
                and not path.is_symlink()
                and path.resolve(strict=True) == path
            )
        except OSError:
            return False

    def verify_application(self, application):
        try:
            version, identity = browser_driver._browser_static_identity(
                application.application_path,
                application.executable_path,
                application.bundle_identifier,
            )
            if not isinstance(version, str) or _SAFE_VERSION.fullmatch(version) is None:
                raise MatrixIdentityError("invalid version")
            return VerifiedApplication(version, identity)
        except (
            OSError,
            plistlib.InvalidFileException,
            browser_driver._IdentityError,
        ) as error:
            raise MatrixIdentityError("application identity failed") from error

    def build_and_pin(self):
        environment = {
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "en_US.UTF-8",
            "LC_CTYPE": "UTF-8",
        }
        completed = subprocess.run(
            ["/bin/zsh", os.fspath(_REPOSITORY_ROOT / "scripts" / "build-e2e-app.sh")],
            cwd=_REPOSITORY_ROOT,
            env=environment,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=180,
            check=False,
        )
        if completed.returncode != 0:
            raise MatrixIdentityError("E2E build failed")
        application = _REPOSITORY_ROOT / "build-e2e" / "PickVia E2E.app"
        verification = subprocess.run(
            [
                "/usr/bin/codesign",
                "--verify",
                "--deep",
                "--strict",
                os.fspath(application),
            ],
            env=environment,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=10,
            check=False,
        )
        if verification.returncode != 0:
            raise MatrixIdentityError("E2E signature failed")
        return smoke_e2e_runtime.PinnedApplication.open(application)

    def e2e_identity(self, pinned_app):
        if not pinned_app.validate():
            raise MatrixIdentityError("E2E application identity changed")
        fields = (
            pinned_app.directory_stat.st_ino,
            pinned_app.directory_stat.st_ctime_ns,
            pinned_app.executable_stat.st_ino,
            pinned_app.executable_stat.st_mtime_ns,
            pinned_app.bundle_manifest,
        )
        return hashlib.sha256(repr(fields).encode("utf-8")).hexdigest()

    def run_sequence(
        self,
        pinned_app,
        group,
        sessions,
        requests,
        profile_relative_root,
        e2e_app_identity,
        browser_app_identity,
    ):
        cell = group[0]
        if not pinned_app.validate():
            raise MatrixIdentityError("E2E application identity changed")
        target_id = f"{cell.bundle_identifier}||{cell.mode}"
        handoff_context = _sequence_handoff_context(
            cell,
            target_id,
            sessions,
            profile_relative_root,
            e2e_app_identity,
            browser_app_identity,
        )
        handoff = _CleanupHandoff.create(handoff_context)
        arguments = [
            "/usr/bin/python3",
            os.fspath(_SCRIPT_DIR / "pickvia_e2e_driver.py"),
            "--e2e-app",
            os.fspath(pinned_app.path),
            "--browser-app",
            os.fspath(cell.application.application_path),
            "--expected-browser-executable",
            os.fspath(cell.application.executable_path),
            "--target-id",
            target_id,
            "--bundle-id",
            cell.bundle_identifier,
            "--mode",
            cell.mode,
            "--mechanism",
            cell.mechanism,
            "--session",
            sessions[0],
            "--request",
            requests[0],
            "--capability",
            cell.capability,
            "--state",
            "sequence",
            "--e2e-app-identity",
            e2e_app_identity,
            "--browser-app-identity",
            browser_app_identity,
            "--route-count",
            "3",
            "--cleanup-handoff-fd",
            str(handoff.child_ledger_descriptor()),
            "--cleanup-handoff-secret-fd",
            str(handoff.child_secret_descriptor()),
        ]
        for request in requests:
            arguments.extend(["--sequence-request", request])
        for session in sessions:
            arguments.extend(["--sequence-session", session])
        if profile_relative_root is not None:
            arguments.extend(
                [
                    "--profile-strategy",
                    cell.profile_strategy,
                    "--profile-relative-root",
                    profile_relative_root,
                    "--create-profile",
                    "--derive-profile-target",
                ]
            )
        environment = {
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "en_US.UTF-8",
            "LC_CTYPE": "UTF-8",
            "PYTHONDONTWRITEBYTECODE": "1",
        }
        try:
            completed = _supervise_driver_process(
                arguments, environment, handoff=handoff
            )
            task_root_finalized = handoff.task_root_finalized
        finally:
            handoff.close()
        try:
            if len(completed.stdout) > 16_384 or not completed.stdout.endswith(b"\n"):
                raise ValueError
            text = completed.stdout.decode("utf-8")
            decoder = json.JSONDecoder(
                object_pairs_hook=_unique_object,
                parse_constant=_reject_constant,
            )
            report, end = decoder.raw_decode(text)
            if text[end:] != "\n":
                raise ValueError
            if not isinstance(report, dict):
                raise ValueError
        except (
            UnicodeDecodeError,
            json.JSONDecodeError,
            ValueError,
            MatrixManifestError,
        ):
            report = {"outcome": "invalid-driver-report"}
            return (
                report,
                browser_driver.DRIVER_PROCESS_ERROR,
                task_root_finalized,
            )
        return report, completed.returncode, task_root_finalized


class _ArgumentParser(argparse.ArgumentParser):
    def error(self, _message):
        self.print_usage(sys.stderr)
        self.exit(MATRIX_USAGE, f"{self.prog}: error: invalid arguments\n")


def main(argv=None):
    parser = _ArgumentParser(
        description="Run the installed PickVia browser matrix sequentially."
    )
    parser.add_argument("--manifest", required=True, type=pathlib.Path)
    parser.add_argument("--output", type=pathlib.Path)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--resume", action="store_true")
    arguments = parser.parse_args(argv)
    if arguments.dry_run and (arguments.output is not None or arguments.resume):
        return MATRIX_USAGE
    if not arguments.dry_run and arguments.output is None:
        return MATRIX_USAGE
    try:
        manifest = load_manifest(arguments.manifest, enforce_required=True)
        if arguments.dry_run:
            return dry_run(manifest)
        return execute_matrix(
            manifest,
            arguments.output,
            resume=arguments.resume,
        ).exit_code
    except (MatrixError, MatrixIdentityError):
        return MATRIX_BLOCKED


if __name__ == "__main__":
    raise SystemExit(main())
