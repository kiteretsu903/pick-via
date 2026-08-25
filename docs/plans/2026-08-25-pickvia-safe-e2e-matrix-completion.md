# PickVia Safe E2E Matrix Completion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `subagent-driven-development` (recommended) or `executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Finish exact, automated non-Safari browser/profile/private E2E coverage with provenance-owned cleanup and truthful per-descriptor capability results.

**Architecture:** First replace final task-root deletion and smoke-app launch with practical exclusive-rename cleanup and exact process ownership. Then add a compile-gated launch-provenance FIFO, task-owned profile grants/custom roots, and explicit per-descriptor capability policy. Only after those gates pass does one sequential matrix runner create isolated profiles, route every eligible cell, reconcile confirmed product failures, and rewrite the authoritative report.

**Tech Stack:** Swift 6, AppKit/NSWorkspace, Darwin process/filesystem APIs, C17 helper compiled with `xcrun clang`, Python 3.14 harness/tests, zsh build/smoke gates, Swift Testing/XCTest.

**Approved spec:** `docs/specs/2026-08-25-pickvia-e2e-safe-matrix-completion-design.md`

---

## File map

- `scripts/browser-e2e/exclusive_cleanup.c`: one native exclusive-rename/verify/remove critical section.
- `scripts/browser-e2e/test_exclusive_cleanup.py`: native helper contract and injected-race tests.
- `scripts/browser-e2e/pickvia_e2e_driver.py`: pinned task root, provenance parser, exact owned-generation cleanup.
- `scripts/browser-e2e/smoke_e2e_runtime.py`: exact E2E app owner and shared native cleanup invocation.
- `scripts/smoke-test-e2e.sh`: bounded non-routing smoke orchestration only.
- `Sources/PickViaCore/Launching/LaunchObservation.swift`: production-neutral PID/mechanism result.
- `Sources/PickViaCore/Launching/BrowserLauncher.swift`: returns launch observations and validates capability policy/custom roots.
- `Sources/PickViaCore/Launching/DuckDuckGoProcessCoordinator.swift`: returns the exact reused/launched managed PID.
- `Sources/PickVia/E2E/E2ELaunchProvenance.swift`: compile-gated sanitized FIFO record/sink.
- `Sources/PickVia/E2E/E2EProfileGrant.swift`: compile-gated manifest validation and grant installation.
- `Sources/PickVia/E2E/E2EControl.swift`: immutable request/provenance/grant controls.
- `Sources/PickVia/App/AppDelegate.swift`: E2E-only composition of grant installer and provenance sink.
- `Sources/PickViaCore/Discovery/ProfileParsers.swift`: Chromium profile directory URLs from the granted root.
- `Sources/PickViaCore/Discovery/BrowserDescriptor.swift`: explicit normal/private/profile/profile-private policy.
- `Sources/PickViaCore/Discovery/BrowserCatalog.swift`: emits only policy-supported targets.
- `scripts/browser-e2e/create_synthetic_profile.py`: isolated Chromium/Firefox profile initialization.
- `scripts/browser-e2e/run_browser_matrix.py`: sequential one-command matrix orchestration.
- `scripts/browser-e2e/browser_matrix_manifest.json`: safe bundle/app/executable/strategy inventory, excluding Safari execution.
- `docs/testing/browser-compatibility-2026-08-21.md`: historical qualification plus one authoritative matrix.

---

### Task 1: Native exclusive cleanup and exact smoke-app ownership

**Files:**

- Create: `scripts/browser-e2e/exclusive_cleanup.c`
- Create: `scripts/browser-e2e/test_exclusive_cleanup.py`
- Modify: `scripts/browser-e2e/pickvia_e2e_driver.py`
- Modify: `scripts/browser-e2e/test_pickvia_e2e_driver.py`
- Modify: `scripts/browser-e2e/smoke_e2e_runtime.py`
- Modify: `scripts/browser-e2e/test_smoke_e2e_runtime.py`
- Modify: `scripts/smoke-test-e2e.sh`
- Modify: `scripts/browser-e2e/test-e2e-build-isolation.sh`

- [ ] **Step 1: Write failing native cleanup tests**

Add tests that compile the helper with `/usr/bin/xcrun clang -std=c17 -Wall -Wextra -Werror`, pass inherited parent/root descriptors, and assert the closed outcomes:

