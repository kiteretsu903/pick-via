# Browser Computer E2E — seven-case retry

**All seven previously failed cases passed on retry. Firefox Stable completed the final cold-profile case after the user authorized normal Quit of its existing session.** No strict signature verification was used. These results supplement the [original matrix](browser-computer-e2e-2026-09-05.md); original observations are retained rather than erased.

| Browser | Case | Retry outcome | Receipt |
|---|---|---|---:|
| Brave Beta 152.1.95.96 | Normal, cold | PASS after startup settled, without Reload | 192 |
| Brave Beta 152.1.95.96 | Normal, running | PASS | 195 |
| Brave Nightly 153.1.97.8 | Isolated profile, cold | PASS with a fresh fixture | 198 |
| Brave Nightly 153.1.97.8 | Isolated profile, running | PASS | 199 |
| Firefox 154.0.1 | Isolated profile, cold | PASS after path fix and setup | 200 |
| Firefox Developer Edition 156.0 | Isolated profile, cold | PASS after path fix and setup | 196 |
| Firefox Nightly 157.0a1 | Isolated profile, cold | PASS after path fix and setup | 197 |

Exact requests and receive times are in the [retry JSON](browser-computer-e2e-2026-09-05-retry.json). Developer Edition and Nightly updated since the original matrix, so these are results for the versions listed above.

## Why the original cases failed

**Firefox: confirmed path-normalization bug.** `FirefoxProfileParser` used `standardizedFileURL`, which rewrote an existing physical `/private/tmp/...` fixture path as `/tmp/...`. Launch validation then rejected it because its physical path differed. A new integration regression reproduced the rejection before the change. Switching discovery and install-default URL normalization to `URL.standardized` preserves the physical prefix while normalizing URL components. Opaque identity generation and launcher validation are unchanged. The regression also confirms that an actual symbolic-link profile is still rejected.

Stable, Developer Edition and Nightly then successfully opened their exact disposable profiles through the real PickVia chooser. Their process arguments included the intended `-profile /private/tmp/...` paths. For Stable, the existing session was closed normally with explicit user authorization, and a process check confirmed no Stable process remained before launch. The new process used `profiles/firefox-stable-final-retry/PickVia E2E`; Computer verified the exact request URL and visible Receipt 200 after setup. The local receiver independently recorded the same request.

**Brave: earlier blank observations were not enough to establish persistent routing failure.** Beta initially appeared blank again, then the original cold request and the running request loaded without direct Reload. Nightly's fresh-profile cold request reached the receiver about 5.3 seconds after beginning the chooser command; running delivery took about 2.1 seconds including chooser interaction. Both pages were verified in Computer, and the Profiles menu identified “PickVia E2E.” No Brave-specific product fix was made. The deeper cause of the earlier stalls remains unproven; startup delays, restored windows and attachment ambiguity are observations, not a confirmed browser defect. Nightly still displayed its profile-data/encryption relaunch notice, so this is functional routing evidence, not a clean profile/privacy certification.

## Verification and limitations

- Production-mode parser/catalog/launcher tests: **195 passed**.
- E2E-mode selected tests: **45 XCTest + 95 Swift Testing tests passed**, including composition, profile grants, parser and launcher behavior.
- Production and E2E release builds with warnings-as-errors passed. The fixed E2E binary was staged into the temporary test app and exercised through Computer. Installed production PickVia was not replaced; no commit, push or release was made.
- Firefox diagnostics, studies, personalized recommendations, remote feature experiments, daily usage reporting and automatic crash reporting were confirmed off in the tested disposable Stable/Developer/Nightly profiles. Sign-in/import/default-browser changes were skipped.
- A command-line attempt to create a fresh Stable fixture exited with code 5 and left a startup-crash record under the disposable root. It was not counted as a PickVia route result, and the existing Stable browser process was preserved at that stage.
- Two Nightly instances appeared during attachment; the extra Restore Session instance was closed normally, and only the process carrying the exact test profile arguments was used for verification. A Computer paste operation also opened an unintended search using unrelated clipboard text; that tab was closed, subsequent settings changes used native menus/AX controls, and no search result was used as test evidence.
- Firefox Stable process 26670 was launched by production PickVia. The user subsequently authorized closing it for this final test; it was closed with Firefox’s normal Quit command before the cold-profile launch.

The retry receiver was stopped. Earlier cleanup verified that no retry-owned Developer Edition, Nightly or Brave Beta/Nightly processes remained; the final Stable run also closed its test browser and E2E app normally, and a process audit confirmed both had exited.

Private logs and fixtures remain under `/private/tmp/pickvia-e2e-computer-cc5zt84r`. This completes the seven-case retry; the original matrix’s other unverified or blocked cells are outside these seven results.
