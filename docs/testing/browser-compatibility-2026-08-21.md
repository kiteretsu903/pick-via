# Browser Compatibility Evidence — 2026-08-21

## Authoritative provenance-backed matrix — 2026-08-26

Status: **NOT RUN for every eligible route.** The final fresh sequential
invocation completed its immutable 159-cell evidence chain with exit status 3.
The Edge Stable pilot found one exact preexisting Edge generation and refused the
three-state sequence before route delivery. Its three cells are
`NOT RUN / harness-ambiguity`; all 156 later cells are
`NOT RUN / blocked-after-ambiguity`. Authenticated cleanup handoff evidence shows
that the current Edge generation was never task-owned and that the new task root
was finalized without signaling that preexisting browser. No route crossed
selection, no localhost receipt was requested, no launch provenance or exact
route-process proof was produced, and no browser UI observation was attempted.
This is the required user-state preservation stop, not evidence of a PickVia
product failure, so no browser descriptor or capability policy was changed and
no direct product diagnostic was run.

The authoritative artifact contains one run record plus 159 chained cell records.
All eligible browser applications were present at the initial manifest preflight.
Versions shown as `unavailable` are the sanitized values retained when strict
signature verification did not succeed, not claims that an application was
absent. The configured route timeout,
cleanup grace, and quiescence bounds were 30, 5, and 2 seconds, respectively, but
none was exercised and no timing field was emitted. In the table, `n/a / n/a /
n/a / n/a` means total elapsed / route timeout / cleanup grace / quiescence was
not emitted; `false / false / false` means receipt / exact E2E identity / exact
browser identity. No sanitized edition, browser-window, private/profile indicator,
or onboarding boolean exists because the visual observer was not invoked. Two
earlier terminal attempts are retained as diagnostic-only evidence: they exposed
and led to fixes for a signature-verification bound/classification defect and a
volatile outer-bundle timestamp comparison. They do not override this final
user-state-preservation classification.

| Descriptor / capability | Strategy | Version | Primary / detail | Cold | Running | Reopen | Provenance | Receipt / E2E / browser | Timing | Cleanup |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `com.microsoft.edgemac` / normal | workspace | 151.0.4129.101 | **NOT RUN** / `harness-ambiguity` | NOT RUN | NOT RUN | NOT RUN | none | false / false / false | n/a / n/a / n/a / n/a | not invoked |
| `com.google.Chrome` / normal | workspace | unavailable | **NOT RUN** / `blocked-after-ambiguity` | NOT RUN | NOT RUN | NOT RUN | none | false / false / false | n/a / n/a / n/a / n/a | not invoked |
| `com.google.Chrome` / private | chromium-private | unavailable | **NOT RUN** / `blocked-after-ambiguity` | NOT RUN | NOT RUN | NOT RUN | none | false / false / false | n/a / n/a / n/a / n/a | not invoked |
| `com.google.Chrome` / profile | chromium-profile | unavailable | **NOT RUN** / `blocked-after-ambiguity` | NOT RUN | NOT RUN | NOT RUN | none | false / false / false | n/a / n/a / n/a / n/a | not invoked |
| `com.google.Chrome.beta` / normal | workspace | unavailable | **NOT RUN** / `blocked-after-ambiguity` | NOT RUN | NOT RUN | NOT RUN | none | false / false / false | n/a / n/a / n/a / n/a | not invoked |
| `com.google.Chrome.beta` / private | chromium-private | unavailable | **NOT RUN** / `blocked-after-ambiguity` | NOT RUN | NOT RUN | NOT RUN | none | false / false / false | n/a / n/a / n/a / n/a | not invoked |
| `com.google.Chrome.beta` / profile | chromium-profile | unavailable | **NOT RUN** / `blocked-after-ambiguity` | NOT RUN | NOT RUN | NOT RUN | none | false / false / false | n/a / n/a / n/a / n/a | not invoked |
| `com.google.Chrome.dev` / normal | workspace | 154.0.8013.2 | **NOT RUN** / `blocked-after-ambiguity` | NOT RUN | NOT RUN | NOT RUN | none | false / false / false | n/a / n/a / n/a / n/a | not invoked |
| `com.google.Chrome.dev` / private | chromium-private | 154.0.8013.2 | **NOT RUN** / `blocked-after-ambiguity` | NOT RUN | NOT RUN | NOT RUN | none | false / false / false | n/a / n/a / n/a / n/a | not invoked |
| `com.google.Chrome.dev` / profile | chromium-profile | 154.0.8013.2 | **NOT RUN** / `blocked-after-ambiguity` | NOT RUN | NOT RUN | NOT RUN | none | false / false / false | n/a / n/a / n/a / n/a | not invoked |
| `com.google.Chrome.canary` / normal | workspace | 154.0.8025.0 | **NOT RUN** / `blocked-after-ambiguity` | NOT RUN | NOT RUN | NOT RUN | none | false / false / false | n/a / n/a / n/a / n/a | not invoked |
| `com.google.Chrome.canary` / private | chromium-private | 154.0.8025.0 | **NOT RUN** / `blocked-after-ambiguity` | NOT RUN | NOT RUN | NOT RUN | none | false / false / false | n/a / n/a / n/a / n/a | not invoked |
| `com.google.Chrome.canary` / profile | chromium-profile | 154.0.8025.0 | **NOT RUN** / `blocked-after-ambiguity` | NOT RUN | NOT RUN | NOT RUN | none | false / false / false | n/a / n/a / n/a / n/a | not invoked |
| `com.microsoft.edgemac` / private | chromium-private | 151.0.4129.101 | **NOT RUN** / `blocked-after-ambiguity` | NOT RUN | NOT RUN | NOT RUN | none | false / false / false | n/a / n/a / n/a / n/a | not invoked |
| `com.microsoft.edgemac` / profile | chromium-profile | 151.0.4129.101 | **NOT RUN** / `blocked-after-ambiguity` | NOT RUN | NOT RUN | NOT RUN | none | false / false / false | n/a / n/a / n/a / n/a | not invoked |
| `com.microsoft.edgemac.Beta` / normal | workspace | 152.0.4191.41 | **NOT RUN** / `blocked-after-ambiguity` | NOT RUN | NOT RUN | NOT RUN | none | false / false / false | n/a / n/a / n/a / n/a | not invoked |
| `com.microsoft.edgemac.Beta` / private | chromium-private | 152.0.4191.41 | **NOT RUN** / `blocked-after-ambiguity` | NOT RUN | NOT RUN | NOT RUN | none | false / false / false | n/a / n/a / n/a / n/a | not invoked |
| `com.microsoft.edgemac.Beta` / profile | chromium-profile | 152.0.4191.41 | **NOT RUN** / `blocked-after-ambiguity` | NOT RUN | NOT RUN | NOT RUN | none | false / false / false | n/a / n/a / n/a / n/a | not invoked |
| `com.microsoft.edgemac.Dev` / normal | workspace | 153.0.4224.0 | **NOT RUN** / `blocked-after-ambiguity` | NOT RUN | NOT RUN | NOT RUN | none | false / false / false | n/a / n/a / n/a / n/a | not invoked |
| `com.microsoft.edgemac.Dev` / private | chromium-private | 153.0.4224.0 | **NOT RUN** / `blocked-after-ambiguity` | NOT RUN | NOT RUN | NOT RUN | none | false / false / false | n/a / n/a / n/a / n/a | not invoked |
| `com.microsoft.edgemac.Dev` / profile | chromium-profile | 153.0.4224.0 | **NOT RUN** / `blocked-after-ambiguity` | NOT RUN | NOT RUN | NOT RUN | none | false / false / false | n/a / n/a / n/a / n/a | not invoked |
| `com.microsoft.edgemac.Canary` / normal | workspace | 153.0.4233.0 | **NOT RUN** / `blocked-after-ambiguity` | NOT RUN | NOT RUN | NOT RUN | none | false / false / false | n/a / n/a / n/a / n/a | not invoked |
| `com.microsoft.edgemac.Canary` / private | chromium-private | 153.0.4233.0 | **NOT RUN** / `blocked-after-ambiguity` | NOT RUN | NOT RUN | NOT RUN | none | false / false / false | n/a / n/a / n/a / n/a | not invoked |
| `com.microsoft.edgemac.Canary` / profile | chromium-profile | 153.0.4233.0 | **NOT RUN** / `blocked-after-ambiguity` | NOT RUN | NOT RUN | NOT RUN | none | false / false / false | n/a / n/a / n/a / n/a | not invoked |
| `com.brave.Browser` / normal | workspace | unavailable | **NOT RUN** / `blocked-after-ambiguity` | NOT RUN | NOT RUN | NOT RUN | none | false / false / false | n/a / n/a / n/a / n/a | not invoked |
| `com.brave.Browser` / private | chromium-private | unavailable | **NOT RUN** / `blocked-after-ambiguity` | NOT RUN | NOT RUN | NOT RUN | none | false / false / false | n/a / n/a / n/a / n/a | not invoked |
| `com.brave.Browser` / profile | chromium-profile | unavailable | **NOT RUN** / `blocked-after-ambiguity` | NOT RUN | NOT RUN | NOT RUN | none | false / false / false | n/a / n/a / n/a / n/a | not invoked |
| `com.brave.Browser.beta` / normal | workspace | 152.1.95.87 | **NOT RUN** / `blocked-after-ambiguity` | NOT RUN | NOT RUN | NOT RUN | none | false / false / false | n/a / n/a / n/a / n/a | not invoked |
| `com.brave.Browser.beta` / private | chromium-private | 152.1.95.87 | **NOT RUN** / `blocked-after-ambiguity` | NOT RUN | NOT RUN | NOT RUN | none | false / false / false | n/a / n/a / n/a / n/a | not invoked |
| `com.brave.Browser.beta` / profile | chromium-profile | 152.1.95.87 | **NOT RUN** / `blocked-after-ambiguity` | NOT RUN | NOT RUN | NOT RUN | none | false / false / false | n/a / n/a / n/a / n/a | not invoked |
| `com.brave.Browser.nightly` / normal | workspace | 152.1.96.6 | **NOT RUN** / `blocked-after-ambiguity` | NOT RUN | NOT RUN | NOT RUN | none | false / false / false | n/a / n/a / n/a / n/a | not invoked |
| `com.brave.Browser.nightly` / private | chromium-private | 152.1.96.6 | **NOT RUN** / `blocked-after-ambiguity` | NOT RUN | NOT RUN | NOT RUN | none | false / false / false | n/a / n/a / n/a / n/a | not invoked |
| `com.brave.Browser.nightly` / profile | chromium-profile | 152.1.96.6 | **NOT RUN** / `blocked-after-ambiguity` | NOT RUN | NOT RUN | NOT RUN | none | false / false / false | n/a / n/a / n/a / n/a | not invoked |
| `com.vivaldi.Vivaldi` / normal | workspace | 8.1.4087.70 | **NOT RUN** / `blocked-after-ambiguity` | NOT RUN | NOT RUN | NOT RUN | none | false / false / false | n/a / n/a / n/a / n/a | not invoked |
| `com.vivaldi.Vivaldi` / private | chromium-private | 8.1.4087.70 | **NOT RUN** / `blocked-after-ambiguity` | NOT RUN | NOT RUN | NOT RUN | none | false / false / false | n/a / n/a / n/a / n/a | not invoked |
| `com.vivaldi.Vivaldi` / profile | chromium-profile | 8.1.4087.70 | **NOT RUN** / `blocked-after-ambiguity` | NOT RUN | NOT RUN | NOT RUN | none | false / false / false | n/a / n/a / n/a / n/a | not invoked |
| `com.vivaldi.Vivaldi.snapshot` / normal | workspace | 8.2.4133.24 | **NOT RUN** / `blocked-after-ambiguity` | NOT RUN | NOT RUN | NOT RUN | none | false / false / false | n/a / n/a / n/a / n/a | not invoked |
| `com.vivaldi.Vivaldi.snapshot` / private | chromium-private | 8.2.4133.24 | **NOT RUN** / `blocked-after-ambiguity` | NOT RUN | NOT RUN | NOT RUN | none | false / false / false | n/a / n/a / n/a / n/a | not invoked |
| `com.vivaldi.Vivaldi.snapshot` / profile | chromium-profile | 8.2.4133.24 | **NOT RUN** / `blocked-after-ambiguity` | NOT RUN | NOT RUN | NOT RUN | none | false / false / false | n/a / n/a / n/a / n/a | not invoked |
| `org.mozilla.firefox` / normal | executable | 153.0.3 | **NOT RUN** / `blocked-after-ambiguity` | NOT RUN | NOT RUN | NOT RUN | none | false / false / false | n/a / n/a / n/a / n/a | not invoked |
| `org.mozilla.firefox` / private | firefox-private | 153.0.3 | **NOT RUN** / `blocked-after-ambiguity` | NOT RUN | NOT RUN | NOT RUN | none | false / false / false | n/a / n/a / n/a / n/a | not invoked |
| `org.mozilla.firefox` / profile | firefox-profile | 153.0.3 | **NOT RUN** / `blocked-after-ambiguity` | NOT RUN | NOT RUN | NOT RUN | none | false / false / false | n/a / n/a / n/a / n/a | not invoked |
| `org.mozilla.firefoxdeveloperedition` / normal | executable | 155.0 | **NOT RUN** / `blocked-after-ambiguity` | NOT RUN | NOT RUN | NOT RUN | none | false / false / false | n/a / n/a / n/a / n/a | not invoked |
| `org.mozilla.firefoxdeveloperedition` / private | firefox-private | 155.0 | **NOT RUN** / `blocked-after-ambiguity` | NOT RUN | NOT RUN | NOT RUN | none | false / false / false | n/a / n/a / n/a / n/a | not invoked |
| `org.mozilla.firefoxdeveloperedition` / profile | firefox-profile | 155.0 | **NOT RUN** / `blocked-after-ambiguity` | NOT RUN | NOT RUN | NOT RUN | none | false / false / false | n/a / n/a / n/a / n/a | not invoked |
| `org.mozilla.nightly` / normal | executable | 156.0a1 | **NOT RUN** / `blocked-after-ambiguity` | NOT RUN | NOT RUN | NOT RUN | none | false / false / false | n/a / n/a / n/a / n/a | not invoked |
| `org.mozilla.nightly` / private | firefox-private | 156.0a1 | **NOT RUN** / `blocked-after-ambiguity` | NOT RUN | NOT RUN | NOT RUN | none | false / false / false | n/a / n/a / n/a / n/a | not invoked |
| `org.mozilla.nightly` / profile | firefox-profile | 156.0a1 | **NOT RUN** / `blocked-after-ambiguity` | NOT RUN | NOT RUN | NOT RUN | none | false / false / false | n/a / n/a / n/a / n/a | not invoked |
| `com.operasoftware.Opera` / normal | workspace | unavailable | **NOT RUN** / `blocked-after-ambiguity` | NOT RUN | NOT RUN | NOT RUN | none | false / false / false | n/a / n/a / n/a / n/a | not invoked |
| `company.thebrowser.Browser` / normal | workspace | unavailable | **NOT RUN** / `blocked-after-ambiguity` | NOT RUN | NOT RUN | NOT RUN | none | false / false / false | n/a / n/a / n/a / n/a | not invoked |
| `com.kagi.kagimacOS` / normal | workspace | 1.1.2 | **NOT RUN** / `blocked-after-ambiguity` | NOT RUN | NOT RUN | NOT RUN | none | false / false / false | n/a / n/a / n/a / n/a | not invoked |
| `com.duckduckgo.macos.browser` / normal | duckduckgo | 1.203.0 | **NOT RUN** / `blocked-after-ambiguity` | NOT RUN | NOT RUN | NOT RUN | none | false / false / false | n/a / n/a / n/a / n/a | not invoked |
| `com.duckduckgo.macos.browser` / private | duckduckgo-private | 1.203.0 | **NOT RUN** / `blocked-after-ambiguity` | NOT RUN | NOT RUN | NOT RUN | none | false / false / false | n/a / n/a / n/a / n/a | not invoked |
| `com.apple.Safari` / normal | workspace | not inspected | **SKIPPED** / user decision | SKIPPED | SKIPPED | SKIPPED | none | n/a / n/a / n/a | n/a / n/a / n/a / n/a | not invoked |
| `com.apple.SafariTechnologyPreview` / normal | workspace | not inspected | **SKIPPED** / user decision | SKIPPED | SKIPPED | SKIPPED | none | n/a / n/a / n/a | n/a / n/a / n/a / n/a | not invoked |

