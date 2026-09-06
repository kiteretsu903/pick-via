# Browser Computer E2E — 2026-09-05

**Later update:** [All seven failed cases passed on retry](browser-computer-e2e-2026-09-05-retry.md), including Firefox Stable’s authorized cold-profile retry. A Firefox path-normalization fix is now present. The matrix below records the earlier attempt. Strict signature checks are discontinued for this workflow.

**Manual matrix attempt closed with failures and blocked cases. This is not release acceptance or a fully passing compatibility certification.**

The user requested native Computer testing in the `browser-editions-and-families` worktree, replacing automatic chooser selection. The run continued into 2026-09-06 UTC (still September 5 locally). A dedicated desktop testing period and normal Quit of Chrome/Brave were authorized; later active user browsing was preserved. Setup instructions were to disable default-browser changes and optional diagnostics/experience programs, skip imports, and stay signed out.

**159 eligible cells: 125 PASS, 7 FAIL, 27 NOT RUN / blocked / unverified.** PASS means the requested local page was actually observed through Computer, with mode/profile evidence where applicable. It does not certify latency, absence of first-run dialogs, clean privacy behavior, or all versions installed during this run.

Working HEAD: `263e1c4997b5ceade188bc6ef2953b126d4c564a`; branch `feature/browser-editions-and-families`. Only manual E2E UI hooks, their composition test, and this report were changed. No capability policy was changed; nothing was committed, pushed, released, or installed over production PickVia.

## Cell results

Entries are **cold / running / reopen**. Numbers are verified receiver receipts; `F` is an observed test failure and `N` is blocked or not reliably verified. `—` is unsupported by the checked capability policy. First-run setup assistance, delays, retries and version changes are qualified below.

| Browser | Normal | Private | Isolated profile |
|---|---|---|---|
| Google Chrome | 114 / 115 / 116 | 15 / 12 / 16 | 141 / 142 / 143 |
| Google Chrome Beta | 108 / 109 / 112 | 110 / 111 / 113 | 144 / 151 / 150 |
| Google Chrome Dev | 35 / 36 / 43 | 39 / 40 / 47 | 152 / 153 / 154 |
| Google Chrome Canary | 37 / 38 / 84 | 41 / 42 / 48 | 155 / 156 / 157 |
| Microsoft Edge | 6 / 8 / 10 | 13 / 14 / 17 | 18 / 19 / 22 |
| Microsoft Edge Beta | 49 / 50 / 58 | 51 / 52 / 67 | 158 / 159 / 160 |
| Microsoft Edge Dev | 63 / 64 / 68 | 59 / 60 / 70 | 162 / 163 / 164 |
| Microsoft Edge Canary | 65 / 66 / 69 | 61 / 62 / 71 | 166 / 167 / 168 |
| Brave Browser | N / N / N | N / N / N | N / N / N |
| Brave Browser Beta | F / F / N | 134 / 171 / 172 | 173 / 174 / 176 |
| Brave Browser Nightly | N / N / 82 | 78 / 79 / 83 | F / F / 178 |
| Vivaldi | 127 / 128 / 132 | 129 / 130 / 133 | 180 / 181 / 183 |
| Vivaldi Snapshot | 147 / 184 / N | 187 / 188 / N | N / N / N |
| Firefox | 135 / 136 / 139 | 137 / 138 / 140 | F / N / N |
| Firefox Developer Edition | 96 / 97 / 107 | 100 / 101 / 104 | F / N / N |
| Firefox Nightly | 98 / 99 / 106 | 102 / 103 / 105 | F / N / N |
| Opera | N / N / N | — | — |
| Arc | N / 118 / 119 | — | — |
| Orion | 120 / 121 / 124 | — | — |
| DuckDuckGo | 26 / 30 / 29 | 32 / 33 / 34 | — |

The [JSON](browser-computer-e2e-2026-09-05-results.json) and [CSV](browser-computer-e2e-2026-09-05-results.csv) contain all 159 cells, exact request identifiers where available, receive times, initial/final installed versions, and reasons for failed or blocked cells. Safari and Safari Technology Preview were skipped by user decision. Chromium was not installed or run. Profile-private routes are unsupported for every included descriptor and were not attempted; this is capability-policy evidence, not browser incompatibility evidence.

