#!/usr/bin/env python3

import argparse
import dataclasses
import hashlib
import json
import math
import os
import pathlib
import plistlib
import re
import secrets
import stat
import subprocess
import sys

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
        "result",
        "detail",
        "driverOutcome",
        "provenance",
        "receipt",
        "e2eIdentity",
        "browserIdentity",
        "sessionHash",
        "previousHash",
        "recordHash",
    }
)
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
        data = pathlib.Path(path).read_bytes()
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


def _plan_digest(cells):
    return _digest_json([cell.specification_hash for cell in cells])


def _chain_record(record, previous_hash):
    chained = dict(record)
    chained["previousHash"] = previous_hash
    chained["recordHash"] = _digest_json(chained)
    return chained


def _validate_output_directory(output, *, create):
    output = pathlib.Path(output)
    if not output.is_absolute() or output.parent == output:
        raise MatrixError("unsafe output directory")
    if output.exists() or output.is_symlink():
        metadata = output.lstat()
        if (
            output.is_symlink()
            or not stat.S_ISDIR(metadata.st_mode)
            or metadata.st_uid != os.getuid()
            or metadata.st_mode & 0o077
            or output.resolve(strict=True) != output
        ):
            raise MatrixError("unsafe output directory")
        if create and any(output.iterdir()):
            raise MatrixError("fresh output directory is not empty")
        if not create:
            entries = list(output.iterdir())
            if len(entries) != 1 or entries[0].name != _EVIDENCE_NAME:
                raise MatrixResumeError("resume directory contains unexpected entries")
            evidence = entries[0]
            evidence_metadata = evidence.lstat()
            if (
                evidence.is_symlink()
                or not stat.S_ISREG(evidence_metadata.st_mode)
                or evidence_metadata.st_uid != os.getuid()
                or stat.S_IMODE(evidence_metadata.st_mode) != 0o600
                or evidence.resolve(strict=True) != evidence
            ):
                raise MatrixResumeError("resume evidence identity is invalid")
    elif create:
        output.mkdir(mode=0o700)
    else:
        raise MatrixResumeError("missing output directory")
    return output


def _write_records(path, records):
    data = b"".join(
        (
            json.dumps(record, allow_nan=False, separators=(",", ":"), sort_keys=True)
            + "\n"
        ).encode("ascii")
        for record in records
    )
    if len(data) > _MAXIMUM_EVIDENCE_BYTES:
        raise MatrixError("evidence limit exceeded")
    temporary = path.with_name(f".{path.name}.{secrets.token_hex(8)}")
    descriptor = os.open(
        temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC, 0o600
    )
    try:
        offset = 0
        while offset < len(data):
            written = os.write(descriptor, data[offset:])
            if written <= 0:
                raise MatrixError("evidence write failed")
            offset += written
        os.fsync(descriptor)
        os.close(descriptor)
        descriptor = -1
        os.replace(temporary, path)
    except BaseException:
        if descriptor >= 0:
            os.close(descriptor)
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass
        raise
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def _read_resume(path, manifest, cells):
    try:
        data = path.read_bytes()
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
        "previousHash",
        "recordHash",
    }
    if (
        set(header) != expected_header_fields
        or header["recordType"] != "run"
        or header["schemaVersion"] != 1
        or header["manifestDigest"] != manifest.digest
        or header["planDigest"] != _plan_digest(cells)
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
        timing_keys = keys - _CELL_REQUIRED_KEYS
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
        ):
            raise MatrixResumeError("completed cell mismatch")
        session_hash = record["sessionHash"]
        if session_hash != "not-invoked":
            if session_hash in seen_session_hashes:
                raise MatrixResumeError("reused session hash")
            seen_session_hashes.add(session_hash)
        completed.append(record)
    return records, completed


def _classification(report, return_code):
    outcome = report.get("outcome")
    provenance = report.get("launch_provenance", "none")
    if return_code == 0 and outcome == "selected" and provenance == "launch-observed":
        return "PASS", "proven-route", False
    if outcome in {"launch-error"}:
        return "FAIL", "product-route-failure", False
    if (
        outcome == "receipt-timeout"
        and report.get("exact_browser_process_identity") is True
        and provenance == "launch-observed"
    ):
        return "FAIL", "product-receipt-failure", False
    if outcome in {"target-disabled", "target-mode-mismatch"}:
        return "UNSUPPORTED", "catalog-capability-refused", False
    return "NOT RUN", "harness-ambiguity", True


def _expected_target_id(cell):
    if not cell.has_profile:
        return f"{cell.bundle_identifier}||{cell.mode}"
    if cell.profile_strategy == "chromium":
        return f"{cell.bundle_identifier}|PickVia E2E|{cell.mode}"
    if cell.profile_strategy == "firefox":
        return "firefox-derived"
    raise DriverProofError("unsupported profile target")


