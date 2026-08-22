# Browser Compatibility Evidence — 2026-08-21

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