## Findings

### Firefox isolated profiles: path-validation integration failure

Stable, Developer Edition and Nightly displayed **“Could not open the selected browser target.”** Stable reproduced this with both a hand-seeded fixture and a browser-created `-CreateProfile` fixture. Developer Edition and Nightly also failed with a normal browser instance running and after a normal Quit. Those retries do not establish the required isolated-profile running/reopen lifecycle, so dependent cells remain NOT RUN.

A direct local Foundation probe reproduces a relevant path mismatch:

```text
Input:                   /private/tmp/pickvia-e2e-computer-cc5zt84r/profiles/firefox-nightly-profile/PickVia E2E
URL.standardizedFileURL: /tmp/pickvia-e2e-computer-cc5zt84r/profiles/firefox-nightly-profile/PickVia E2E
POSIX realpath:          /private/tmp/pickvia-e2e-computer-cc5zt84r/profiles/firefox-nightly-profile/PickVia E2E
```

`FirefoxProfileParser` standardizes the discovered profile URL, while `FoundationBrowserProfileLaunchPathValidator.capture` requires `realpath(candidate) == candidate.path`. The standardized temporary profile path therefore fails that guard. This explains why these fixture paths cannot pass launch validation; it does not establish that ordinary Firefox profiles elsewhere are unsupported. No capability was downgraded. No production fix was made during the original matrix attempt; the linked retry documents the later path fix.

### Brave delivery and Snapshot/Arc startup reliability

- Updated Brave Beta normal cold/running attempts remained blank or undelivered. A prior direct Reload produced receipt 91, which is diagnostic only; prior current-build running receipt 92 succeeded. Reopen verification was ambiguous. Its private route recovered after Computer attachment delays (134/171/172), and its fresh isolated profile passed after settling (173/174/176).
- Updated Brave Nightly normal cold/running requests showed blank/restored windows without a verified matching page. Earlier 74/75 were on the old build and are not substituted. The isolated profile's first two requests stayed blank; normal Quit/reopen delivered 178 and a later running retry delivered 179. The initial failed cells remain failures.
- Snapshot eventually delivered an earlier normal cold request as 147, but verification was delayed and the browser updated. Private cold/running 187/188 worked on the updated build. Later normal reopen and fresh isolated-profile startup were stuck, with repeated Computer timeouts. Exact task processes 24332 and 24589 required Activity Monitor Force Quit after normal Quit failed. Dependent cells remain blocked.
- Arc running/reopen 118/119 were observed earlier. The later cold attempt after an update could not be inspected through Computer and was closed normally through Activity Monitor. No pass is inferred from a live process.
- Orion's first launch required dismissing a prior-launch problem notice. Its first reopen showed older restored test tabs; a fresh retry delivered 124. This recovery is retained, not presented as an uninterrupted run.
- Brave Stable had both the user's active session and an extra test process. Computer selected the user session. The test process was closed by exact PID; the user's session was preserved, and all nine stable-browser cells remain unverified.

### Signatures and macOS privacy notifications

“Strict signature check” here means `codesign --verify --deep --strict`: verify nested signed code and apply additional structural/metadata restrictions. Initially Chrome Stable/Beta, Brave Stable and Arc failed strict verification due resource-fork/Finder metadata but passed ordinary `--deep` verification. Updated Brave Beta/Nightly also had metadata-only strict failures and passed ordinary verification. Updated Firefox, Vivaldi and Snapshot passed strict verification. **Opera failed ordinary and strict verification on a sealed Opera Framework resource and was not run.** No browser signatures, quarantine flags, browser bundles or permissions were altered to bypass these checks.

macOS blocked protected app-data and app-modification accesses attributed to “PickVia Computer E2E.” Bounded TCC logs showed Firefox crashhelper activity attributed to the responsible E2E parent, plus app-bundle checks involving parent/browser processes. Exact paths for every notification were not established. No additional privacy permissions were granted. A clean privacy audit is **not** claimed. Disposable profile paths and `CFFIXED_USER_HOME` are not a security sandbox; browsers still showed system account suggestions and made their own background/start-page/update requests. No account was signed in or import initiated by the agent. The local test page itself made no external requests.