def _sanitized_record(cell, version, report, result, detail):
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
    return {
        "recordType": "cell",
        "schemaVersion": 1,
        "sequence": cell.sequence,
        "cellHash": cell.specification_hash,
        "bundleIdentifier": cell.bundle_identifier,
        "capability": cell.capability,
        "state": cell.state,
        "installedVersion": safe_version,
        "result": result,
        "detail": detail,
        "driverOutcome": safe_outcome,
        "provenance": safe_provenance,
        "receipt": report.get("token_received") is True,
        "e2eIdentity": report.get("exact_process_identity") is True,
        "browserIdentity": report.get("exact_browser_process_identity") is True,
        "sessionHash": safe_session_hash,
        **timings,
    }


def _not_run_record(cell, version, detail):
    return _sanitized_record(
        cell,
        version,
        {"outcome": "not-invoked"},
        "NOT RUN",
        detail,
    )


def execute_matrix(manifest, output, *, dependencies=None, resume=False):
    dependencies = dependencies or SystemDependencies()
    cells = plan_cells(manifest, dependencies.is_installed)
    if not cells:
        raise MatrixError("no installed eligible cells")
    output = _validate_output_directory(output, create=not resume)
    evidence_path = output / _EVIDENCE_NAME
    if resume:
        chained_records, completed = _read_resume(evidence_path, manifest, cells)
        if len(completed) == len(cells):
            exit_code = (
                MATRIX_PRODUCT_FAILURE
                if any(record["result"] == "FAIL" for record in completed)
                else MATRIX_BLOCKED
                if any(record["result"] == "NOT RUN" for record in completed)
                else MATRIX_SUCCESS
            )
            return MatrixExecutionResult(exit_code, tuple(completed))
    else:
        header = _chain_record(
            {
                "recordType": "run",
                "schemaVersion": 1,
                "manifestDigest": manifest.digest,
                "planDigest": _plan_digest(cells),
            },
            "0" * 64,
        )
        chained_records = [header]
        completed = []
        _write_records(evidence_path, chained_records)

    versions = {}
    application_identities = {}
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
            versions[cell.bundle_identifier] = verification.version
            application_identities[cell.bundle_identifier] = verification.identity
        except MatrixIdentityError:
            versions[cell.bundle_identifier] = "unavailable"
            application_identities[cell.bundle_identifier] = "0" * 64
            identity_blocked_bundles.add(cell.bundle_identifier)
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
        return MatrixExecutionResult(MATRIX_SUCCESS, tuple(completed))
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
        return MatrixExecutionResult(MATRIX_BLOCKED, tuple(completed))
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
        return MatrixExecutionResult(MATRIX_BLOCKED, tuple(completed))
    exit_code = MATRIX_BLOCKED if blocked_bundles else MATRIX_SUCCESS
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
            sessions = tuple(secrets.token_hex(24) for _ in _STATES)
            requests = tuple(secrets.token_hex(24) for _ in _STATES)
            profile_relative_root = (
                f"profiles/{cell.specification_hash[:24]}" if cell.has_profile else None
            )
            try:
                report, driver_code = dependencies.run_sequence(
                    pinned_app,
                    group,
                    sessions,
                    requests,
                    profile_relative_root,
                    e2e_app_identity,
                    application_identities[cell.bundle_identifier],
                )
            except Exception:
                report = {"outcome": "invalid-driver-report"}
                driver_code = browser_driver.DRIVER_PROCESS_ERROR
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
            for index, (state_cell, (result, detail)) in enumerate(
                zip(group, sequence_results)
            ):
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
                }
                record = _sanitized_record(
                    state_cell,
                    versions[state_cell.bundle_identifier],
                    cell_report,
                    result,
                    detail,
                )
                chained_records.append(
                    _chain_record(record, chained_records[-1]["recordHash"])
                )
                completed.append(chained_records[-1])
                if result == "FAIL":
                    exit_code = MATRIX_PRODUCT_FAILURE
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
            browser_driver._validate_signed_browser_binding(
                application.application_path,
                application.executable_path,
                application.bundle_identifier,
            )
            with (application.application_path / "Contents" / "Info.plist").open(
                "rb"
            ) as handle:
                document = plistlib.load(handle)
            version = document.get("CFBundleShortVersionString") or document.get(
                "CFBundleVersion"
            )
            if not isinstance(version, str) or _SAFE_VERSION.fullmatch(version) is None:
                raise MatrixIdentityError("invalid version")
            identity_fields = (
                application.bundle_identifier,
                os.fspath(application.application_path),
                os.fspath(application.executable_path),
                application.application_path.lstat().st_ino,
                application.executable_path.lstat().st_ino,
                application.executable_path.lstat().st_mtime_ns,
                application.executable_path.lstat().st_size,
            )
            return VerifiedApplication(
                version,
                hashlib.sha256(repr(identity_fields).encode("utf-8")).hexdigest(),
            )
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
            completed = subprocess.run(
                arguments,
                cwd=_REPOSITORY_ROOT,
                env=environment,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=150,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            raise MatrixIdentityError("driver invocation failed") from error
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
            return report, browser_driver.DRIVER_PROCESS_ERROR
        return report, completed.returncode


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