Safari and Safari Technology Preview profile/private routing remain unsupported;
the user chose to skip both Safari applications, so no Safari route, Shortcut,
extension, profile, private window, UI observer, or browser process was invoked.
The hash-chained evidence file is retained under the approved private matrix output
for review. It contains only the sanitized schema: no application path, routed
address, request token, URL, PID, process arguments, secret, profile path, raw UI,
or screenshot. The three attempt-specific authenticated cleanup packages are also
retained privately. One physical task root from the second diagnostic attempt is
still present because a later exact Edge generation is not in any authenticated
owned-generation ledger; its relationship to that root is therefore unproven.
Neither the generation nor the root was signaled, inspected beyond ownership-safe
metadata, or removed.

The final process audit found no E2E application, driver, receiver, helper, FIFO,
handoff directory, or cleanup/finalization quarantine. One Edge Stable generation
and one Brave Stable generation were preserved because neither was proved
task-owned; the Edge generation is the pilot blocker above, and Brave was never
reached. One exact E2E preferences artifact created during the first attempt was
moved recoverably to Trash, after which the real preferences location rechecked
empty. The one ambiguous task root and three authenticated forensic packages
remain intentionally retained for review.

## Historical diagnostic-only ledgers

Every section below predates the 2026-08-26 isolated matrix. It is retained for
diagnosis and provenance, but is not authoritative compatibility evidence and
must not be used to override the matrix classification above.

## Localhost receiver harness

Status: **PASS for the receiver harness.** Normal browser-routing E2E remains
pending for Task 9; Task 5 enhanced-capability probes are recorded below.

The receiver binds an ephemeral port on the exact IPv4 loopback address
`127.0.0.1`. Any other configured bind address is rejected before server
creation. Tokens are generated in memory with `secrets.token_urlsafe(24)`, are
one-shot, and are never persisted by the receiver. Selected expired tokens are
retained below as non-routable evidence identifiers.

The CLI accepts counts only; it does not accept a routed URL. Its newline-delimited
JSON protocol is:

- readiness: `{"port": <ephemeral integer>, "tokens": [<opaque token>, ...]}`
- receipt: `{"token": <opaque token>, "receipt_time": <number>, "remote_address": "127.0.0.1"}`

Each successful request must have an exact raw target consisting only of one
registered token. It receives an empty 204 response and consumes that token.
Unknown targets, duplicates, and path or query variants all receive the same
empty 404 response and do not create receipts. Malformed or unsupported HTTP
requests receive generic empty error responses that do not reflect request data.
The configured receipt count is enforced atomically, including during concurrent
requests.

Privacy constraints verified by the harness:

- only token, receipt time, and loopback remote address enter a receipt;
- request paths, query strings, and headers are neither recorded nor emitted;
- default HTTP request logging is disabled;
- the receiver itself persists neither tokens nor receipts;
- stdout contains only readiness and explicitly requested receipt records;
- stderr is empty during valid operation;
- invalid target-like arguments are rejected without being reflected to output;
- the receiver shuts down after the requested receipt count.

## Harness evidence

- `python3 scripts/browser-e2e/test_localhost_probe.py -v`: 15 tests ran, all OK.
- Live subprocess proof from a unique temporary working directory: one path/query
  variant returned 404, two independent registered tokens returned 204, exactly
  two minimal receipts were emitted, stdout/stderr passed the forbidden-data
  scan, the process exited with status 0, and the temporary directory was removed.

## Opera, Arc, and Orion enhanced-capability probes

The Task 5 probes used the installed vendor-signed apps one at a time. A
caller-side alarm bounded every receiver, and a separate bounded wrapper
supervised each browser launch. The routed address was assembled only in
process memory from a separately supplied ephemeral port and opaque token;
shell tracing and browser output were disabled. The report records tokens but
does not record routed addresses, request targets, or headers.

Tool-specific app capture hung without returning state on the first Opera
observation. After the screenshot permission preflight passed, all later UI
evidence came from observation-only macOS window captures. No click, key,
Accessibility action, synthetic input, account, sign-in, sync, import,
extension, password, or default-browser change was used. The screenshots were
deleted after the textual observations below were recorded.

