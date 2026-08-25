# PickVia Safe Browser-Matrix Completion Design

## Status

Approved in principle by the user on 2026-08-25 as option 1. This written design is the
review gate before implementation planning. It amends the cleanup, process-ownership,
profile, capability, and matrix sections of
`docs/specs/2026-08-22-pickvia-e2e-automation-design.md`; all other isolation and privacy
requirements in that design remain in force.

## Goal

Complete automated, truthful end-to-end coverage for PickVia's installed non-Safari
browsers, including browser-level normal/private routing and exact task-created profiles,
without inspecting existing browser profiles or terminating browser processes that
PickVia did not prove it launched.

## Approved threat model

The harness protects against accidental or stale state, symlinks and hard links,
path replacement, PID reuse, unknown process generations, inherited secrets, malformed
controls, and ordinary concurrent application activity. Every ambiguity fails closed.

The user approved a practical same-user boundary: an actively malicious process running
as the same macOS user and racing the final native filesystem syscall after all identity
checks is out of scope. The implementation must still minimize that interval with one
native critical section and must never describe the result as an inode-conditional delete.
No privileged helper or different-UID service will be added.

## Non-goals

- Safari and Safari Technology Preview routing, profiles, and private windows remain
  skipped by user decision.
- No browser extension, Shortcut, AppleScript, System Events, Accessibility automation,
  or general remote-control interface will be added.
- Existing user browser profiles will not be enumerated, copied, renamed, or used for
  E2E evidence.
- Existing browser applications with invalid strict signatures will not be modified or
  reinstalled automatically.
- This work does not publish, release, merge, push, or replace `/Applications/PickVia.app`.

## Architecture

Implementation is divided into four independently testable units, completed in order:

1. practical exclusive-rename cleanup and exact smoke-app ownership;
2. compile-gated browser launch provenance;
3. task-owned profile roots and PickVia-owned grants; and
4. per-descriptor capability gating followed by a fresh browser matrix.

No real browser route runs until units 1 through 3 pass their unit, privacy, binary
isolation, process, and cleanup gates.

## Practical exclusive-rename cleanup

The driver continues to create a random `0700` task root under `/private/tmp`, open it
with `O_DIRECTORY | O_NOFOLLOW`, and pin its device, inode, owner, and mode. All FIFO,
audit, and recursive content operations remain descriptor-relative.

After every writer and exact owned process has stopped, the finalizer:

1. requires a stable, bounded, two-pass empty-tree audit;
2. uses a small Darwin-native helper to rename the public task-root entry to a new random
   quarantine name with `renameatx_np(..., RENAME_EXCL)` relative to a pinned
   `/private/tmp` descriptor;
3. immediately verifies that the quarantine entry still matches the held root descriptor
   and is empty;
4. removes that empty quarantine entry inside the same native critical section; and
5. reports cleanup success only when the original public name and quarantine name are
   absent and the held descriptor identifies an unlinked, empty directory.

Any destination collision, identity change, unexpected entry, cross-device child,
unknown syscall result, or post-operation mismatch preserves the ambiguous entry and
returns `cleanup-error`. The normal path leaves no empty task-root residue. Tests inject
replacement entries at every hook surrounding rename, verification, and removal.

The smoke gate moves its app launch into the exact-generation Python process owner. It no
longer launches the app as an unowned shell child. TERM/KILL remains bounded, validates
PID start generation and executable identity before every signal, and requires the entire
owned process group to disappear before task-root finalization.

## Compile-gated launch provenance

Normal PickVia builds keep the existing public routing interfaces and contain no E2E
provenance marker, environment key, status case, or sink type. Under
`PICKVIA_E2E_AUTOMATION`, application composition injects an `E2ELaunchProvenanceSink`
into `BrowserLauncher` and `DuckDuckGoProcessCoordinator`.

For each selected request, the sink emits one bounded sanitized record after the actual
launch/open operation returns:

- opaque E2E session and request nonces;
- canonical target ID and expected bundle identifier;
- route mode and launch mechanism (`process`, `workspace`, or `duckduckgo`);
- the returned process identifier; and
- a closed outcome: `launch-observed`, `launch-unproven`, or `launch-error`.

The record never contains the routed URL, browser arguments, profile label, profile path,
arbitrary error text, or environment values. It travels over a separate task-owned FIFO;
it is not written to the compatibility report or regular task-root files.

`SystemProcessRunner` returns the child PID from the launched `Process`.
`SystemWorkspace` returns the exact `NSRunningApplication.processIdentifier` supplied by
the `NSWorkspace` completion handler. DuckDuckGo routing returns the PID of the exact
reused or newly managed application generation. A missing, zero, ambiguous, or mismatched
PID produces `launch-unproven`, which is a harness result rather than a product failure.

The driver immediately resolves the reported PID through Darwin process inspection and
pins PID, start generation, executable, expected bundle, and target. It may signal only
that provenance-observed generation. A later replacement, helper process, second browser
generation, or process found only by temporal appearance is observation-only and remains
untouched. Receipt and visible evidence can never upgrade an unproven launch to PASS.

## Task-owned profile roots and grants

Every profile E2E cell uses a new root beneath the pinned task root. No bookmark points to
the user's conventional browser data directory.

