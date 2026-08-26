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
_NORMAL_STRATEGIES = frozenset({"unsupported", "workspace", "executable"})
_STATES = ("cold", "running", "reopen")
_RESULTS = frozenset({"PASS", "FAIL", "UNSUPPORTED", "NOT RUN"})
_MAXIMUM_MANIFEST_BYTES = 256 * 1024
_MAXIMUM_EVIDENCE_BYTES = 8 * 1024 * 1024
_EVIDENCE_NAME = "evidence.jsonl"
_SAFE_VERSION = re.compile(r"\A[A-Za-z0-9][A-Za-z0-9._+()-]{0,127}\Z")
_SAFE_DRIVER_OUTCOMES = frozenset(
    {
        "selected",
        "launch-error",
        "receipt-timeout",
        "target-disabled",
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
        "blocked-before-run",
        "blocked-after-ambiguity",
        "edge-pilot-failed",
        "build-blocker",
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
class MatrixCell:
    sequence: int
    bundle_identifier: str
    capability: str
    state: str
    application: MatrixApplication

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


def load_manifest(path):
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
        application
        for application in manifest.applications
        if not application.skip
        and application.bundle_identifier not in _APPLE_SKIPPED
        and is_installed(application)
    ]
    edge = next(
        (
            application
            for application in eligible
            if application.bundle_identifier == "com.microsoft.edgemac"
        ),
        None,
    )
    ordered = []
    if edge is not None and "normal" in _application_capabilities(edge):
        ordered.extend((edge, "normal", state) for state in _STATES)
    for application in eligible:
        for capability in _application_capabilities(application):
            if application is edge and capability == "normal":
                continue
            ordered.extend((application, capability, state) for state in _STATES)
    return tuple(
        MatrixCell(index, application.bundle_identifier, capability, state, application)
        for index, (application, capability, state) in enumerate(ordered)
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
        ):
            raise MatrixResumeError("completed cell mismatch")
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
    blocked_bundles = set()
    for cell in cells:
        if cell.bundle_identifier in versions:
            continue
        try:
            versions[cell.bundle_identifier] = dependencies.verify_application(
                cell.application
            )
        except MatrixIdentityError:
            versions[cell.bundle_identifier] = "unavailable"
            blocked_bundles.add(cell.bundle_identifier)
    if "com.microsoft.edgemac" in blocked_bundles:
        for cell in cells[len(completed) :]:
            detail = (
                "signature-blocker"
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
    exit_code = MATRIX_BLOCKED if blocked_bundles else MATRIX_SUCCESS
    stop_detail = None
    try:
        for offset, cell in enumerate(remaining):
            if cell.bundle_identifier in blocked_bundles:
                record = _not_run_record(
                    cell,
                    versions[cell.bundle_identifier],
                    "signature-blocker",
                )
                chained_records.append(
                    _chain_record(record, chained_records[-1]["recordHash"])
                )
                completed.append(chained_records[-1])
                _write_records(evidence_path, chained_records)
                continue
            session = secrets.token_hex(24)
            profile_relative_root = (
                f"profiles/{cell.specification_hash[:24]}" if cell.has_profile else None
            )
            try:
                report, driver_code = dependencies.run_driver(
                    pinned_app, cell, session, profile_relative_root
                )
            except Exception:
                report = {"outcome": "invalid-driver-report"}
                driver_code = browser_driver.DRIVER_PROCESS_ERROR
            result, detail, must_stop = _classification(report, driver_code)
            record = _sanitized_record(
                cell, versions[cell.bundle_identifier], report, result, detail
            )
            chained_records.append(
                _chain_record(record, chained_records[-1]["recordHash"])
            )
            completed.append(chained_records[-1])
            _write_records(evidence_path, chained_records)
            edge_pilot = (
                cell.sequence < 3 and cell.bundle_identifier == "com.microsoft.edgemac"
            )
            if result == "FAIL":
                exit_code = MATRIX_PRODUCT_FAILURE
            if must_stop or edge_pilot and result != "PASS":
                exit_code = MATRIX_BLOCKED if must_stop else MATRIX_PRODUCT_FAILURE
                stop_detail = (
                    "blocked-after-ambiguity" if must_stop else "edge-pilot-failed"
                )
                remaining_tail = remaining[offset + 1 :]
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
    finally:
        close = getattr(pinned_app, "close", None)
        if callable(close):
            close()
    return MatrixExecutionResult(exit_code, tuple(completed))


def dry_run(manifest, *, dependencies=None):
    dependencies = dependencies or SystemDependencies()
    cells = plan_cells(manifest, dependencies.is_installed)
    for cell in cells:
        print(cell.identifier)
    return MATRIX_SUCCESS if cells else MATRIX_BLOCKED


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
            return version
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

    def run_driver(self, pinned_app, cell, session, profile_relative_root):
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
            session,
        ]
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
                timeout=75,
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
        manifest = load_manifest(arguments.manifest)
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