| Browser | Capability | Installed version | Candidate | Cold state | Already-running state | Close-window and repeat | Result |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Opera (`com.operasoftware.Opera`) | Normal | 135.0 | Workspace launch | Not part of this enhanced-capability gate | Not run | Not run | **PENDING — Task 9** |
| Opera (`com.operasoftware.Opera`) | Profile | 135.0 | Exact installed executable with a task-owned data root and `--profile-directory=PickVia E2E` | Installed Opera PID verified; token `J-WxXBi14CEhdWNzdvuWXNp7xJvF-7Sv` received; UI showed only a generic profile glyph, not visible `PickVia E2E` identity | Not run after cold UI failure | Not run after cold UI failure | **UNSUPPORTED — failed visible exact-profile criterion** |
| Opera (`com.operasoftware.Opera`) | Private | 135.0 | Exact installed executable with a task-owned data root and `--incognito` | Installed Opera PID verified; token `hr0QmzhTrAWatYmNfRIZT595FOHCTjxR` received; native `PRIVATE` badge visible | Token `QldTC-hiPKry_V7-AuOeijV93b2ZF0z6` received while the original PID remained, but the bounded second invocation reached its 15-second alarm and no running-state window capture was available | No documented exact-window close mechanism was established without prohibited UI automation | **UNSUPPORTED — running UI and close-window repeat criteria unproven** |
| Arc (`company.thebrowser.Browser`) | Normal | 1.161.1 | Workspace launch | Not part of this enhanced-capability gate | Not run | Not run | **PENDING — Task 9** |
| Arc (`company.thebrowser.Browser`) | Profile | 1.161.1 | Exact binary contained profile/data-root switches, but no profile route was attempted past first-run onboarding | Cold launch remained in `A browser for you` onboarding; no exact profile indicator or token receipt | Not run | Not run | **UNSUPPORTED — onboarding blocked cold identity and receipt criteria** |
| Arc (`company.thebrowser.Browser`) | Private | 1.161.1 | Exact installed executable with task-owned data root and `--incognito` | Arc launcher PID observed; first splash then `A browser for you` onboarding; token `YcDa17U6QDlk2QOdmpzA2NZQ5RDn7XQv` was not received and no private indicator appeared before the 45-second bounds expired | Not run after cold failure | Not run after cold failure | **UNSUPPORTED — failed cold receipt and private-UI criteria** |
| Orion (`com.kagi.kagimacOS`) | Normal | 1.1.2 | Workspace launch | Ordinary direct launch was used only to observe first-run behavior; the receiver did not receive token `ssBCBoA2r19z1oMb0RVXPWoHNlAvDSTT` before timeout | Not run | Not run | **PENDING — Task 9** |
| Orion (`com.kagi.kagimacOS`) | Profile | 1.1.2 | Kagi documents UI-created profiles and external links opening in the last/default profile; installed metadata and binary exposed no exact selected-profile launch selector | Orion remained in onboarding video windows; no `PickVia E2E` identity and no token receipt | Not run | Not run | **UNSUPPORTED — no exact selector and cold UI/receipt criteria failed** |
| Orion (`com.kagi.kagimacOS`) | Private | 1.1.2 | Installed metadata and binary exposed private-window UI actions but no external private selector | Orion remained in onboarding video windows; no native private indicator and no token receipt | Not run | Not run | **UNSUPPORTED — no external selector and cold UI/receipt criteria failed** |

Opera displayed an untouched optional feature-usage telemetry banner. Arc and
Orion required first-run interaction, so the probes stopped rather than
advancing onboarding. Opera and Arc task-owned data roots were removed. The
Orion process reparented and no longer exposed the synthetic-home environment;
after its exact executable and task-time launch were verified, only that PID was
terminated. The unambiguous Orion task directory was removed, while any
possible default-location first-run state was left untouched because ownership
could not be proved without inspecting browser data. Final exact-process checks
found no running Opera, Arc, or Orion process, and the task screenshot/data
directory was empty.

All enhanced targets therefore remain absent from PickVia. No request may fall
back to a normal window, another profile, another edition, or another browser.

## Safari Shortcuts proof gate

The user chose to skip the Safari helper and extension route. Safari 27.0
(`com.apple.Safari`) and Safari Technology Preview 27.0
(`com.apple.SafariTechnologyPreview`) therefore remain normal-workspace-only.
Their profile strategies are `.none` and their private strategies are
`.unsupported`.

| Browser | Capability | Installed version | Result |
| --- | --- | --- | --- |
| Safari | Normal | 27.0 | **PENDING — Task 9** |
| Safari | Profile | 27.0 | **UNSUPPORTED — helper route skipped by user; no routing proof attempted or completed** |
| Safari | Private | 27.0 | **UNSUPPORTED — helper route skipped by user; no routing proof attempted or completed** |
| Safari Technology Preview | Normal | 27.0 | **PENDING — Task 9** |
| Safari Technology Preview | Profile | 27.0 | **UNSUPPORTED — helper route skipped by user; no edition-specific routing proof attempted or completed** |
| Safari Technology Preview | Private | 27.0 | **UNSUPPORTED — helper route skipped by user; no edition-specific routing proof attempted or completed** |

No Safari profile, Tab Group, Shortcut helper, localhost receiver, or routed
token was created. The required `/dev/stdin` privacy proof was not run, so this
gate makes no claim about its behavior. The initial read-only Computer Use
inspection of Safari returned no state and was aborted after hanging; no further
Safari or Shortcuts UI, screenshot, or installed-app action was taken. Because
the resulting Safari/Shortcuts process and window ownership was uncertain, it
was left untouched. The preexisting ownership-unknown path
`/private/tmp/pickvia-safari-research.ADchkR` was also left untouched and was
not inspected.

## Automated Edge Stable pilot — 2026-08-22

Status: **FAIL — BrowserLauncher Chromium normal direct-executable
incompatibility in the installed Edge cold state.** The full browser matrix did
not begin.

The separate E2E build, smoke test, binary-isolation gate, and exact-application
NSWorkspace control passed. The classified cold run then emitted the closed
`selected` FIFO outcome, verified the exact E2E application process, and
observed an exact Microsoft Edge Stable process generation. The one-shot
loopback receiver did not receive its fresh token within the 30-second bound.

An independent control bypassed PickVia and invoked the exact installed Edge
executable with the same production single-URL argument shape. It likewise
observed an exact Edge process generation without a receiver receipt in 30
seconds. This isolates the failure from E2E target selection, the stdin helper,
and exact-application delivery: Microsoft Edge 151.0.4129.101 did not navigate
the supplied route through the direct-executable launch strategy in its current
cold state.

| Browser | Mode/state | Installed identity | Selection | Receipt | Exact process identity | Result |
| --- | --- | --- | --- | --- | --- | --- |
| Microsoft Edge Stable | Normal, cold | 151.0.4129.101; `com.microsoft.edgemac`; team `UBF8T346G9` | `selected` | No receipt within 30 seconds | E2E app and Edge Stable generation verified | **FAIL — direct-executable browser transport** |
| Microsoft Edge Stable | Normal, already running | Same installed identity | Not attempted | Not attempted | Not attempted | **NOT RUN — stopped at cold gate** |
| Microsoft Edge Stable | Normal, reopen | Same installed identity | Not attempted | Not attempted | Not attempted | **NOT RUN — stopped at cold gate** |

No valid browser UI observation was used: the exact Edge main generation was
too transient to satisfy the read-only presence guard, so no Computer Use call
was made for the classified run. No raw UI tree, routed address, browser
arguments, request target, profile label, or token was recorded. No profile or
private target was created or attempted.

The driver and independent control both stopped their receiver and terminated
only the unambiguous task-owned Edge generation. Final exact-process checks
found no Edge Stable, E2E PickVia, or receiver process and no driver-created
support root. The installed PickVia process remained the same exact generation
recorded before the pilot. Preexisting named build/review temporary roots were
left untouched.

### Workspace-launch remediation rerun

Status: **PASS for the complete Microsoft Edge Stable normal pilot.** Cold,
already-running, and reopen each passed the selected-status, receipt,
exact-process, visible-edition, onboarding, and browser-window gates. The full
browser matrix was not started in this task. This rerun preserves the earlier
failure above as evidence for the replaced direct-executable strategy. At
`05da88f`, browser-level normal Chromium targets changed to exact
trusted-application workspace delivery; profile and private launch strategies
were not exercised by this gate.

The rebuilt E2E application passed its identity, signature, smoke, and
normal-binary isolation gates. One immediate post-build preflight ended in a
sanitized helper error before selection. Bundle, signature, helper, FIFO, and
focused driver checks found no reproducible defect; an identical diagnostic
route then completed with helper compiler and exact-app helper exit status zero,
`selected`, a fresh receipt, and exact process identities. The authorized cold
retry and the two remaining classified states all passed independently:

| Browser | Mode/state | Installed identity | Selection | Receipt | Exact process identity | Sanitized visible evidence | Result |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Microsoft Edge Stable | Normal, cold | 151.0.4129.101; `com.microsoft.edgemac`; team `UBF8T346G9` | `selected` | Fresh receipt | E2E app and Edge Stable generation verified | Edge Stable visible; browser window present; onboarding absent | **PASS** |
| Microsoft Edge Stable | Normal, already running | Same installed identity | `selected` | Fresh receipt | Same recorded task-owned Edge generation verified and preserved by the driver | Edge Stable visible; browser window present; onboarding absent | **PASS** |
| Microsoft Edge Stable | Normal, reopen | Same installed identity | `selected` | Fresh receipt | New exact Edge Stable generation verified after the recorded baseline was closed | Edge Stable visible; browser window present; onboarding absent | **PASS** |

An earlier held cold route repeated the automated proof but could not return
browser state while the Mac was locked. After unlock, three fresh independent
routes supplied the visible evidence above through read-only Computer Use calls
guarded by an exact Edge Stable process. Only the three booleans represented in
the table were retained; the underlying UI state and screenshots were not
emitted or recorded.

This remediation-rerun entry contains no routed address, token, browser
arguments, raw UI, or profile label, and no profile or private target was
created or attempted. Each task-owned cold/reopen generation was removed after
proof; the already-running generation was terminated only after its exact PID
and start generation were revalidated. Final checks found no Edge Stable, E2E
PickVia, or receiver process and no driver-created support root. Installed
PickVia remained the same exact pre-pilot process generation, and preexisting
temporary roots were left untouched.

## DuckDuckGo normal routing — 2026-08-22

Status: **PASS for DuckDuckGo normal routing in cold, already-running, and
reopen states.** The installed 1.203.0 build has bundle identifier
`com.duckduckgo.macos.browser`, team `HKE973VLUW`, and PickVia's `.duckDuckGo`
launch strategy.

An earlier cold UI observer attempt ended in a capture-start failure and was
excluded from the result. The coordinated rerun used a fresh independent route
for every state and held only the exact causal DuckDuckGo generation while a
bounded read-only observer returned sanitized booleans:

| Browser | Mode/state | Selection | Receipt | Exact process identity | Sanitized visible evidence | Result |
| --- | --- | --- | --- | --- | --- | --- |
| DuckDuckGo | Normal, cold | `selected` | Fresh receipt | E2E app and DuckDuckGo generation verified | DuckDuckGo visible; browser window present; onboarding absent | **PASS** |
| DuckDuckGo | Normal, already running | `selected` | Fresh receipt | Same recorded task-owned DuckDuckGo generation verified and preserved by the driver | DuckDuckGo visible; browser window present; onboarding absent | **PASS** |
| DuckDuckGo | Normal, reopen | `selected` | Fresh receipt | New exact DuckDuckGo generation verified after the recorded baseline was closed | DuckDuckGo visible; browser window present; onboarding absent | **PASS** |