## Evidence qualifications

- Computer operated the real chooser and native browser UI. Receiver entries alone, process existence, restored tabs and direct browser reloads were insufficient for PASS. Profile paths were additionally checked for representative Chromium-family launches.
- The original receiver was single-threaded and could stall on preconnections; it was replaced with `ThreadingHTTPServer`. From receipt 28, each chooser request included a fresh UUID. Earlier receipts have weaker request disambiguation and are retained only where a distinct delivery was observed.
- Setup-assisted cold receipts include Edge 18, Chrome 141, Chrome Beta 144, Chrome Dev 152, Canary 155, Edge Beta 158, Firefox 135, Firefox Nightly 98 and Orion 120. Edge Dev/Canary profile cold checks 162/166 and Vivaldi profile cold 180 were made after setup and normal Quit.
- Chrome Beta profile 145 reached the receiver but Computer returned an empty tree. Exact disposable process 15148 exited after Activity Monitor normal Quit; fresh reopen 150 and running retry 151 were verified.
- Vivaldi normal cold 127 was behind a What's New tab and was verified by selecting the matching tab. Its interrupted private request `59477004` was excluded; retry 130 passed. Nightly private receipt 105 was verified visually when the page content was absent from the accessibility tree.
- Excluded: Chrome private receipt 1 was a normal user window; Edge 9 did not prove Quit/reopen; repeated DuckDuckGo 26 did not prove a fresh delivery; 31 was an accidentally selected retained Edge synthetic profile; Chrome Canary 46 was restored old content. Corrected Canary normal reopen 84 was verified.
- Browser versions changed during restarts. Results are a multi-version functional run, **not** one stable-build certification. Initial/final versions are recorded per cell; they do not pretend to be exact per-cell live-code attestations. Historical Brave Beta 72/73/76/77 and Brave Nightly 74/75 are not substituted for later failed/unverified normal cases.
- The manual run bypassed the automatic E2E chooser wrapper by explicit opt-in. Its fixed provenance context does not authenticate arbitrary manual selections. This report is separate from the old automated matrix and does not replace that report's authenticated evidence chain.
- Windows were moved to HUYAN using native Window menu actions where supported. Computer input is not monitor-isolated; uninterrupted simultaneous work on other displays cannot be guaranteed. Later active user browser generations were left alone.

## Build and cleanup

- E2E-flagged `AppCompositionTests`: **23 passed**, including explicit manual-chooser opt-in and default automatic-wrapper behavior.
- Production and E2E release builds with warnings-as-errors: **passed**. `swift format` and `git diff --check`: **passed**. The full historical automated harness suites were not rerun or represented as current results.
- Production binary contains none of `PICKVIA_E2E_MANUAL_UI`, `PICKVIA_E2E_MANUAL_URL`, or `Open Local E2E Test Page`.
- Final rebuilt/staged E2E app delivered fresh Edge receipt **189** (`4DEC9951-FFB3-4D49-83E8-4E8D98FFA71F`) through the real chooser, then both apps were quit.
- Receiver stopped. Final process audit found only non-task-owned Chrome, the preserved Brave user session, and installed production PickVia among the scoped app names. Arc and the extra Brave test process exited after Activity Monitor normal Quit; stuck Snapshot task processes required Force Quit. Activity Monitor's original `tail` filter was restored. No retained or ambiguous artifact roots were deleted.
- Private evidence remains at `/private/tmp/pickvia-e2e-computer-cc5zt84r`: receiver records, synthetic profiles, setup artifacts, build logs and private OS logs. Do not publish raw profiles, bookmark grants or OS logs. Temporary-directory retention is not guaranteed.

Remaining acceptance work is concrete: resolve the Firefox temporary-path validation mismatch; investigate Brave intermittent delivery and Snapshot/Arc startup failures; schedule noninterfering Brave Stable coverage; then rerun failed/blocked cells on fixed, recorded browser versions. Do not release or advertise universal compatibility from this run.