```python
class ExclusiveCleanupTests(unittest.TestCase):
    def test_empty_owned_root_is_exclusively_renamed_and_removed(self):
        with CleanupFixture() as fixture:
            self.assertEqual(fixture.run(), 0)
            self.assertFalse(fixture.root.exists())

    def test_existing_quarantine_destination_is_preserved(self):
        with CleanupFixture(precreate_quarantine=True) as fixture:
            self.assertNotEqual(fixture.run(), 0)
            self.assertTrue(fixture.root.exists())
            self.assertEqual(fixture.quarantine_marker.read_text(), "preserve")

    def test_replacement_after_rename_is_preserved_and_fails_closed(self):
        with CleanupFixture(swap_after_rename=True) as fixture:
            self.assertNotEqual(fixture.run(), 0)
            self.assertEqual(fixture.replacement_marker.read_text(), "replacement")

    def test_identity_mismatch_preserves_both_entries(self):
        with CleanupFixture(expected_inode_delta=1) as fixture:
            self.assertNotEqual(fixture.run(), 0)
            self.assertTrue(fixture.root.exists())

    def test_nonempty_root_is_preserved(self):
        with CleanupFixture(root_file=b"owned") as fixture:
            self.assertNotEqual(fixture.run(), 0)
            self.assertEqual((fixture.root / "owned").read_bytes(), b"owned")

    def test_cross_device_or_uninspectable_state_is_preserved(self):
        with CleanupFixture(force_identity_failure=True) as fixture:
            self.assertNotEqual(fixture.run(), 0)
            self.assertTrue(fixture.root.exists())
```

Run:

```zsh
python3 scripts/browser-e2e/test_exclusive_cleanup.py -v
```

Expected: FAIL because the helper does not exist.

- [ ] **Step 2: Implement the native critical section**

Use a closed numeric exit contract and inherited descriptors only:

```c
enum cleanup_result {
  CLEANUP_OK = 0,
  CLEANUP_USAGE = 64,
  CLEANUP_AMBIGUOUS = 70,
  CLEANUP_NOT_EMPTY = 71
};

int main(int argc, char **argv) {
  // argv: parent_fd root_fd original_name quarantine_name expected_dev expected_ino
  // 1. fstat(root_fd), require expected device/inode, owner, directory, 0700.
  // 2. require the root descriptor contains only "." and "..".
  // 3. renameatx_np(parent_fd, original_name, parent_fd, quarantine_name, RENAME_EXCL).
  // 4. openat(parent_fd, quarantine_name, O_RDONLY|O_DIRECTORY|O_NOFOLLOW),
  //    compare it to root_fd, and require the opened directory to be empty.
  // 5. unlinkat(parent_fd, quarantine_name, AT_REMOVEDIR).
  // 6. require original and quarantine names are absent and root_fd is still empty.
}
```

Do not add restore/overwrite behavior. Any mismatch exits nonzero with both ambiguous names untouched.

- [ ] **Step 3: Integrate the helper with the driver pinned root**

Add a compiler/cache and make `_PinnedTaskRoot.remove()` call the helper only after descriptor-relative scrub plus stable audit:

```python
@dataclasses.dataclass(frozen=True)
class _ExclusiveCleanupResult:
    removed: bool
    outcome: str

def _run_exclusive_cleanup(root: _PinnedTaskRoot, executable: pathlib.Path) -> _ExclusiveCleanupResult:
    completed = subprocess.run(
        [str(executable), str(root.parent_descriptor), str(root.descriptor),
         root.path.name, f".pickvia-final-{secrets.token_hex(16)}",
         str(root.identity.device), str(root.identity.inode)],
        pass_fds=(root.parent_descriptor, root.descriptor),
        env=_FIXED_TOOL_ENVIRONMENT,
        timeout=2,
        check=False,
    )
    return _ExclusiveCleanupResult(completed.returncode == 0, "removed" if completed.returncode == 0 else "ambiguous")
```

Replace the final Python `rmdir` only; retain descriptor-relative child scrubbing and every existing fail-closed test.

- [ ] **Step 4: Move the smoke app under `ExactProcess` ownership**

Add `launch-app` and `finalize-root` commands to `smoke_e2e_runtime.py`. `launch-app` must start the exact executable in a new session, pin PID/start/executable/app manifest, write the PID to a task-owned descriptor, and supervise until the shell requests bounded shutdown. `smoke-test-e2e.sh` must not use `"$executable" &`.

```python
process = ExactProcess.start(
    label="e2e-app",
    arguments=[str(pinned.executable)],
    environment=minimal_app_environment,
    expected_executable=pinned.executable,
)
```

Finalization calls the same native helper and clears `runtime_root` before traps can run again. An ambiguous root is preserved and fails the smoke gate.

- [ ] **Step 5: Run focused and full verification**

```zsh
python3 scripts/browser-e2e/test_exclusive_cleanup.py -v
python3 scripts/browser-e2e/test_smoke_e2e_runtime.py -v
python3 scripts/browser-e2e/test_pickvia_e2e_driver.py -v
zsh scripts/browser-e2e/test-e2e-build-isolation.sh
zsh scripts/smoke-test-e2e.sh "build-e2e/PickVia E2E.app"
git diff --check
```

Expected: all tests pass; no `pickvia-e2e-*`, quarantine, smoke process, or preference residue.

- [ ] **Step 6: Commit and obtain two reviews**

```zsh
git add scripts/browser-e2e/exclusive_cleanup.c \
  scripts/browser-e2e/test_exclusive_cleanup.py \
  scripts/browser-e2e/pickvia_e2e_driver.py \
  scripts/browser-e2e/test_pickvia_e2e_driver.py \
  scripts/browser-e2e/smoke_e2e_runtime.py \
  scripts/browser-e2e/test_smoke_e2e_runtime.py \
  scripts/browser-e2e/test-e2e-build-isolation.sh \
  scripts/smoke-test-e2e.sh
git commit -m "fix: finalize E2E roots with exclusive rename"
```