No Fire, private, or profile target was created or attempted. This entry
contains no routed address, token, browser arguments, raw UI, screenshot, or
profile label. The already-running baseline was terminated only after exact PID
and start-generation revalidation. Final checks found no DuckDuckGo, E2E
PickVia, or receiver process; installed PickVia remained the same exact
pre-batch process generation, and preexisting temporary roots were left
untouched.

## Microsoft Edge Beta normal routing — 2026-08-22

Status: **FAIL for the cold PickVia route; already-running and reopen were not
run.** The installed Microsoft Edge Beta 152.0.4191.41 build has bundle
identifier `com.microsoft.edgemac.Beta`, team `UBF8T346G9`, and uses PickVia's
browser-level normal Chromium workspace strategy.

| Browser | Mode/state | Selection | Receipt | Exact process identity | Sanitized visible evidence | Result |
| --- | --- | --- | --- | --- | --- | --- |
| Microsoft Edge Beta | Normal, cold | `selected` | No receipt within 30 seconds | E2E app and exact Edge Beta generation verified | **NOT RUN — bounded observer did not return state** | **FAIL — PickVia product route did not deliver** |
| Microsoft Edge Beta | Normal, already running | Not attempted | Not attempted | Not attempted | Not attempted | **NOT RUN — stopped at cold gate** |
| Microsoft Edge Beta | Normal, reopen | Not attempted | Not attempted | Not attempted | Not attempted | **NOT RUN — stopped at cold gate** |

One independent control bypassed PickVia and used the same exact-application
NSWorkspace delivery shape with a fresh receiver. The helper exited
successfully, an exact Edge Beta generation appeared, and the receiver obtained
its receipt. This isolates the failed cold cell from target selection, the E2E
helper, the installed Edge Beta build, and the receiver; the failure remains at
PickVia's product routing boundary. The visible observer exceeded its bound and
was interrupted without returning browser state, so no channel-edition,
browser-window, or onboarding claim is made.

No profile or private target was created or attempted. This entry contains no
routed address, token, browser arguments, raw UI, screenshot, or profile label.
The sole control generation exited after exact task-time revalidation. Final
checks found no Edge Beta, E2E PickVia, or receiver process; installed PickVia
remained the same exact pre-batch process generation, and preexisting temporary
roots were left untouched.

### Initialized-state reconciliation

Status: **PASS for Microsoft Edge Beta normal routing in the initialized cold,
already-running, and reopen states.** This result supersedes the earlier stable
product-failure conclusion, but does not erase the pristine first cold failure
or the successful direct exact-application control above. The installed
Microsoft Edge Beta 152.0.4191.41 identity remained
`com.microsoft.edgemac.Beta`, team `UBF8T346G9`, using PickVia's browser-level
normal Chromium exact-application workspace strategy.

The E2E harness was subsequently hardened before this reconciliation. Exact-app
delivery is now bound to the launched E2E process identity, including bounded
registration and open readiness. Cleanup now bounds and de-duplicates exact
generation termination, allows a bounded shutdown grace, observes a quiescence
window for delayed generations, and revokes termination authority after an
unknown identity state. These changes address the helper, readiness, and cleanup
uncertainty encountered while investigating the first-launch history; they do
not reclassify the original missing receipt as a successful route.

Three fresh initialized-state routes then supplied independent causal and
visible proof:

| Browser | Mode/state | Selection | Receipt | Exact process identity | Sanitized visible evidence | Result |
| --- | --- | --- | --- | --- | --- | --- |
| Microsoft Edge Beta | Normal, cold | `selected` | Fresh receipt | E2E app and exact Edge Beta generation verified | Edge Beta visible; browser window present; onboarding absent | **PASS** |
| Microsoft Edge Beta | Normal, already running | `selected` | Fresh receipt | Same recorded task-owned Edge Beta generation verified and preserved by the driver | Edge Beta visible; browser window present; onboarding absent | **PASS** |
| Microsoft Edge Beta | Normal, reopen | `selected` | Fresh receipt | New exact Edge Beta generation verified after the recorded baseline was closed | Edge Beta visible; browser window present; onboarding absent | **PASS** |

No profile or private target was created or attempted. This reconciliation
contains no routed address, token, browser arguments, raw UI, screenshot, or
profile label. The final held batch ended with exact Edge Beta, E2E PickVia, and
receiver absence after every state. The cold and already-running drivers
reported `selected` and exited successfully; the reopen held proof established
`selected`, a fresh receipt, and both exact identities before release, and its
final exact absence was verified without reconstructing the numeric exit status
lost with the held session output. Installed PickVia remained the same exact
pre-batch process generation, and preexisting temporary roots were left
untouched.

## Microsoft Edge Dev normal routing — 2026-08-22

Status: **PASS for Microsoft Edge Dev normal routing in the initialized cold,
already-running, and reopen states.** The installed Microsoft Edge Dev
153.0.4224.0 build has bundle identifier `com.microsoft.edgemac.Dev`, team
`UBF8T346G9`, and uses PickVia's browser-level normal Chromium exact-application
workspace strategy.

Two harness attempts were excluded without being converted into browser or
product evidence. The first cold invocation supplied a noncanonical target
identifier and closed with `target-missing` before browser launch; its exact E2E
identity passed, but it produced no receipt or Edge Dev generation. After the
canonical cold and already-running cells passed, the first reopen invocation
closed with `identity-ambiguous` before receipt and before visible observation.
Its remaining exact generation was signaled only after the originally empty
browser baseline, exact executable, bundle, team, and task-time start generation
were revalidated; bounded quiescence then confirmed absence. One authorized
fresh reopen retry from that confirmed absence completed the full gate.

| Browser | Mode/state | Selection | Receipt | Exact process identity | Sanitized visible evidence | Result |
| --- | --- | --- | --- | --- | --- | --- |
| Microsoft Edge Dev | Normal, cold | `selected` | Fresh receipt | E2E app and exact Edge Dev generation verified | Edge Dev visible; browser window present; onboarding absent | **PASS** |
| Microsoft Edge Dev | Normal, already running | `selected` | Fresh receipt | Same recorded task-owned Edge Dev generation verified and preserved by the driver | Edge Dev visible; browser window present; onboarding absent | **PASS** |
| Microsoft Edge Dev | Normal, reopen | `selected` | Fresh receipt | New exact Edge Dev generation verified on the fresh retry after the recorded baseline was closed | Edge Dev visible; browser window present; onboarding absent | **PASS** |

No profile or private target was created or attempted. This entry contains no
routed address, token, browser arguments, raw UI, screenshot, or profile label.
The already-running baseline was terminated only after exact PID and
start-generation revalidation. The final held batch and reopen retry ended with
exact Edge Dev, E2E PickVia, receiver, and driver absence after the driver's
bounded cleanup and quiescence checks. Installed PickVia remained the same exact
pre-batch process generation, and preexisting temporary roots were left
untouched.

## Microsoft Edge Canary normal routing — 2026-08-22

Status: **PASS for Microsoft Edge Canary normal routing in the initialized
cold, already-running, and reopen states.** The installed Microsoft Edge Canary
153.0.4233.0 build has bundle identifier `com.microsoft.edgemac.Canary`, team
`UBF8T346G9`, and uses PickVia's browser-level normal Chromium exact-application
workspace strategy.

This result preserves an earlier pristine cold 30-second receiver receipt
timeout as historical evidence; the missing receipt was not retroactively
reclassified as a successful route. In the current initialized batch, the first
cold route passed the causal and visible gates and the driver exited with status
zero, but an independent
post-driver check found one delayed exact Canary generation. Because the
pre-batch Canary baseline was empty, the sole generation was signaled only after
its exact executable, bundle, team, and task-time start were revalidated.
Bounded quiescence confirmed absence. One authorized cold retry prompted only
by that cleanup anomaly then completed the entire gate with clean final absence.

| Browser | Mode/state | Selection | Receipt | Exact process identity | Sanitized visible evidence | Result |
| --- | --- | --- | --- | --- | --- | --- |
| Microsoft Edge Canary | Normal, cold | `selected` | Fresh receipt | E2E app and exact Edge Canary generation verified on the clean retry | Edge Canary visible; browser window present; onboarding absent | **PASS** |
| Microsoft Edge Canary | Normal, already running | `selected` | Fresh receipt | E2E app and same recorded task-owned Edge Canary generation verified and preserved by the driver | Edge Canary visible; browser window present; onboarding absent | **PASS** |
| Microsoft Edge Canary | Normal, reopen | `selected` | Fresh receipt | E2E app and new exact Edge Canary generation verified after the recorded baseline was closed | Edge Canary visible; browser window present; onboarding absent | **PASS** |

No profile or private target was created or attempted. This entry contains no
routed address, token, browser arguments, raw UI, screenshot, or profile label.
The already-running baseline was terminated only after exact PID and
start-generation revalidation. Final bounded quiescence found no Edge Canary,
E2E PickVia, receiver, or driver process; installed PickVia remained the same
exact pre-batch process generation, and preexisting temporary roots were left
untouched.

## Google Chrome normal routing — 2026-08-22

Status: **two installed-identity blockers and two passing initialized routing
matrices.** Chrome Stable and Beta were not launched because their installed
bundles failed strict deep code-signature verification. Chrome Dev and Canary
passed strict deep Developer ID verification and all three normal routing
states. All four descriptors use PickVia's browser-level normal Chromium
exact-application workspace strategy.

The read-only identity gate recorded these exact installed editions:

| Browser | Installed identity | Strict installed signature | Normal state result |
| --- | --- | --- | --- |
| Google Chrome Stable | 151.0.7922.172; `com.google.Chrome`; team `EQHXZ8M8AV` | **FAIL — installed bundle is not validly signed** | Cold, already-running, and reopen: **NOT RUN — installation identity blocker** |
| Google Chrome Beta | 153.0.8010.5; `com.google.Chrome.beta`; team `EQHXZ8M8AV` | **FAIL — installed bundle is not validly signed** | Cold, already-running, and reopen: **NOT RUN — installation identity blocker** |
| Google Chrome Dev | 154.0.8013.2; `com.google.Chrome.dev`; team `EQHXZ8M8AV` | **PASS — valid on disk and satisfies its designated requirement** | Cold, already-running, and reopen: **PASS** |
| Google Chrome Canary | 154.0.8016.0; `com.google.Chrome.canary`; team `EQHXZ8M8AV` | **PASS — valid on disk and satisfies its designated requirement** | Cold, already-running, and reopen: **PASS** |

