# Chrome Beta Support and PickVia v1.2 Design

## Goal

PickVia v1.2 will recognize an installed Google Chrome Beta application as a
separate Chromium-family browser. It will expose Chrome Beta profiles and
normal/private targets without mixing them with stable Google Chrome.

The release will be built and verified locally. Tagging, pushing, and
publishing the GitHub release remain outside this change until separately
authorized.

## Browser Catalog

Add one explicit `BrowserDescriptor` immediately after stable Google Chrome:

- display name: `Google Chrome Beta`
- bundle identifier: `com.google.Chrome.beta`
- family: Chromium
- profile root: `Library/Application Support/Google/Chrome Beta`
- executable path: `Contents/MacOS/Google Chrome Beta`

An explicit descriptor is preferred over bundle-prefix inference because each
Chrome channel owns distinct application metadata and profile storage. It also
preserves the catalog's current allowlist and trusted-executable model.

## Behavior

Existing Chromium behavior applies without a new browser family:

- macOS application discovery identifies Chrome Beta by bundle identifier;
- Chromium `Local State` parsing discovers its profiles;
- Chrome Beta appears as its own browser group in settings and the chooser;
- normal and private targets use the existing Chromium launch arguments;
- configuration and profile-access grants remain keyed by the Beta bundle
  identifier, separate from stable Chrome.

Missing or unreadable Beta profile metadata follows the existing fallback and
profile-access behavior. Stable Chrome and all other browsers remain unchanged.

## Regression Coverage

Tests will establish that:

- the supported descriptor list includes Chrome Beta in the intended order;
- the descriptor contains the exact bundle identifier, display name, profile
  root, and executable path;
- discovery reads Chrome Beta's own `Local State` and returns its profiles;
- the launcher accepts the Beta bundle/executable pairing through the trusted
  catalog and produces the standard Chromium launch plan;
- existing browser discovery and launch tests continue to pass.

Production changes will follow red-green-refactor: add the focused failing
tests, observe the expected failures, then add the minimal descriptor change.

## v1.2 Release Preparation

Update the packaged version to `1.2` and build number to `3`. Add a dated v1.2
changelog entry and update current-version/download text in the README and
website. Release notes will describe Chrome Beta support without implying
support for Chrome Dev, Canary, or special editions of other browsers.

Prepare these local artifacts:

- an ad-hoc-signed `PickVia.app` release build;
- `PickVia-v1.2.dmg`;
- a SHA-256 checksum for the DMG.

The existing documentation must continue to state that the public build is
ad-hoc signed and not notarized.

## Verification

Before declaring the release prepared:

1. Run the focused browser catalog and launcher tests.
2. Run the complete Swift test suite with sandboxing disabled and warnings as
   errors.
3. Run Swift formatting lint and `git diff --check`.
4. Build the release application and confirm its version/build metadata.
5. Run the packaged-app smoke test and strict deep signature verification.
6. Create the DMG, run `hdiutil verify`, and generate its SHA-256 checksum.
7. Confirm the locally installed Chrome Beta metadata matches the supported
   descriptor and perform a discovery smoke check against the real installation.

Any GUI-sensitive check that cannot be proven in the current environment will
be reported explicitly rather than inferred from a successful build.

## Non-goals

- Chrome Dev or Chrome Canary
- special editions of Safari, Edge, Brave, Vivaldi, or Firefox
- dynamic recognition of arbitrary Chrome channel bundle identifiers
- Developer ID signing, notarization, stapling, or automatic updates
- tagging, pushing, or publishing v1.2
