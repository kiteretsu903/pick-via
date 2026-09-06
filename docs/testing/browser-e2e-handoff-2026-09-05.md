# PickVia Browser E2E Handoff — 2026-09-05

## Outcome at handoff

The browser-edition, isolated-profile, capability-policy, provenance, cleanup, and
sequential-matrix implementation is complete on:

- worktree: `/Users/bozhenpeng/gitrepos/pick-via/.worktrees/browser-editions-and-families`
- branch: `feature/browser-editions-and-families`
- reviewed HEAD: `3bba028e1dcd6769bf387349e2dc7fcee482a64f`
- status at this handoff: clean before this document was added

Final cross-task specification and security-quality reviews found no Critical,
Important, or Minor implementation issues. The implementation is ready, but the
real browser compatibility matrix is not complete.

## What is implemented

- Explicit descriptors for the approved browser editions and families.
- Exact per-descriptor normal, browser-private, profile, and profile-private
  capability policy shared by catalog, launcher, configuration, E2E control,
  AppModel, and Settings.
- Task-owned Chromium and Firefox profiles. Conventional browser profile roots
  are never inspected or mutated by E2E.
- Physical profile-path, owner, mode, device/inode, marker, executable, bundle,
  signature, and live-code validation.
- Exact PID-generation launch provenance and fail-closed cleanup authority.
- A sequential matrix runner with an Edge Stable cold/running/reopen pilot,
  fresh per-route sessions and FIFOs, authenticated cleanup recovery, strict
  result classification, private output locking, CAS publication, and keyed
  resume/finalization proofs.
- Safari and Safari Technology Preview remain product normal-route descriptors,
  but are forced skipped by the E2E matrix. No Safari extension or Shortcut is
  part of this work.

The checked manifest is
[`browser_matrix_manifest.json`](../../scripts/browser-e2e/browser_matrix_manifest.json).
The approved design and execution plan are:

- [`2026-08-25-pickvia-e2e-safe-matrix-completion-design.md`](../specs/2026-08-25-pickvia-e2e-safe-matrix-completion-design.md)
- [`2026-08-25-pickvia-safe-e2e-matrix-completion.md`](../plans/2026-08-25-pickvia-safe-e2e-matrix-completion.md)

## Real-matrix evidence so far

The authoritative August report is
[`browser-compatibility-2026-08-21.md`](browser-compatibility-2026-08-21.md).

At the 2026-08-26 preflight, all 20 eligible non-Safari applications were
installed. The final authorized attempt did not cross route selection:

- Edge Stable pilot: 3 cells `NOT RUN / harness-ambiguity` because an exact
  pre-existing, non-task-owned Edge generation blocked the required cold state.
- Remaining eligible cells: 156 `NOT RUN / blocked-after-ambiguity`.
- Safari and Safari Technology Preview: skipped by user decision.
- Product capability changes: none. `NOT RUN` is not compatibility PASS/FAIL
  evidence.

The final implementation gates recorded for that work were:

- ordinary and E2E-flagged Swift suites: passed;
- E2E driver: 172/172;
- matrix runner: 78/78;
- synthetic profile creator: 21/21;
- exclusive cleanup: 10/10;
- localhost receiver: 15/15;
- smoke runtime: 26/26;
- build/binary isolation, native smoke, Ruff, Swift format, privacy, diff, and
  clean-worktree gates: passed.

These are historical verified results, not a claim that they were rerun on
2026-09-05.

## Current live-state snapshot

Read-only checks on 2026-09-05 found:

- Microsoft Edge top-level process: not running;
- Brave Browser top-level process: running;
- Google Chrome top-level process: running.

Process state can change after this snapshot. Before a real rerun, recheck every
target application. Never terminate a generation that the runner did not prove
task-owned.

The previously documented `/private/tmp` matrix outputs, ambiguous task root,
and retained forensic-package paths were not present on 2026-09-05. They may
have been removed by temporary-directory lifecycle management; do not represent
them as available resume evidence and do not recreate or delete them manually.
Use a fresh output directory for the next attempt.

## Exact safe continuation

1. Ask the user to fully quit Brave and Chrome with each application's **Quit**
   command or `Command-Q`, not merely close windows. Edge is currently absent,
   but recheck it too. Do not automate quitting pre-existing processes.
2. Enter the feature worktree and confirm the branch, reviewed HEAD ancestry,
   and clean status.
3. Run the checked manifest dry run and confirm Edge Stable is the first pilot,
   DuckDuckGo is included, and Safari/STP are absent.
4. Use a new private output path that does not already exist, for example
   `/private/tmp/pickvia-e2e-matrix-<UTC timestamp>`.
5. Run the matrix sequentially:

   ```zsh
   python3 scripts/browser-e2e/run_browser_matrix.py \
     --manifest scripts/browser-e2e/browser_matrix_manifest.json \
     --output /private/tmp/pickvia-e2e-matrix-<UTC timestamp>
   ```

6. Let the runner stop on any pre-existing process, signature failure,
   provenance ambiguity, cleanup ambiguity, or identity change. Preserve any
   private retained artifact named by the runner.
7. Reconcile a capability only after all three states produce exact product
   evidence and one bounded direct diagnostic confirms the result. Harness
   failures remain `NOT RUN` and never change descriptors.
8. Update the authoritative report only from the validated, sanitized evidence
   chain, then rerun the full Task 8 gate list in the approved plan and obtain
   fresh spec and security-quality reviews.

## Safety boundaries

- Do not run Safari or Safari Technology Preview.
- Do not install or run Chromium unless a separately signed build passes its
  existing installation gate.
- Do not inspect conventional browser profile roots.
- Do not signal, quit, or delete pre-existing browser generations.
- Do not use Accessibility, Computer Use, private browser APIs, settings
  mutation, or synthetic UI input for the matrix.
- Do not delete ambiguous roots or forensic artifacts.
- Do not merge, push, release, publish, or install PickVia as part of E2E.

## Completion condition

The handoff is complete when every installed eligible non-Safari cell has a
truthful authoritative `PASS`, `FAIL`, `UNSUPPORTED`, or `NOT RUN` result from a
fresh run, the report matches the validated evidence, all cleanup/privacy/build
audits pass, and both final reviews accept the new evidence.