Gatekeeper assessment separately returned an internal Code Signing subsystem
error for the otherwise strictly valid Dev and Canary bundles. That local
assessment anomaly is retained as installed-environment evidence and is not
classified as a PickVia routing failure. Neither blocked edition was opened or
observed through Computer Use. The exact preexisting Chrome Stable process
generation was preserved throughout, and Chrome Beta remained absent.

Chrome Dev supplied independent causal proof for each classified state:

| Browser | Mode/state | Selection | Receipt | Exact process identity | Sanitized visible evidence | Result |
| --- | --- | --- | --- | --- | --- | --- |
| Google Chrome Dev | Normal, initialized cold | `selected` | Fresh receipt | E2E app and exact Chrome Dev generation verified | Chrome Dev visible; browser window present; onboarding visible | **PASS** |
| Google Chrome Dev | Normal, already running | `selected` | Fresh receipt | Same exact task-created Chrome Dev baseline verified and preserved by the driver | Chrome Dev visible; browser window present; onboarding visible | **PASS** |
| Google Chrome Dev | Normal, reopen | `selected` | Fresh receipt | New exact Chrome Dev generation verified after the recorded baseline was closed | Chrome Dev visible; browser window present; onboarding visible | **PASS** |

An initial noncanonical cold harness invocation was rejected before application
launch and contributed no evidence. The first canonical initialized cold route
then encountered an exact-process identity handoff before receipt. The sole
remaining task-time Dev generation was terminated only after the originally
empty baseline and exact executable identity were revalidated; bounded absence
was confirmed before the one authorized retry. That retry passed the complete
causal gate. Its first read-only observer exceeded the observation bound and
was excluded; a separate full-path observer returned only the three sanitized
booleans shown above for the exact held state. The running and reopen observers
completed within their bounds. The onboarding surface was never advanced, and
no sign-in, synchronization, import, or default-browser action was taken.

Chrome Canary likewise supplied independent proof for each state:

| Browser | Mode/state | Selection | Receipt | Exact process identity | Sanitized visible evidence | Result |
| --- | --- | --- | --- | --- | --- | --- |
| Google Chrome Canary | Normal, initialized cold | `selected` | Fresh receipt | E2E app and exact Chrome Canary generation verified | Chrome Canary visible; browser window present; onboarding absent | **PASS** |
| Google Chrome Canary | Normal, already running | `selected` | Fresh receipt | Same exact task-created Chrome Canary baseline verified and preserved by the driver | Chrome Canary visible; browser window present; onboarding absent | **PASS** |
| Google Chrome Canary | Normal, reopen | `selected` | Fresh receipt | New exact Chrome Canary generation verified after the recorded baseline was closed | Chrome Canary visible; browser window present; onboarding absent | **PASS** |

The first initialized Canary cold route was excluded after an exact-process
identity handoff. Its sole remaining task-time generation was terminated only
after the empty prestate and exact identity were revalidated; bounded absence
preceded the one authorized retry, which passed. All three Canary observers
used the full application path and completed within their bounds.

No profile or private target was created or attempted. This entry contains no
routed address, token, browser arguments, raw UI, screenshot, or profile label.
The task-created running baselines were closed only after exact process and
start-generation revalidation. Final exact-process checks found Chrome Dev,
Chrome Canary, E2E PickVia, receiver, and driver absent; the preexisting Chrome
Stable and installed PickVia generations remained unchanged. Preexisting
temporary roots were left untouched.

## Brave normal routing — 2026-08-22

Status: **Brave Stable NOT RUN because its installed bundle failed strict deep
signature verification; Brave Beta and Nightly FAIL at the cold receipt gate.**
All three descriptors use PickVia's browser-level normal Chromium
exact-application workspace strategy.

The read-only installed-identity gate recorded Brave Stable 151.1.93.138,
`com.brave.Browser`, and team `KL8N8XSYF4`. Its strict deep signature check
exited nonzero, so no Stable route or UI observation was attempted.

Brave Beta 152.1.95.87, `com.brave.Browser.beta`, team `KL8N8XSYF4`, passed its
strict deep signature check. Two independent PickVia cold routes from confirmed
absence each emitted `selected`, verified the exact E2E app and exact Brave Beta
generation, and failed to receive the fresh receiver receipt within 30 seconds.
The second run followed exact cleanup and quiescence of the first generation,
so the repeated cold failure from confirmed absence is not classified as
first-launch-only.
Both drivers ultimately reported `cleanup-error` because their exact Beta
generations remained after the receipt failure; no visible observation was made.

Brave Nightly 152.1.96.6, `com.brave.Browser.nightly`, team `KL8N8XSYF4`, also
passed its strict deep signature check. Its independent cold route from
confirmed absence through the production driver emitted `selected`, verified
the exact E2E app and exact Nightly generation, and received no fresh receipt
within 30 seconds. The driver reported `cleanup-error` because the exact Nightly
generation remained after the receipt failure. No visible observation was made,
and the already-running and reopen states were not attempted.

| Browser | Mode/state | Selection | Receipt | Exact process identity | Sanitized visible evidence | Result |
| --- | --- | --- | --- | --- | --- | --- |
| Brave Stable | Normal, cold/already running/reopen | Not attempted | Not attempted | Installed identity recorded; strict deep signature failed | **NOT RUN** | **NOT RUN — installation identity blocker** |
| Brave Beta | Normal, cold | `selected` on both attempts | No receipt within 30 seconds on either attempt | E2E app and exact Brave Beta generation verified on both attempts | **NOT RUN — stopped before observer** | **FAIL — repeated cold receipt failure** |
| Brave Beta | Normal, already running | Not attempted | Not attempted | Not attempted | Not attempted | **NOT RUN — stopped at cold gate** |
| Brave Beta | Normal, reopen | Not attempted | Not attempted | Not attempted | Not attempted | **NOT RUN — stopped at cold gate** |
| Brave Nightly | Normal, cold | `selected` | No receipt within 30 seconds | E2E app and exact Brave Nightly generation verified | **NOT RUN — stopped before observer** | **FAIL — cold receipt failure** |
| Brave Nightly | Normal, already running | Not attempted | Not attempted | Not attempted | Not attempted | **NOT RUN — stopped at cold gate** |
| Brave Nightly | Normal, reopen | Not attempted | Not attempted | Not attempted | Not attempted | **NOT RUN — stopped at cold gate** |

Separate independent controls for Beta and Nightly bypassed PickVia and used the
same exact-application NSWorkspace delivery helper with a fresh receiver. In
each control the receiver became ready, the helper compiled, and the exact
edition generation was verified; the helper exited nonzero and the receiver
obtained no receipt. The controls therefore do not isolate the missing receipts
to PickVia's selection boundary.

No profile or private target was created or attempted. This entry contains no
routed address, token, browser arguments, raw UI, screenshot, or profile label.
Each sole residual Beta or Nightly generation received SIGTERM only after the
originally empty edition prestate plus its exact PID, start generation,
executable, bundle, team, and task-time start were revalidated. No SIGKILL was
used. Each final control-generation cleanup reached bounded absence and
quiescence; final checks found no Brave Beta, Brave Nightly, E2E PickVia,
receiver, helper, or driver process. Installed PickVia remained the same exact
pre-batch generation, and preexisting temporary roots were left untouched.

## Vivaldi Stable normal routing — 2026-08-22

Status: **AUTOMATED COLD ROUTE PASS / VISIBLE MATRIX INCOMPLETE.** The installed
Vivaldi Stable 8.1.4087.70 build has bundle identifier
`com.vivaldi.Vivaldi`, team `4XF3XNRN6Y`, passes strict deep signature
verification, and uses PickVia's browser-level normal Chromium
exact-application workspace strategy.

Two fresh independent cold routes from confirmed absence each emitted
`selected`, received a fresh receiver receipt, verified the exact E2E app and
exact Vivaldi generation, and exited successfully. Each exact route was held for
the bounded 240-second full-path observation window, but no observer result was
returned before either hold expired. No edition, browser-window, or onboarding
visibility claim is therefore made. The single allowed coordination retry was
exhausted, and already-running and reopen were not attempted because the
mandatory visible cold gate remained incomplete.

| Browser | Mode/state | Selection | Receipt | Exact process identity | Sanitized visible evidence | Result |
| --- | --- | --- | --- | --- | --- | --- |
| Vivaldi Stable | Normal, cold | `selected` on both attempts | Fresh receipt on both attempts | E2E app and exact Vivaldi generation verified on both attempts | **NOT RUN — observer result unavailable within both bounds** | **AUTOMATED ROUTE PASS / VISIBLE GATE INCOMPLETE** |
| Vivaldi Stable | Normal, already running | Not attempted | Not attempted | Not attempted | Not attempted | **NOT RUN — stopped at visible cold gate** |
| Vivaldi Stable | Normal, reopen | Not attempted | Not attempted | Not attempted | Not attempted | **NOT RUN — stopped at visible cold gate** |

No profile or private target was created or attempted. No onboarding action,
sign-in, synchronization, import, or default-browser change was taken. This
entry contains no routed address, token, browser arguments, raw UI, screenshot,
or profile label. Driver cleanup and bounded quiescence found Vivaldi, E2E
PickVia, receiver, and driver absent after each cold route. Installed PickVia
remained the same exact pre-batch process generation, and preexisting temporary
roots were left untouched.

## Vivaldi Snapshot normal routing — 2026-08-22

Status: **FAIL at the cold receipt gate; already-running and reopen NOT RUN.**
The installed Vivaldi Snapshot 8.2.4133.24 build has bundle identifier
`com.vivaldi.Vivaldi.snapshot`, team `4XF3XNRN6Y`, passes strict deep signature
verification, and uses PickVia's browser-level normal Chromium
exact-application workspace strategy.

An initial CLI invocation supplied a non-absolute E2E application path and was
rejected as `driver-error` before any application or browser launch. It
contributed no routing evidence. From the unchanged empty Snapshot prestate,
the corrected production-driver cold route emitted `selected`, verified the
exact E2E app and exact Vivaldi Snapshot generation, and received no fresh
receiver receipt within 30 seconds. The driver ultimately reported
`cleanup-error` because the exact Snapshot generation remained after the
receipt failure.

One independent control bypassed PickVia and used the same exact-application
NSWorkspace delivery helper with a fresh receiver. The receiver became ready,
the helper compiled, and the exact Snapshot generation was verified; the helper
exited nonzero and the receiver obtained no receipt. The control therefore does
not isolate the missing receipt to PickVia's selection boundary.