Run a fresh spec review and security-quality review. Critical/Important findings require a new RED test and follow-up commit.

---

### Task 2: Production-neutral launch observations

**Files:**

- Create: `Sources/PickViaCore/Launching/LaunchObservation.swift`
- Modify: `Sources/PickViaCore/Launching/BrowserLauncher.swift`
- Modify: `Sources/PickViaCore/Launching/DuckDuckGoProcessCoordinator.swift`
- Modify: `Sources/PickViaCore/Launching/DuckDuckGoSystemAdapters.swift`
- Modify: `Tests/PickViaCoreTests/BrowserLauncherTests.swift`
- Modify: `Tests/PickViaCoreTests/DuckDuckGoProcessCoordinatorTests.swift`

- [ ] **Step 1: Write failing adapter/launcher tests**

Cover direct `Process`, `NSWorkspace`, DuckDuckGo new launch, DuckDuckGo reuse, and missing PID:

```swift
@Test func directExecutionReturnsExactChildPID() async throws {
  let runner = ProcessRunnerSpy(processIdentifier: 4101)
  let launcher = launcher(processRunner: runner)
  let result = try await launcher.execute(.executable(application: executable, arguments: []))
  #expect(result == BrowserLaunchObservation(processIdentifier: 4101, mechanism: .process))
}

@Test func workspaceExecutionReturnsCompletionApplicationPID() async throws {
  let workspace = WorkspaceSpy(processIdentifier: 4102)
  let result = try await launcher(workspace: workspace).execute(
    .workspace(application: application, url: route))
  #expect(result == BrowserLaunchObservation(processIdentifier: 4102, mechanism: .workspace))
}

@Test func duckDuckGoFireReturnsManagedPID() async throws {
  let router = DuckDuckGoRouterSpy(processIdentifier: 4103)
  let result = try await launcher(duckDuckGo: router).execute(
    .duckDuckGo(application: application, url: route, mode: .private))
  #expect(result == BrowserLaunchObservation(processIdentifier: 4103, mechanism: .duckDuckGo))
}

@Test func zeroOrMissingPIDFailsLaunchObservation() async {
  await #expect(throws: LaunchFailure.self) {
    try await launcher(processRunner: ProcessRunnerSpy(processIdentifier: 0)).execute(
      .executable(application: executable, arguments: []))
  }
}
```

Run:

```zsh
swift test --disable-sandbox --filter BrowserLauncherTests -Xswiftc -warnings-as-errors
swift test --disable-sandbox --filter DuckDuckGoProcessCoordinatorTests -Xswiftc -warnings-as-errors
```

Expected: FAIL because launch APIs return `Void`.

- [ ] **Step 2: Add the production-neutral observation types**

```swift
public enum BrowserLaunchMechanism: Equatable, Sendable {
  case process
  case workspace
  case duckDuckGo
}

public struct BrowserLaunchObservation: Equatable, Sendable {
  public let processIdentifier: Int32
  public let mechanism: BrowserLaunchMechanism
}
```

Change `ProcessRunning.run`, `WorkspaceOpening.open`, and `DuckDuckGoRouting.open` to return an observation. `SystemProcessRunner` returns `process.processIdentifier`; `SystemWorkspace` requires exactly one completion application matching the requested bundle path; DuckDuckGo returns the exact managed/reused PID already established by its state machine.

- [ ] **Step 3: Make launcher execution return the observation**

```swift
public func execute(_ plan: LaunchPlan) async throws -> BrowserLaunchObservation

public func launch(
  url: URL,
  application: BrowserApplication,
  target: BrowserTarget
) async throws -> BrowserLaunchObservation
```

`RouteLauncher` discards the observation in ordinary composition. No E2E strings or conditionals belong in this task.

- [ ] **Step 4: Verify normal behavior and commit**

```zsh
swift test --disable-sandbox --filter BrowserLauncherTests -Xswiftc -warnings-as-errors
swift test --disable-sandbox --filter DuckDuckGoProcessCoordinatorTests -Xswiftc -warnings-as-errors
swift test --disable-sandbox -Xswiftc -warnings-as-errors
xcrun swift-format lint --recursive Sources Tests
git diff --check
```

```zsh
git add Sources/PickViaCore/Launching/LaunchObservation.swift \
  Sources/PickViaCore/Launching/BrowserLauncher.swift \
  Sources/PickViaCore/Launching/DuckDuckGoProcessCoordinator.swift \
  Sources/PickViaCore/Launching/DuckDuckGoSystemAdapters.swift \
  Tests/PickViaCoreTests/BrowserLauncherTests.swift \
  Tests/PickViaCoreTests/DuckDuckGoProcessCoordinatorTests.swift
git commit -m "refactor: return exact browser launch observations"
```

Obtain fresh spec and quality reviews before Task 3.

---

### Task 3: Compile-gated provenance FIFO and provenance-owned cleanup