For Chromium-family editions, the harness initializes an isolated user-data root with one
profile whose only test-facing display name is `PickVia E2E`. The root contains a
task-created `Local State`; the parser therefore cannot encounter existing profiles. For
Firefox editions, the harness initializes one isolated profile and a task-created
`profiles.ini` that refers only to that directory.

Before `BrowserCatalog` loads, the E2E composition validates a task-owned grant manifest
and installs the exact root through the production `ProfileAccessCoordinator`. Validation
requires:

- an absolute physical root beneath the pinned task root;
- exact owner and restrictive mode;
- the descriptor's expected marker file;
- exactly one supported synthetic profile; and
- a bundle identifier and profile strategy matching the immutable E2E control.

The isolated `JSONProfileAccessStore` owns any resulting bookmark. Stale, session-only,
wrong-root, extra-profile, symlinked, or malformed grants fail closed. The production
Settings picker remains unchanged; the compile-gated E2E path automates the same grant
coordinator without an interactive panel.

Chromium targets already carry the discovered profile directory path. For a granted root,
`BrowserLauncher` derives and validates the user-data root from that path, then launches
with both the descriptor's profile selector argument and an explicit
`--user-data-dir=<granted-root>` argument. The profile directory must be a direct physical
child of the granted root. Firefox continues to use its exact validated `-profile` path.
This makes custom granted roots functional in normal PickVia as well as isolated in E2E.

Profile creation and routing are separate phases. The creator process is exact-generation
owned and fully stopped before PickVia discovery begins. Only opaque target IDs and
booleans enter logs and reports; filesystem paths and profile labels do not.

## Per-descriptor capability gating

Browser support is modeled per descriptor and per capability instead of inferred from a
single family-wide strategy. Each descriptor declares:

- browser-level normal availability and launch strategy;
- browser-level private availability and launch strategy;
- profile availability and profile launch strategy; and
- profile-private availability.

The catalog creates a target only when that exact capability is declared. The launcher
validates the same declaration before producing a plan. A Chromium-family descriptor may
therefore use workspace normal routing, direct-executable normal routing, or mark normal
unsupported without changing another edition.

Capability reconciliation uses only fresh runs completed after launch provenance and
profile isolation land. A capability is removed or marked unsupported only after the
production route was selected, its exact launch was proven, all required cold/running/
reopen states failed consistently, and direct diagnostics confirmed the product strategy
failure. Harness errors remain `NOT RUN` and never remove a capability.

## Fresh matrix protocol

All historical browser cells gathered before E2E home isolation and launch provenance
are retained only as diagnostic history. They are not current compatibility evidence.

The new matrix runs sequentially because browsers share desktop and process state:

1. rebuild and pin `PickVia E2E.app`;
2. rerun the Edge Stable normal cold/running/reopen pilot;
3. create isolated synthetic roots for each advertised profile capability;
4. run every installed, strictly valid, non-Safari normal capability;
5. run every advertised browser-private, profile, and profile-private capability;
6. reconcile descriptor capabilities from confirmed product evidence;
7. rerun every changed descriptor; and
8. perform final process, profile-root, preference, task-root, privacy, and build audits.

Each authoritative cell has exactly one primary result: `PASS`, `FAIL`, `UNSUPPORTED`, or
`NOT RUN`. It records installed version, bundle ID, selected target, sanitized provenance,
receipt, visible boolean evidence when obtainable, route timeout, total elapsed time,
five-second cleanup grace, two-second quiescence bound, and cleanup outcome. Observer
failure, signature failure, user-state preservation, or harness ambiguity is `NOT RUN`,
not a product failure.

Safari and Safari Technology Preview are omitted from execution and reported as skipped
by user decision. Chromium remains uninstalled unless a separately signed build passes
the existing installation gate.

## Testing and review

Every production change follows RED-GREEN-REFACTOR and lands in a focused commit. Required
automated coverage includes:

- native exclusive-rename success, collision, replacement, mismatch, and cleanup-error
  paths;
- exact smoke-app and browser provenance for process, workspace, and DuckDuckGo routes;
- no signaling for temporal-only, replacement, multiple, reused, or uninspectable PIDs;
- normal-binary absence of every E2E provenance and grant symbol/string;
- isolated Chromium and Firefox roots containing exactly one synthetic profile;
- refusal of conventional-home, extra-profile, symlink, stale, and wrong-descriptor roots;
- Chromium `--user-data-dir` plus profile selector validation and Firefox exact `-profile`;
- per-descriptor target emission and plan refusal for unsupported capability combinations;
- sanitized report classification and complete timing fields; and
- no E2E preference artifact, task process, FIFO, root, profile root, or quarantine residue.

Each unit receives a fresh specification review and a fresh code/security-quality review.
Critical or Important findings return to a new failing test before implementation.

## Acceptance criteria

Implementation is complete only when:

1. the practical cleanup path leaves no normal task-root residue and fails closed under
   every injected non-malicious replacement/collision case;
2. every PASS has exact compile-gated launch provenance and exact-generation cleanup;
3. every profile PASS uses only a task-owned isolated root and PickVia-owned grant;
4. the catalog and launcher agree on exact per-descriptor capabilities;
5. all installed eligible non-Safari cells have one truthful authoritative result;
6. the compatibility report supersedes privacy-invalid historical evidence explicitly;
7. ordinary PickVia binaries remain free of E2E controls and provenance; and
8. all automated, privacy, signature, process, root, profile, and review gates pass with a
   clean feature worktree.