| Browser | Mode/state | Selection | Receipt | Exact process identity | Sanitized visible evidence | Result |
| --- | --- | --- | --- | --- | --- | --- |
| Vivaldi Snapshot | Normal, cold | `selected` | No receipt within 30 seconds | E2E app and exact Vivaldi Snapshot generation verified | **NOT RUN — Vivaldi observer incompatibility** | **FAIL — cold receipt failure** |
| Vivaldi Snapshot | Normal, already running | Not attempted | Not attempted | Not attempted | **NOT RUN** | **NOT RUN — stopped at cold gate** |
| Vivaldi Snapshot | Normal, reopen | Not attempted | Not attempted | Not attempted | **NOT RUN** | **NOT RUN — stopped at cold gate** |

No Computer Use call was made for Snapshot, and the missing visible evidence is
not itself classified as a product failure. No onboarding action, profile, or
private target was created or attempted. This entry contains no routed address,
token, browser arguments, raw UI, screenshot, or profile label. Each sole
residual cold or control Snapshot generation received SIGTERM only after the
originally empty prestate plus its exact PID, start generation, executable,
bundle, team, and task-time start were revalidated; no SIGKILL was used. Bounded
absence and quiescence then found Vivaldi Snapshot, E2E PickVia, receiver,
helper, and driver absent. Installed PickVia remained the same exact pre-batch
process generation, and preexisting temporary roots were left untouched.

## Firefox normal routing — 2026-08-22

Status: **FAIL at the first attempted receipt or exact-generation gate for
Firefox Stable, Developer Edition, and Nightly.** All three installed bundles
pass strict deep signature verification, carry team `43AQ936H96`, and use
PickVia's normal Firefox launch strategy.

The read-only identity gate recorded Firefox Stable 153.0.3
(`org.mozilla.firefox`), Firefox Developer Edition 155.0
(`org.mozilla.firefoxdeveloperedition`), and Firefox Nightly 156.0a1
(`org.mozilla.nightly`).

| Browser | Mode/state | Selection | Receipt | Exact process identity | Sanitized visible evidence | Result |
| --- | --- | --- | --- | --- | --- | --- |
| Firefox Stable | Normal, cold | Not attempted | Not attempted | Exact preexisting Stable generation recorded | **NOT RUN** | **NOT RUN — preexisting browser state** |
| Firefox Stable | Normal, already running | `selected` | No receipt within 30 seconds | E2E app and same exact Stable generation verified | **NOT RUN — causal failure and observer incompatibility** | **FAIL — receipt failure** |
| Firefox Stable | Normal, reopen | Not attempted | Not attempted | Not attempted | **NOT RUN** | **NOT RUN — stopped at running gate** |
| Firefox Developer Edition | Normal, cold | `selected` | No receipt within 30 seconds | E2E app and exact Developer Edition generation verified | **NOT RUN — causal failure and observer incompatibility** | **FAIL — receipt failure** |
| Firefox Developer Edition | Normal, already running | Not attempted | Not attempted | Not attempted | **NOT RUN** | **NOT RUN — stopped at cold gate** |
| Firefox Developer Edition | Normal, reopen | Not attempted | Not attempted | Not attempted | **NOT RUN** | **NOT RUN — stopped at cold gate** |
| Firefox Nightly | Normal, cold | `selected` before final `identity-ambiguous` driver outcome | No receipt | Exact E2E app verified; multiple exact Nightly generations prevented exact browser proof | **NOT RUN — causal failure and observer incompatibility** | **FAIL — driver outcome `identity-ambiguous`** |
| Firefox Nightly | Normal, already running | Not attempted | Not attempted | Not attempted | **NOT RUN** | **NOT RUN — stopped at cold gate** |
| Firefox Nightly | Normal, reopen | Not attempted | Not attempted | Not attempted | **NOT RUN** | **NOT RUN — stopped at cold gate** |

Independent exact-application NSWorkspace controls for all three editions used
fresh receivers. Each receiver became ready, each helper compiled, and the
edition's exact application identity was verified; each helper exited nonzero
and no receiver obtained a receipt. The controls therefore do not isolate the
missing receipts to PickVia's selection boundary. The Stable control used the
recorded preexisting generation and preserved its exact PID and start generation
without signaling it. Across both the production already-running route and the
control, the preexisting Stable generation was never signaled.

No Computer Use call was made because the classified causal gates failed and a
Firefox observer was already known to exceed its bound. Missing visible evidence
is not itself classified as a product failure. No profile or private target was
created or attempted. This entry contains no routed address, token, browser
arguments, raw UI, screenshot, or profile label. Developer Edition and Nightly
task generations were cleaned only after exact identity and ownership checks;
the sole post-ambiguity Nightly survivor received SIGTERM after exact task-time
revalidation, and no SIGKILL was used. Final checks found Developer Edition,
Nightly, E2E PickVia, receiver, helper, and driver absent. The preexisting
Firefox Stable and installed PickVia generations remained unchanged, and
preexisting temporary roots were left untouched.

## Opera, Arc, and Orion normal routing — 2026-08-22

Status: **Opera and Arc NOT RUN because their installed bundles failed strict
deep signature verification; Orion's automated causal normal matrix passed but
its visible matrix remains incomplete.** All three use PickVia's normal
workspace launch strategy. The enhanced-capability probe evidence above remains
separate and is not reclassified by this normal matrix.

The read-only installed-identity gate recorded Opera 135.0
(`com.operasoftware.Opera`, team `A2P9LX4JPN`) and Arc 1.161.1
(`company.thebrowser.Browser`, team `S6N382Y83G`). Both strict deep signature
checks failed, and both exact process prestates were empty. Neither application
was launched, UI-observed, or mutated, and all three normal states remain NOT
RUN for those editions.

Orion 1.1.2 (`com.kagi.kagimacOS`, team `TFVG979488`) passed strict deep
signature verification and began from exact absence. An initial cold production
route emitted `selected`, received its fresh receipt, verified the exact E2E app
and exact Orion generation, exited successfully, and reached exact absence. A
second independent cold route repeated the complete causal proof and held the
exact generation for a bounded 240-second full-path observation. No observer
result arrived before the hold expired, and the driver ultimately reported
`cleanup-error`.
The exact generation exited naturally before the guarded external cleanup check;
bounded absence and quiescence then passed without signaling it.

The root observer returned only after the 240-second hold and route cleanup, so
its booleans were excluded. Its delayed full-path invocation left a separate
exact Orion generation that began after route cleanup. Because the original
Orion prestate was empty, that sole generation received SIGTERM only after its
exact PID, start generation, executable, bundle, team, and task-time start were
revalidated. No SIGKILL was used, and bounded absence plus quiescence passed.

From confirmed absence after that cleanup, the already-running state used one
exact task-created Orion baseline. Its production route emitted `selected`,
received a fresh receipt, verified the exact E2E app and the same baseline
generation, and exited successfully. The baseline was terminated only after its
exact PID and start generation were revalidated, and bounded quiescence
confirmed absence. The fresh reopen route then independently emitted
`selected`, received its fresh receipt, verified the exact E2E app and new exact
Orion generation, exited successfully, and reached exact absence.

| Browser | Mode/state | Selection | Receipt | Exact process identity | Sanitized visible evidence | Result |
| --- | --- | --- | --- | --- | --- | --- |
| Opera | Normal, cold/already running/reopen | Not attempted | Not attempted | Installed identity recorded; strict deep signature failed | **NOT RUN** | **NOT RUN — installation identity blocker** |
| Arc | Normal, cold/already running/reopen | Not attempted | Not attempted | Installed identity recorded; strict deep signature failed | **NOT RUN** | **NOT RUN — installation identity blocker** |
| Orion | Normal, cold | `selected` | Fresh receipt | E2E app and exact Orion generation verified | **NOT RUN — observer result unavailable within bound** | **AUTOMATED ROUTE PASS / VISIBLE NOT RUN** |
| Orion | Normal, already running | `selected` | Fresh receipt | E2E app and same exact task-created Orion baseline verified | **NOT RUN — causal-only continuation; observer not attempted** | **AUTOMATED ROUTE PASS / VISIBLE NOT RUN** |
| Orion | Normal, reopen | `selected` | Fresh receipt | E2E app and new exact Orion generation verified | **NOT RUN — causal-only continuation; observer not attempted** | **AUTOMATED ROUTE PASS / VISIBLE NOT RUN** |

No exact-application control was needed because every classified Orion
production route received its receipt. No onboarding action, account, sign-in,
profile, private target, or default-browser change was created or attempted.
This entry contains no
routed address, token, browser arguments, raw UI, screenshot, or profile label.
Final checks found Opera, Arc, Orion, E2E PickVia, receiver, and driver absent;
installed PickVia remained the same exact pre-batch generation, and preexisting
temporary roots were left untouched.

## DuckDuckGo private/Fire routing — 2026-08-22

Status: **cold PASS; already-running NOT RUN / HARNESS BLOCKED; reopen NOT
RUN.** DuckDuckGo 1.203.0 (`com.duckduckgo.macos.browser`, team `HKE973VLUW`)
passed strict deep signature verification and began from exact process absence.
The canonical private target used PickVia's managed DuckDuckGo Fire strategy;
no profile target was attempted.

The cold production route emitted `selected`, received its fresh receipt,
verified the exact E2E app and one exact DuckDuckGo generation, and exited
successfully. While that generation was held, sanitized isolation checks found
one managed session, a marker matching the exact process, no quarantine state,
an isolated home matching the process environment, and no normal-browser
fallback. Bounded full-path observation found the DuckDuckGo edition visible,
a browser window present, the private-or-Fire indicator visible, and onboarding
absent.

For the already-running setup, a separate production private route created and
held one exact managed Fire baseline. That setup route itself emitted
`selected`, received its fresh receipt, and verified the exact E2E app and exact
DuckDuckGo generation. The baseline retained the same exact process generation
and managed session throughout both classified attempts. The first classified
already-running invocation stopped with a helper error before selection,
receipt, or browser proof. The one authorized helper-only retry stopped at the
same preselection helper boundary. Accordingly, the already-running product
route was **not run** and is classified as a harness block, not a PickVia or
DuckDuckGo product failure. No UI observation was made for either invocation.
The reopen state was not attempted after that harness gate.

| Browser | Mode/state | Selection | Receipt | Exact process identity | Sanitized visible evidence | Result |
| --- | --- | --- | --- | --- | --- | --- |
| DuckDuckGo | Private/Fire, cold | `selected` | Fresh receipt | E2E app and one exact managed DuckDuckGo generation verified | Edition visible; window present; private-or-Fire indicator visible; onboarding absent | **PASS** |
| DuckDuckGo | Private/Fire, already running | Not reached; helper error on both attempts before selection | Not reached | Exact baseline remained unchanged; classified invocations produced no browser proof | **NOT RUN — harness blocked before observation** | **NOT RUN / HARNESS BLOCKED** |
| DuckDuckGo | Private/Fire, reopen | Not attempted | Not attempted | Not attempted | **NOT RUN** | **NOT RUN — stopped at running harness gate** |