**Files:**

- Create: `Sources/PickVia/E2E/E2ELaunchProvenance.swift`
- Create: `Tests/PickViaTests/E2ELaunchProvenanceTests.swift`
- Modify: `Sources/PickVia/E2E/E2EControl.swift`
- Modify: `Sources/PickVia/App/AppDelegate.swift`
- Modify: `Sources/PickViaCore/Launching/BrowserLauncher.swift`
- Modify: `Tests/PickViaTests/E2EControlTests.swift`
- Modify: `Tests/PickViaTests/AppDelegateTests.swift`
- Modify: `Tests/PickViaCoreTests/BrowserLauncherTests.swift`
- Modify: `scripts/browser-e2e/pickvia_e2e_driver.py`
- Modify: `scripts/browser-e2e/test_pickvia_e2e_driver.py`
- Modify: `scripts/browser-e2e/test-e2e-build-isolation.sh`

- [ ] **Step 1: Write failing Swift provenance tests**

Require a closed record and no sensitive fields:

```swift
enum E2ELaunchProvenanceOutcome: String, Codable { case launchObserved, launchUnproven, launchError }

struct E2ELaunchProvenanceRecord: Codable, Equatable {
  let session: String
  let request: String
  let targetID: String
  let bundleIdentifier: String
  let mode: BrowserMode
  let mechanism: String
  let processIdentifier: Int32?
  let outcome: E2ELaunchProvenanceOutcome
}
```

Tests must reject invalid nonces, PID `<= 0`, duplicate records, oversized output, non-FIFO paths, FIFO replacement, and any JSON key for URL, arguments, label, path, or error text.

- [ ] **Step 2: Extend immutable E2E controls**

Add and validate:

```swift
static let requestNonceKey = "PICKVIA_E2E_REQUEST_NONCE"
static let provenanceFIFOKey = "PICKVIA_E2E_PROVENANCE_FIFO"
```

The provenance FIFO must be a task-owned sibling of the status FIFO beneath the validated support root. Update normal-binary isolation scans for both literals and all new E2E type names.

- [ ] **Step 3: Inject the compile-gated sink**

Under `PICKVIA_E2E_AUTOMATION`, add a sink parameter to `BrowserLauncher`. After production `launch` returns, emit `launchObserved`; on a zero/missing PID emit `launchUnproven`; on launch failure emit `launchError` and rethrow the existing sanitized failure. Normal initializers and binaries must not reference the sink.

- [ ] **Step 4: Write failing driver provenance/ownership tests**

Add cases for direct/workspace/DuckDuckGo observations, wrong session/request/target/bundle/mode, duplicate record, receipt without provenance, temporal-only browser, provenance PID reuse, replacement generation, and multiple generations.

```python
def test_receipt_and_browser_identity_without_provenance_is_harness_failure(self):
    with DriverFixture(delivers_provenance=False) as fixture:
        result = fixture.run()
        self.assertEqual(result.exit_code, driver.DRIVER_PROVENANCE_FAILURE)
        self.assertTrue(result.report["token_received"])
        self.assertTrue(result.report["exact_browser_process_identity"])

def test_only_provenance_generation_can_be_terminated(self):
    with DriverFixture(provenance_pid=7201, temporal_browser_pids=(7201, 7202)) as fixture:
        fixture.run()
        self.assertEqual(fixture.terminated_browser_pids, [7201])

def test_temporal_replacement_is_never_signaled(self):
    with DriverFixture(provenance_pid=7301, replacement_browser_pid=7302) as fixture:
        result = fixture.run()
        self.assertEqual(result.exit_code, driver.DRIVER_BROWSER_IDENTITY_AMBIGUOUS)
        self.assertNotIn(7302, fixture.terminated_browser_pids)
```

Expected RED: the current driver treats temporal appearance as ownership.

- [ ] **Step 5: Make the driver require provenance**

Create/open a second FIFO descriptor, parse exactly one bounded record, and resolve it immediately to `_ProcessIdentity(pid, start, executable)`. Replace temporal ownership assignment with:

```python
owned_browsers = {provenance_identity} if provenance_identity is not None else set()
```

Authoritative snapshots remain required for ambiguity/quiescence, but never grant cleanup authority. Missing/invalid provenance exits with a harness code and preserves factual receipt/browser booleans.

- [ ] **Step 6: Verify binary isolation, full suites, and commit**

```zsh
swift test --disable-sandbox -Xswiftc -warnings-as-errors
swift test --disable-sandbox -Xswiftc -DPICKVIA_E2E_AUTOMATION -Xswiftc -warnings-as-errors
python3 scripts/browser-e2e/test_pickvia_e2e_driver.py -v
zsh scripts/browser-e2e/test-e2e-build-isolation.sh
xcrun swift-format lint --recursive Sources Tests
git diff --check
```

