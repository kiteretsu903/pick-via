# Firefox edition profile presentation

Firefox, Firefox Developer Edition and Firefox Nightly remain separate browser entries with their existing names and app icons. Discovery now excludes profiles that Firefox records as last used by another currently located Firefox edition. Both Settings and the chooser consume this filtered catalog. Rescanning removes old detected duplicates; manually added targets are retained.

Association uses `LastPlatformDir` from the profile's `compatibility.ini`, as written by [Firefox's application runner](https://searchfox.org/mozilla-central/source/toolkit/xre/nsAppRunner.cpp). This is last-use metadata, not permanent profile ownership. Editable profile names are never used to guess an edition. Missing, unreadable, ambiguous or unrecognized metadata remains available through the existing fallback; this can still show an unassigned profile under more than one edition. Paths for moved or no-longer-located applications also retain that fallback.

Validation:

- Regression fixture: three installed editions and three identically named profiles resolve to one profile per edition; rescanning reduces nine old detected profile entries to three and preserves six browser-level normal/private entries.
- Association parser covers renamed applications and absent, malformed, relative and duplicate metadata.
- Focused catalog, association, chooser model and Settings tests passed.
- Full suite: 360 Swift Testing tests passed; 413 XCTest tests ran with one skipped and four display-dependent failures because the sandbox returned no NSScreen. Re-running all 32 chooser panel controller tests with display access passed with zero failures.
- Production and E2E release builds with warnings-as-errors passed.
- Computer verified native Settings sections and chooser groups using a disposable shared Firefox profile list: Firefox Work appeared only under Firefox; Firefox Developer Edition Work only under Developer Edition; Firefox Nightly Work only under Nightly. The chooser was canceled without launching a browser, and the preview app was quit normally.

UI fixture: `/private/tmp/pickvia-e2e-firefox-ui-c23v71je`. Build/test logs: `/private/tmp/pickvia-firefox-editions-*.log`.

No strict signature checks were run. Installed production PickVia was not replaced. The earlier seven-case launch retry remains historical evidence for the prior build; this subsequent change received the validation above.