After each successful setup or cold route reached exact browser absence, only
its validated task-owned managed session was removed. The preexisting managed
root was restored as the same real, empty directory. Final checks found
DuckDuckGo, E2E PickVia, receiver, helper, and driver absent; installed PickVia
remained the same exact pre-batch generation. This entry contains no routed
address, token, browser arguments, raw UI, screenshot, or profile label.

## Brave private routing — 2026-08-22

Status: **Brave Stable NOT RUN at the installation-identity gate; Brave Beta
and Nightly FAIL at the cold causal gate.** No Brave profile target was created
or attempted, and neither eligible edition advanced to already-running or
reopen.

Brave Stable 151.1.93.138 (`com.brave.Browser`, team `KL8N8XSYF4`) again failed
strict deep signature verification. Its exact preexisting process generation
was recorded and preserved without signaling it. Stable received no private
route, process launch, or UI observation.

Brave Beta 152.1.95.87 (`com.brave.Browser.beta`, team `KL8N8XSYF4`) and Brave
Nightly 152.1.96.6 (`com.brave.Browser.nightly`, team `KL8N8XSYF4`) passed
strict deep signature verification and each began from exact process absence.
Each canonical browser-level private production route verified the exact E2E
app but stopped with an exact-browser identity ambiguity before any fresh
receiver receipt. Exact browser proof was therefore false for each classified
route. Neither route reached the guarded visible-observation gate, and neither
failure is presented as proof that Brave's private transport itself is broken.

| Browser | Mode/state | Selection | Receipt | Exact process identity | Sanitized visible evidence | Result |
| --- | --- | --- | --- | --- | --- | --- |
| Brave Stable | Private, cold/already running/reopen | Not attempted | Not attempted | Installed identity and exact preexisting generation recorded; strict deep signature failed | **NOT RUN** | **NOT RUN — installation identity blocker** |
| Brave Beta | Private, cold | Not authoritatively retained before the identity gate | No receipt | Exact E2E app verified; exact browser proof false after generation ambiguity | **NOT RUN — causal gate failed** | **FAIL — identity-ambiguous before receipt** |
| Brave Beta | Private, already running | Not attempted | Not attempted | Not attempted | **NOT RUN** | **NOT RUN — stopped at cold gate** |
| Brave Beta | Private, reopen | Not attempted | Not attempted | Not attempted | **NOT RUN** | **NOT RUN — stopped at cold gate** |
| Brave Nightly | Private, cold | Not authoritatively retained before the identity gate | No receipt | Exact E2E app verified; exact browser proof false after generation ambiguity | **NOT RUN — causal gate failed** | **FAIL — identity-ambiguous before receipt** |
| Brave Nightly | Private, already running | Not attempted | Not attempted | Not attempted | **NOT RUN** | **NOT RUN — stopped at cold gate** |
| Brave Nightly | Private, reopen | Not attempted | Not attempted | Not attempted | **NOT RUN** | **NOT RUN — stopped at cold gate** |

Independent exact-executable private controls then ran from confirmed absence
for Beta and Nightly. Each used a fresh bounded receiver, verified one exact
edition generation, and received its fresh receipt. These controls demonstrate
that both installed editions can deliver the private control route outside
PickVia, while leaving the production driver's exact-generation attribution
failure unresolved. No visible evidence was collected from a control.

After each production failure, its sole residual edition generation was
sent SIGTERM only after the originally empty prestate and exact task generation
were revalidated. Each direct control likewise used one guarded bounded
SIGTERM attempt; subsequent bounded absence and quiescence checks passed. No
SIGKILL was used. Final checks found Brave Beta, Brave Nightly, E2E PickVia,
receiver, helper, and driver absent. The exact preexisting Brave Stable and
installed PickVia generations remained unchanged. This entry contains no
routed address, token, browser arguments, raw UI, screenshot, or profile label.

## Vivaldi private routing — 2026-08-22

Status: **Vivaldi Stable and Snapshot FAIL at the cold causal gate; their
already-running and reopen states are NOT RUN.** Both editions use PickVia's
browser-level private Chromium launch strategy. No profile target was created
or attempted.

Vivaldi Stable 8.1.4087.70 (`com.vivaldi.Vivaldi`, team `4XF3XNRN6Y`) and
Vivaldi Snapshot 8.2.4133.24 (`com.vivaldi.Vivaldi.snapshot`, team
`4XF3XNRN6Y`) passed strict deep signature verification and each began from
exact process absence. Each canonical private production route verified the
exact E2E app but stopped with an exact-browser identity ambiguity before any
fresh receiver receipt. Exact browser proof was therefore false for both
classified routes, and neither edition advanced beyond cold.

| Browser | Mode/state | Selection | Receipt | Exact process identity | Sanitized visible evidence | Result |
| --- | --- | --- | --- | --- | --- | --- |
| Vivaldi Stable | Private, cold | Not authoritatively retained before the identity gate | No receipt | Exact E2E app verified; exact browser proof false after generation ambiguity | **NOT RUN — known Vivaldi observer incompatibility and failed causal gate** | **FAIL — identity-ambiguous before receipt** |
| Vivaldi Stable | Private, already running | Not attempted | Not attempted | Not attempted | **NOT RUN** | **NOT RUN — stopped at cold gate** |
| Vivaldi Stable | Private, reopen | Not attempted | Not attempted | Not attempted | **NOT RUN** | **NOT RUN — stopped at cold gate** |
| Vivaldi Snapshot | Private, cold | Not authoritatively retained before the identity gate | No receipt | Exact E2E app verified; exact browser proof false after generation ambiguity | **NOT RUN — known Vivaldi observer incompatibility and failed causal gate** | **FAIL — identity-ambiguous before receipt** |
| Vivaldi Snapshot | Private, already running | Not attempted | Not attempted | Not attempted | **NOT RUN** | **NOT RUN — stopped at cold gate** |
| Vivaldi Snapshot | Private, reopen | Not attempted | Not attempted | Not attempted | **NOT RUN** | **NOT RUN — stopped at cold gate** |

Independent exact-executable private controls then ran from confirmed absence
with fresh bounded receivers. Stable verified one exact generation and received
its fresh receipt, demonstrating that its installed private transport works
outside PickVia while leaving the production driver's generation-attribution
failure unresolved. Snapshot also verified one exact generation but received
no receipt within the bound, so its missing receipt is not isolated to PickVia.
No Computer Use call was made and no visible evidence was collected; that
missing visible evidence is not itself classified as a product failure.

After each production failure, its sole residual edition generation received
SIGTERM only after the originally empty prestate and exact task generation were
revalidated. Each control likewise used one guarded bounded SIGTERM attempt;
subsequent bounded absence and quiescence checks passed, including Snapshot's
delayed exit after its first cleanup check. No SIGKILL was used. Final checks
found Vivaldi Stable, Vivaldi Snapshot, E2E PickVia, receiver, helper, and driver
absent. Installed PickVia remained the same exact pre-batch generation. This
entry contains no routed address, token, browser arguments, raw UI, screenshot,
or profile label.

## Firefox private routing — 2026-08-22

Status: **FAIL at the receipt gate for Firefox Stable, Developer Edition, and
Nightly.** All three installed editions passed strict deep signature
verification and use PickVia's browser-level Firefox private-window strategy.
No profile target was created or attempted.

The read-only identity gate recorded Firefox Stable 153.0.3
(`org.mozilla.firefox`), Firefox Developer Edition 155.0
(`org.mozilla.firefoxdeveloperedition`), and Firefox Nightly 156.0a1
(`org.mozilla.nightly`), all with team `43AQ936H96`. Stable began with one exact
preexisting generation, so a cold state was not claimable. Its already-running
private production route emitted `selected`, verified the exact E2E app and the
same exact Stable generation, and received no fresh receipt within 30 seconds.
The exact Stable PID and start generation remained unchanged and was never
signaled.

Developer Edition and Nightly each began from exact absence. Each cold private
production route emitted `selected`, verified the exact E2E app and an exact
edition generation, and received no fresh receipt within 30 seconds. Each
driver then restored exact edition absence. Neither edition advanced to
already-running or reopen.

| Browser | Mode/state | Selection | Receipt | Exact process identity | Sanitized visible evidence | Result |
| --- | --- | --- | --- | --- | --- | --- |
| Firefox Stable | Private, cold | Not attempted | Not attempted | Exact preexisting Stable generation recorded | **NOT RUN** | **NOT RUN — preexisting browser state** |
| Firefox Stable | Private, already running | `selected` | No receipt within 30 seconds | E2E app and same exact Stable generation verified | **NOT RUN — causal failure and known observer incompatibility** | **FAIL — receipt failure** |
| Firefox Stable | Private, reopen | Not attempted | Not attempted | Not attempted | **NOT RUN** | **NOT RUN — stopped at running gate** |
| Firefox Developer Edition | Private, cold | `selected` | No receipt within 30 seconds | E2E app and exact Developer Edition generation verified | **NOT RUN — causal failure and known observer incompatibility** | **FAIL — receipt failure** |
| Firefox Developer Edition | Private, already running | Not attempted | Not attempted | Not attempted | **NOT RUN** | **NOT RUN — stopped at cold gate** |
| Firefox Developer Edition | Private, reopen | Not attempted | Not attempted | Not attempted | **NOT RUN** | **NOT RUN — stopped at cold gate** |
| Firefox Nightly | Private, cold | `selected` | No receipt within 30 seconds | E2E app and exact Nightly generation verified | **NOT RUN — causal failure and known observer incompatibility** | **FAIL — receipt failure** |
| Firefox Nightly | Private, already running | Not attempted | Not attempted | Not attempted | **NOT RUN** | **NOT RUN — stopped at cold gate** |
| Firefox Nightly | Private, reopen | Not attempted | Not attempted | Not attempted | **NOT RUN** | **NOT RUN — stopped at cold gate** |

Independent exact-executable private-window controls for all three editions
used fresh bounded receivers and verified exact edition activity; none received
a receipt. The controls therefore do not isolate the missing private receipts
to PickVia's selection boundary. Stable's transient control generation exited
without signaling the exact preexisting generation. Developer Edition and
Nightly control generations were terminated only after exact task ownership
was established; guarded SIGTERM cleanup plus bounded absence and quiescence
passed. No SIGKILL was used.

No Computer Use call was made because every causal gate failed and the Firefox
observer is known to exceed its bound. Missing visible evidence is not itself
classified as a product failure. Final checks found Developer Edition, Nightly,
E2E PickVia, receiver, helper, and driver absent. The exact preexisting Firefox
Stable and installed PickVia generations remained unchanged. This entry
contains no routed address, token, browser arguments, raw UI, screenshot, or
profile label.