```zsh
git add Sources/PickVia/E2E/E2ELaunchProvenance.swift \
  Tests/PickViaTests/E2ELaunchProvenanceTests.swift \
  Sources/PickVia/E2E/E2EControl.swift Sources/PickVia/App/AppDelegate.swift \
  Sources/PickViaCore/Launching/BrowserLauncher.swift \
  Tests/PickViaTests/E2EControlTests.swift Tests/PickViaTests/AppDelegateTests.swift \
  Tests/PickViaCoreTests/BrowserLauncherTests.swift \
  scripts/browser-e2e/pickvia_e2e_driver.py \
  scripts/browser-e2e/test_pickvia_e2e_driver.py \
  scripts/browser-e2e/test-e2e-build-isolation.sh
git commit -m "feat: prove E2E browser launch provenance"
```

Obtain fresh spec and quality reviews.

---

### Task 4: Task-owned profile grant manifest

**Files:**

- Create: `Sources/PickVia/E2E/E2EProfileGrant.swift`
- Create: `Tests/PickViaTests/E2EProfileGrantTests.swift`
- Modify: `Sources/PickVia/E2E/E2EControl.swift`
- Modify: `Sources/PickVia/App/AppDelegate.swift`
- Modify: `Tests/PickViaTests/E2EControlTests.swift`
- Modify: `Tests/PickViaTests/AppDelegateTests.swift`
- Modify: `scripts/browser-e2e/pickvia_e2e_driver.py`
- Modify: `scripts/browser-e2e/test_pickvia_e2e_driver.py`

- [ ] **Step 1: Write failing manifest validation tests**

Use a versioned manifest with a relative root only:

```swift
struct E2EProfileGrantManifest: Codable, Equatable {
  let schemaVersion: Int
  let bundleIdentifier: String
  let strategy: String
  let relativeRoot: String
}
```

Cover physical in-root Chromium/Firefox roots, wrong bundle/strategy, absolute/traversal paths, symlinks, permissive mode, wrong owner, missing/wrong marker, zero/two profiles, malformed JSON, stale bookmark, and a conventional-home path.

- [ ] **Step 2: Implement the compile-gated installer**

`E2EProfileGrantInstaller.installIfPresent` must run before `BrowserCatalog` construction:

```swift
static func installIfPresent(
  control: E2EControl,
  descriptors: [BrowserDescriptor],
  coordinator: any ProfileAccessManaging
) throws
```

Resolve `relativeRoot` beneath the physical support root, validate the exact descriptor marker and one synthetic profile, then call `coordinator.installGrant(root:for:)`. Require `.persistent` or `.currentSessionOnly` to be visible through `beginAccess` immediately. Never open `NSOpenPanel` in E2E.

- [ ] **Step 3: Extend driver controls without leaking paths**

Add an optional manifest path fixed beneath the task root. The driver writes only bundle ID, strategy, and relative root; reports/status/provenance never emit it. Audit rejects the routed URL as before.

- [ ] **Step 4: Verify isolation and commit**

```zsh
swift test --disable-sandbox --filter E2EProfileGrantTests -Xswiftc -DPICKVIA_E2E_AUTOMATION -Xswiftc -warnings-as-errors
swift test --disable-sandbox --filter AppCompositionTests -Xswiftc -DPICKVIA_E2E_AUTOMATION -Xswiftc -warnings-as-errors
python3 scripts/browser-e2e/test_pickvia_e2e_driver.py -v
zsh scripts/browser-e2e/test-e2e-build-isolation.sh
git diff --check
```

```zsh
git add Sources/PickVia/E2E/E2EProfileGrant.swift \
  Tests/PickViaTests/E2EProfileGrantTests.swift \
  Sources/PickVia/E2E/E2EControl.swift Sources/PickVia/App/AppDelegate.swift \
  Tests/PickViaTests/E2EControlTests.swift Tests/PickViaTests/AppDelegateTests.swift \
  scripts/browser-e2e/pickvia_e2e_driver.py scripts/browser-e2e/test_pickvia_e2e_driver.py
git commit -m "feat: install isolated E2E profile grants"
```

Obtain fresh spec and quality reviews.

---

### Task 5: Custom-root profile routing and synthetic profile creator

**Files:**

- Modify: `Sources/PickViaCore/Discovery/ProfileParsers.swift`
- Modify: `Sources/PickViaCore/Discovery/BrowserCatalog.swift`
- Modify: `Sources/PickViaCore/Launching/BrowserLauncher.swift`
- Modify: `Tests/PickViaCoreTests/ProfileParserTests.swift`
- Modify: `Tests/PickViaCoreTests/BrowserCatalogTests.swift`
- Modify: `Tests/PickViaCoreTests/BrowserLauncherTests.swift`
- Create: `scripts/browser-e2e/create_synthetic_profile.py`
- Create: `scripts/browser-e2e/test_create_synthetic_profile.py`

- [ ] **Step 1: Write failing Chromium custom-root tests**

Add `ChromiumProfileParser.parse(data:baseDirectory:)` and require each profile directory to be `baseDirectory/<identifier>`. BrowserCatalog must carry that transient physical path into `profileLaunchPath`.

Launcher tests require:

```swift
#expect(arguments == [
  "--user-data-dir=/private/tmp/pickvia-e2e-test/profiles/chrome",
  "--profile-directory=PickVia E2E",
  url.absoluteString,
])
```