## Microsoft Edge private routing — 2026-08-22

Status: **Edge Dev and Canary PASS in cold, already-running, and reopen;
Edge Stable FAILS the cold receipt gate; Edge Beta is HARNESS INVALID after its
cleanup-only retry lost exact-generation uniqueness.** No profile target was
created or attempted.

All four installed applications passed the exact app/executable binding and
team identity gates. The recorded identities are Microsoft Edge Stable
151.0.4129.101 (`com.microsoft.edgemac`), Edge Beta 152.0.4191.41
(`com.microsoft.edgemac.Beta`), Edge Dev 153.0.4224.0
(`com.microsoft.edgemac.Dev`), and Edge Canary 153.0.4233.0
(`com.microsoft.edgemac.Canary`); each is signed by team `UBF8T346G9`. Each
edition began from exact process absence and was isolated from every other
channel.

The canonical browser-level private targets were
`com.microsoft.edgemac||private`, `com.microsoft.edgemac.Beta||private`,
`com.microsoft.edgemac.Dev||private`, and
`com.microsoft.edgemac.Canary||private`, respectively.

Edge Stable's initial cold command did not return a driver report through the
command handoff, although exact post-run process and task-root checks passed.
The one authorized harness retry emitted `selected`, verified the exact E2E app
and exact Stable generation, and received no fresh receipt within 30 seconds.
That cold cell is therefore a product receipt failure. Per the cold gate, no
visible observation or later Stable state was attempted.

Edge Beta's first cold route emitted `selected`, received a fresh receipt, and
verified both exact process identities, but the driver returned `cleanup-error`.
Exact post-run checks found no Beta, E2E, receiver, or fresh task-root state, so
the one cleanup-only retry was allowed. That retry stopped as
`identity-ambiguous` before a receipt and left one exact task-time Beta
generation. The survivor was terminated only after its exact PID, start
generation, and executable were revalidated; bounded absence then passed.
Because neither attempt supplied the complete causal-plus-cleanup proof, the
cold cell is harness-invalid rather than a product pass or failure, and no UI
or later Beta state was attempted.

Edge Dev's first cold route similarly reached `selected`, a fresh receipt, and
both exact identities before a cleanup-only error; exact post-run absence
qualified it for the sole retry. The retry passed every automated gate. Its
exact generation was held only for a bounded full-path read-only observation,
then released to the driver's verified cleanup. The already-running route used
one separately recorded exact task baseline, produced a fresh receipt against
that same generation, and preserved it for observation. After exact
generation revalidation the baseline was terminated; the reopen route then
proved a new exact generation and fresh receipt. All three observations found
the correct Dev channel, a browser window, an InPrivate indicator, and no
onboarding.

Edge Canary passed the same three-state sequence without a route retry. Its
task-created already-running baseline remained the same exact generation for
the fresh receipt and observation. Graceful termination exceeded the initial
five-second poll, but an immediate exact-generation recheck found it gone; the
reopen route began only after channel absence was reconfirmed. All three
full-path observations found the correct Canary channel, a browser window, an
InPrivate indicator, and no onboarding.

| Browser | Mode/state | Selection | Receipt | Exact process identity | Sanitized visible evidence | Result |
| --- | --- | --- | --- | --- | --- | --- |
| Microsoft Edge Stable | Private, cold | `selected` on the classified retry | No receipt within 30 seconds | E2E app and exact Stable generation verified | **NOT RUN — stopped at causal gate** | **FAIL — cold receipt failure** |
| Microsoft Edge Stable | Private, already running | Not attempted | Not attempted | Not attempted | **NOT RUN** | **NOT RUN — stopped at cold gate** |
| Microsoft Edge Stable | Private, reopen | Not attempted | Not attempted | Not attempted | **NOT RUN** | **NOT RUN — stopped at cold gate** |
| Microsoft Edge Beta | Private, cold | `selected` on the first attempt; retry ended `identity-ambiguous` | Fresh receipt on the cleanup-invalid first attempt; none on retry | Exact identities on the first attempt; exact-generation uniqueness failed on retry | **NOT RUN — harness-invalid causal/cleanup proof** | **HARNESS INVALID** |
| Microsoft Edge Beta | Private, already running | Not attempted | Not attempted | Not attempted | **NOT RUN** | **NOT RUN — stopped at cold harness gate** |
| Microsoft Edge Beta | Private, reopen | Not attempted | Not attempted | Not attempted | **NOT RUN** | **NOT RUN — stopped at cold harness gate** |
| Microsoft Edge Dev | Private, cold | `selected` | Fresh receipt | E2E app and exact Dev generation verified | Correct Dev channel; window present; InPrivate indicator present; onboarding absent | **PASS** |
| Microsoft Edge Dev | Private, already running | `selected` | Fresh receipt | E2E app and same exact task-created Dev baseline verified | Correct Dev channel; window present; InPrivate indicator present; onboarding absent | **PASS** |
| Microsoft Edge Dev | Private, reopen | `selected` | Fresh receipt | E2E app and new exact Dev generation verified | Correct Dev channel; window present; InPrivate indicator present; onboarding absent | **PASS** |
| Microsoft Edge Canary | Private, cold | `selected` | Fresh receipt | E2E app and exact Canary generation verified | Correct Canary channel; window present; InPrivate indicator present; onboarding absent | **PASS** |
| Microsoft Edge Canary | Private, already running | `selected` | Fresh receipt | E2E app and same exact task-created Canary baseline verified | Correct Canary channel; window present; InPrivate indicator present; onboarding absent | **PASS** |
| Microsoft Edge Canary | Private, reopen | `selected` | Fresh receipt | E2E app and new exact Canary generation verified | Correct Canary channel; window present; InPrivate indicator present; onboarding absent | **PASS** |

The visual checks retained only the booleans represented above; no underlying
UI state or screenshot was emitted or recorded. No sign-in, default-browser,
onboarding, account, or profile action was taken. Fresh post-matrix gates passed
57/57 driver tests, 15/15 receiver tests, the added-line privacy scan, and the
diff check. The final exact process and temporary-state gate found all four
Edge editions, E2E PickVia, receivers, helpers, fresh task roots, and hold
markers absent. This entry contains no routed address, token, browser
arguments, raw UI, screenshot, or profile label. Installed PickVia and
preexisting temporary roots were left untouched.

## Google Chrome private routing — 2026-08-22

Status: **all states NOT RUN. Chrome Stable and Beta are installation-identity
blocked; Chrome Dev and Canary are harness-blocked before selection in cold.**
No profile target was created or attempted, and neither preselection outcome is
classified as a PickVia or browser product failure.

Fresh installed-identity checks recorded Google Chrome Stable 151.0.7922.172
(`com.google.Chrome`), Chrome Beta 153.0.8010.5
(`com.google.Chrome.beta`), Chrome Dev 154.0.8013.2
(`com.google.Chrome.dev`), and Chrome Canary 154.0.8018.0
(`com.google.Chrome.canary`); each reports team `EQHXZ8M8AV`. Stable and Beta
failed strict deep code-signature verification, so their designated
requirements and all private launch states were not run. Dev and Canary passed
strict deep verification and their own designated requirements.

The canonical browser-level targets were `com.google.Chrome||private`,
`com.google.Chrome.beta||private`, `com.google.Chrome.dev||private`, and
`com.google.Chrome.canary||private`, respectively. Before the classified Dev
and Canary routes, the rebuilt E2E executable's canonical path, inode, and
SHA-256 were pinned. All three values matched immediately before and after each
route, and no build or isolation process ran during the matrix.

The one classified Dev cold route verified the exact E2E application identity
but ended `process-error` before `selected`, a receipt, or exact browser-process
proof. Exact Dev absence passed afterward. The one classified Canary cold route
reached the same bounded preselection result with exact E2E identity verified,
no receipt, and no browser generation observed; exact Canary absence also
passed afterward. Per the cold gate, already-running and reopen were not run.
Because neither route crossed the causal gate, no Computer Use observer was
attached and no edition, window, Incognito, or onboarding boolean was borrowed
from the normal matrix.

| Browser | Mode/state | Selection | Receipt | Exact process identity | Sanitized visible evidence | Result |
| --- | --- | --- | --- | --- | --- | --- |
| Google Chrome Stable | Private, cold | Not attempted | Not attempted | Installed signature invalid | **NOT RUN** | **NOT RUN — installation identity blocker** |
| Google Chrome Stable | Private, already running | Not attempted | Not attempted | Installed signature invalid | **NOT RUN** | **NOT RUN — installation identity blocker** |
| Google Chrome Stable | Private, reopen | Not attempted | Not attempted | Installed signature invalid | **NOT RUN** | **NOT RUN — installation identity blocker** |
| Google Chrome Beta | Private, cold | Not attempted | Not attempted | Installed signature invalid | **NOT RUN** | **NOT RUN — installation identity blocker** |
| Google Chrome Beta | Private, already running | Not attempted | Not attempted | Installed signature invalid | **NOT RUN** | **NOT RUN — installation identity blocker** |
| Google Chrome Beta | Private, reopen | Not attempted | Not attempted | Installed signature invalid | **NOT RUN** | **NOT RUN — installation identity blocker** |
| Google Chrome Dev | Private, cold | Not reached; driver ended `process-error` | Not reached | Exact E2E app verified; no browser generation observed | **NOT RUN — harness blocked before observation** | **NOT RUN / HARNESS BLOCKED** |
| Google Chrome Dev | Private, already running | Not attempted | Not attempted | Not attempted | **NOT RUN** | **NOT RUN — stopped at cold harness gate** |
| Google Chrome Dev | Private, reopen | Not attempted | Not attempted | Not attempted | **NOT RUN** | **NOT RUN — stopped at cold harness gate** |
| Google Chrome Canary | Private, cold | Not reached; driver ended `process-error` | Not reached | Exact E2E app verified; no browser generation observed | **NOT RUN — harness blocked before observation** | **NOT RUN / HARNESS BLOCKED** |
| Google Chrome Canary | Private, already running | Not attempted | Not attempted | Not attempted | **NOT RUN** | **NOT RUN — stopped at cold harness gate** |
| Google Chrome Canary | Private, reopen | Not attempted | Not attempted | Not attempted | **NOT RUN** | **NOT RUN — stopped at cold harness gate** |

No sign-in, account, profile, default-browser, or onboarding action was taken.
Stable was never targeted and one exact Stable generation remained present;
Beta remained absent. Final exact checks found Dev, Canary, E2E PickVia,
receiver, helper, driver, fresh task roots, and hold markers absent. This entry
contains no routed address, token, browser arguments, raw UI, screenshot, or
profile label. Installed PickVia and preexisting temporary roots were left
untouched.