Reject a nonabsolute root, root/profile symlink, profile not a direct child, identifier/leaf mismatch, missing `Local State`, and persisted/config-injected `profileLaunchPath`.

- [ ] **Step 2: Implement Chromium root derivation and validation**

For Chromium only, derive `root = profileLaunchPath.deletingLastPathComponent()`, require `profileIdentifier == profileURL.lastPathComponent`, require a physical direct-child directory and physical `Local State`, then prepend `--user-data-dir=<root>` before the existing profile/private arguments. Firefox retains its exact validated `-profile` path.

- [ ] **Step 3: Write failing creator tests with fake browsers**

```python
def test_chromium_creator_uses_isolated_user_data_and_one_profile(self):
    with SyntheticProfileFixture(strategy="chromium") as fixture:
        result = fixture.run()
        self.assertEqual(result.returncode, 0)
        self.assertEqual(fixture.chromium_info_cache(), {"PickVia E2E": "PickVia E2E"})

def test_firefox_creator_uses_create_profile_and_one_profiles_ini_entry(self):
    with SyntheticProfileFixture(strategy="firefox") as fixture:
        result = fixture.run()
        self.assertEqual(result.returncode, 0)
        self.assertEqual(fixture.firefox_profile_names(), ["PickVia E2E"])

def test_creator_rejects_existing_nonempty_or_symlink_root(self):
    for unsafe_kind in ("nonempty", "symlink"):
        with self.subTest(unsafe_kind=unsafe_kind), SyntheticProfileFixture(
            unsafe_root=unsafe_kind
        ) as fixture:
            self.assertNotEqual(fixture.run().returncode, 0)

def test_creator_terminates_only_exact_generation(self):
    with SyntheticProfileFixture(preexisting_pid=7401) as fixture:
        fixture.run()
        self.assertNotIn(7401, fixture.signaled_pids)
        self.assertEqual(fixture.signaled_pids, [fixture.created_pid])

def test_creator_never_emits_profile_path_or_label(self):
    with SyntheticProfileFixture(strategy="chromium") as fixture:
        result = fixture.run()
        self.assertNotIn(str(fixture.root).encode(), result.stdout + result.stderr)
        self.assertNotIn(b"PickVia E2E", result.stdout + result.stderr)
```

- [ ] **Step 4: Implement isolated profile creation**

The CLI accepts explicit app/executable/bundle/strategy/root arguments from the matrix runner. Chromium launches with an isolated `--user-data-dir`, `--profile-directory=PickVia E2E`, no-first-run/default/sync/background flags, and `about:blank`; after exact shutdown it normalizes only the task-owned `Local State` entry to the display name `PickVia E2E`. Firefox uses `-CreateProfile` against the task root and writes/validates one bounded `profiles.ini`. All child environments are allowlisted and every signal revalidates PID/start/executable.

- [ ] **Step 5: Verify and commit**

```zsh
swift test --disable-sandbox --filter ProfileParserTests -Xswiftc -warnings-as-errors
swift test --disable-sandbox --filter BrowserCatalogTests -Xswiftc -warnings-as-errors
swift test --disable-sandbox --filter BrowserLauncherTests -Xswiftc -warnings-as-errors
python3 scripts/browser-e2e/test_create_synthetic_profile.py -v
python3 scripts/browser-e2e/test_pickvia_e2e_driver.py -v
xcrun swift-format lint --recursive Sources Tests
git diff --check
```

```zsh
git add Sources/PickViaCore/Discovery/ProfileParsers.swift \
  Sources/PickViaCore/Discovery/BrowserCatalog.swift \
  Sources/PickViaCore/Launching/BrowserLauncher.swift \
  Tests/PickViaCoreTests/ProfileParserTests.swift \
  Tests/PickViaCoreTests/BrowserCatalogTests.swift \
  Tests/PickViaCoreTests/BrowserLauncherTests.swift \
  scripts/browser-e2e/create_synthetic_profile.py \
  scripts/browser-e2e/test_create_synthetic_profile.py
git commit -m "feat: route isolated browser profile roots"
```

Obtain fresh spec and quality reviews. Do not create a real profile in this task.

---

### Task 6: Per-descriptor capability policy

**Files:**

- Modify: `Sources/PickViaCore/Discovery/BrowserDescriptor.swift`
- Modify: `Sources/PickViaCore/Discovery/BrowserCatalog.swift`
- Modify: `Sources/PickViaCore/Launching/BrowserLauncher.swift`
- Modify: `Tests/PickViaCoreTests/BrowserDescriptorTests.swift`
- Modify: `Tests/PickViaCoreTests/BrowserCatalogTests.swift`
- Modify: `Tests/PickViaCoreTests/BrowserLauncherTests.swift`

- [ ] **Step 1: Write failing policy tests**

Add exact combinations for unsupported/workspace/executable normal, browser private,
profile, and profile-private:

```swift
public enum BrowserNormalStrategy: Equatable, Sendable {
  case unsupported
  case workspace
  case executable
}

public struct BrowserRouteCapabilityPolicy: Equatable, Sendable {
  public let normal: BrowserNormalStrategy
  public let browserPrivate: Bool
  public let profile: Bool
  public let profilePrivate: Bool
}
```

Tests must prove Catalog emits no unsupported target, profile-private is enabled only when declared, and Launcher refuses every plan that policy does not advertise.

- [ ] **Step 2: Implement policy without changing current advertised support**

Add the policy to every descriptor. Initial values preserve current product behavior; historical privacy-invalid E2E failures must not remove support. For Chromium descriptors initial normal remains `.workspace`, browser-private and profile follow the existing strategies, and profile-private starts `false` because those detected targets are currently disabled. Safari product normal support remains `.workspace`, although the E2E runner will skip it.

`BrowserCatalog.targetCandidates` must independently gate browser normal, browser private, profile normal, and profile private. `BrowserLauncher.makePlan` selects workspace or direct executable normal from `policy.normal` and checks the exact policy before argument construction.

- [ ] **Step 3: Verify and commit**

```zsh
swift test --disable-sandbox --filter BrowserDescriptorTests -Xswiftc -warnings-as-errors
swift test --disable-sandbox --filter BrowserCatalogTests -Xswiftc -warnings-as-errors
swift test --disable-sandbox --filter BrowserLauncherTests -Xswiftc -warnings-as-errors
swift test --disable-sandbox -Xswiftc -warnings-as-errors
xcrun swift-format lint --recursive Sources Tests
git diff --check
```

```zsh
git add Sources/PickViaCore/Discovery/BrowserDescriptor.swift \
  Sources/PickViaCore/Discovery/BrowserCatalog.swift \
  Sources/PickViaCore/Launching/BrowserLauncher.swift \
  Tests/PickViaCoreTests/BrowserDescriptorTests.swift \
  Tests/PickViaCoreTests/BrowserCatalogTests.swift \
  Tests/PickViaCoreTests/BrowserLauncherTests.swift
git commit -m "feat: gate exact browser route capabilities"
```

Obtain fresh spec and quality reviews.

---

### Task 7: One-command sequential browser matrix runner

**Files:**

- Create: `scripts/browser-e2e/browser_matrix_manifest.json`
- Create: `scripts/browser-e2e/run_browser_matrix.py`
- Create: `scripts/browser-e2e/test_run_browser_matrix.py`
- Modify: `scripts/browser-e2e/pickvia_e2e_driver.py`
- Modify: `scripts/browser-e2e/test-e2e-build-isolation.sh`

- [ ] **Step 1: Write failing manifest and orchestration tests**

The versioned manifest contains only safe static identity/strategy data:

```json
{
  "schemaVersion": 1,
  "applications": [
    {
      "bundleIdentifier": "com.microsoft.edgemac",
      "applicationPath": "/Applications/Microsoft Edge.app",
      "executableRelativePath": "Contents/MacOS/Microsoft Edge",
      "profileStrategy": "chromium",
      "skip": false
    },
    {
      "bundleIdentifier": "com.apple.Safari",
      "applicationPath": "/Applications/Safari.app",
      "profileStrategy": "none",
      "skip": true
    }
  ]
}
```

Tests cover schema/duplicate/path validation, Safari forced skip, signature blocker, cold/running/reopen sequencing, fresh nonce/token per cell, stop-on-ambiguity, profile root lifecycle, sanitized JSONL evidence, resume from completed cells, and no parallel browsers.

- [ ] **Step 2: Implement the runner**

`run_browser_matrix.py` must:

1. validate strict signatures and exact app/executable/bundle identity;
2. build/pin `PickVia E2E.app` once;
3. run the Edge Stable three-state pilot and stop if it fails;
4. create one isolated profile root only for advertised profile cells;
5. invoke the driver sequentially with fresh status/provenance FIFOs and nonces;
6. store only sanitized JSONL cell evidence under a task-owned run directory;
7. classify only `PASS`, `FAIL`, `UNSUPPORTED`, or `NOT RUN`;
8. finalize every root through Task 1; and
9. resume only after validating the prior run manifest and exact completed-cell hashes.

No runner code may invoke Computer Use. Visual observations remain a separate sanitized boolean attachment when the specific app observer is reliable; their absence never converts harness evidence into product failure.

- [ ] **Step 3: Add a dry-run gate and commit**

```zsh
python3 scripts/browser-e2e/test_run_browser_matrix.py -v
python3 scripts/browser-e2e/run_browser_matrix.py \
  --manifest scripts/browser-e2e/browser_matrix_manifest.json \
  --dry-run
zsh scripts/browser-e2e/test-e2e-build-isolation.sh
git diff --check
```

Expected: dry run lists every installed eligible non-Safari cell and no process/app/root mutation occurs.

```zsh
git add scripts/browser-e2e/browser_matrix_manifest.json \
  scripts/browser-e2e/run_browser_matrix.py \
  scripts/browser-e2e/test_run_browser_matrix.py \
  scripts/browser-e2e/pickvia_e2e_driver.py \
  scripts/browser-e2e/test-e2e-build-isolation.sh
git commit -m "test: automate the installed browser matrix"
```

Obtain fresh spec and security-quality reviews before any real matrix run.

---

### Task 8: Fresh matrix, capability reconciliation, report, and final review

**Files:**

- Modify conditionally: `Sources/PickViaCore/Discovery/BrowserDescriptor.swift`
- Modify conditionally: `Tests/PickViaCoreTests/BrowserDescriptorTests.swift`
- Modify: `docs/testing/browser-compatibility-2026-08-21.md`

- [ ] **Step 1: Run the Edge pilot and full eligible matrix**

Use the pinned feature worktree and exact installed apps:

```zsh
python3 scripts/browser-e2e/run_browser_matrix.py \
  --manifest scripts/browser-e2e/browser_matrix_manifest.json \
  --output /private/tmp/pickvia-e2e-matrix-20260825
```

Run sequentially. Preserve preexisting user browser generations. Do not run Safari/STP, unsigned/invalid-signature applications, or Chromium. Do not inspect conventional profile roots.

- [ ] **Step 2: Reconcile only confirmed product failures**

For a capability that fails after `selected` plus exact launch provenance in every required state, run one bounded direct diagnostic. If an alternate existing product strategy succeeds, change only that descriptor policy/normal strategy and add a failing test first. If production and direct diagnostics both fail, mark the exact capability unsupported. Harness/signature/observer failures remain `NOT RUN` and do not change descriptors.

For each descriptor change:

```zsh
swift test --disable-sandbox --filter BrowserDescriptorTests -Xswiftc -warnings-as-errors
swift test --disable-sandbox --filter BrowserCatalogTests -Xswiftc -warnings-as-errors
swift test --disable-sandbox --filter BrowserLauncherTests -Xswiftc -warnings-as-errors
git add Sources/PickViaCore/Discovery/BrowserDescriptor.swift \
  Tests/PickViaCoreTests/BrowserDescriptorTests.swift \
  Tests/PickViaCoreTests/BrowserCatalogTests.swift \
  Tests/PickViaCoreTests/BrowserLauncherTests.swift
git commit -m "fix: reconcile confirmed browser capabilities"
```

Rerun every changed descriptor through all advertised states.

- [ ] **Step 3: Rewrite the authoritative report section**

Keep historical ledgers but label all pre-isolation browser evidence diagnostic-only. Add one canonical row per descriptor/capability with primary result, harness/product detail, version, bundle, strategy, cold/running/reopen results, provenance, receipt, sanitized visual booleans, total elapsed, route timeout, five-second cleanup grace, two-second quiescence, and cleanup outcome. Mark Safari/STP skipped by user decision.

- [ ] **Step 4: Run final automated gates**

```zsh
swift test --disable-sandbox -Xswiftc -warnings-as-errors
swift test --disable-sandbox -Xswiftc -DPICKVIA_E2E_AUTOMATION -Xswiftc -warnings-as-errors
python3 scripts/browser-e2e/test_exclusive_cleanup.py -v
python3 scripts/browser-e2e/test_localhost_probe.py -v
python3 scripts/browser-e2e/test_pickvia_e2e_driver.py -v
python3 scripts/browser-e2e/test_smoke_e2e_runtime.py -v
python3 scripts/browser-e2e/test_create_synthetic_profile.py -v
python3 scripts/browser-e2e/test_run_browser_matrix.py -v
zsh scripts/browser-e2e/test-e2e-build-isolation.sh
zsh scripts/smoke-test-e2e.sh "build-e2e/PickVia E2E.app"
xcrun swift-format lint --recursive Sources Tests
git diff --check
git status --short
```

Expected: zero failures/warnings; no E2E app/helper/receiver/browser process, FIFO, task root, quarantine, profile root, real E2E preference artifact, or unreviewed file remains.

- [ ] **Step 5: Commit the report and obtain final cross-task reviews**

```zsh
git add docs/testing/browser-compatibility-2026-08-21.md
git commit -m "test: record provenance-backed browser matrix"
```

Run two fresh read-only reviews across every commit since `49e7279`:

1. spec review against both E2E design documents;
2. code/security-quality review covering normal-binary absence, URL/environment privacy,
   exact provenance, same-user threat-model boundary, profile isolation, capability truth,
   process/root cleanup, report classification, and worktree scope.

Fix every Critical/Important finding with a new RED/GREEN commit and re-review. Do not merge,
push, release, publish, install PickVia, delete ambiguous browser state, or remove task-created
profiles until the final report has been accepted.

---

## Plan self-review checklist

- Every approved design section maps to at least one task.
- Cleanup/provenance/profile/capability changes land before real routes.
- Each production change starts with a failing test and ends with focused/full gates.
- Normal-binary isolation is rechecked after every compile-gated feature.
- Safari/STP are skipped only in E2E; their product descriptor is not removed.
- Existing profiles and preexisting browser generations are never cleanup targets.
- Harness failures never alter product capability policy.
- No step authorizes merge, push, release, publication, app replacement, or ambiguous deletion.
