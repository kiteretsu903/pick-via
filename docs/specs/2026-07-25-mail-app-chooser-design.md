# Mail App Chooser Design

Date: 2026-07-25
Status: Approved

## Goal

Extend PickVia from a browser-specific chooser into a scheme-aware application chooser. In
addition to its existing HTTP and HTTPS behavior, PickVia will handle `mailto:` links and let
the user choose an installed mail-capable application for each request.

Mail selection is application-level only. PickVia will not discover, display, or launch mail
accounts, profiles, identities, or compose modes.

## Scope

This feature includes:

- registration as a `mailto:` URL handler;
- automatic discovery of every installed application registered with macOS for `mailto:`;
- an app-only mail chooser that reuses the established chooser interaction model;
- mail application enablement, ordering, availability, and rescanning in settings;
- `mailto:` default-handler status and an explicit action to make PickVia the default;
- optional mail setup in first-run onboarding;
- generalized routing, application, target, configuration, and launch abstractions shared by
  web and mail requests;
- migration of the existing browser-only configuration without changing browser behavior.

This feature does not include:

- the `message:` scheme or any scheme other than `http`, `https`, and `mailto`;
- mail account or profile selection;
- mailto rewriting, remembered choices, routing rules, or domain rules;
- displaying, copying, logging, or persisting recipients, subject, body, or other request
  content;
- forcing existing users who completed onboarding to repeat onboarding.

## Chosen Architecture

PickVia will use a generalized scheme-router architecture. The supported route kinds are:

- Web, for `http` and `https`
- Mail, for `mailto`

### Shared application and target models

`RoutedApplication` owns the state common to every selectable application:

- stable identity;
- bundle identifier;
- display name;
- resolved application URL;
- availability;
- one or more typed route capabilities.

`RouteTarget` owns the state common to every chooser entry:

- stable identity;
- application identity;
- user-visible label;
- enabled state;
- sort order;
- detected or manual origin;
- availability;
- typed target capability.

An application capability is either browser, with its browser family, or mail. An application
may own both capabilities when macOS registers the same bundle for web and mail links.

The target capability is a separate enum with browser and mail cases. The browser case contains
the existing profile, mode, launch-path, and migration state. The mail case has no subordinate
options. Configuration validation rejects duplicate application capabilities and any target
capability that its application does not support. This preserves browser-specific type safety
without adding mail conditionals to every browser field.

### Discovery

Browser discovery keeps its existing supported-browser catalog, profile parsers, profile
access flow, and target reconciliation behavior, but emits the generalized application and
target models.

Mail discovery asks `NSWorkspace` for all installed applications able to open a representative
`mailto:` URL. Each result must resolve to an installed `.app` with a nonempty bundle
identifier. Discovery normalizes and deduplicates applications, excludes PickVia's own bundle
identifier, and emits one mail target per application.

Application identity remains the bundle identifier, allowing browser and mail discovery to
merge capabilities for the same installed app. Existing browser target identities remain
unchanged. Mail target identities are route-scoped so they cannot collide with browser targets.

Mail reconciliation follows these rules:

- preserve the label, enabled state, and sort order of an existing application;
- enable every newly discovered application by default;
- append new applications in stable display-name order after preserved applications;
- retain a disappeared application as unavailable;
- restore the prior target state if that application is reinstalled;
- never make PickVia itself a selectable target.

Browser and mail discovery are independent authoritative operations. Failure in one catalog
must not erase or replace valid state owned by the other catalog.

### Routing

Incoming URLs are classified by scheme before entering routing. Scheme matching is
case-insensitive. PickVia accepts only `http`, `https`, and `mailto`; unsupported or malformed
requests are ignored.

One routing coordinator owns a single FIFO queue for all supported route kinds. For each
request it:

1. derives the route kind;
2. snapshots the enabled and available applications and targets for that kind;
3. presents the shared chooser with route-specific content;
4. launches the selected target through the matching launch strategy;
5. dismisses the chooser and advances to the next request after success or cancellation.

This shared queue prevents browser and mail chooser panels from competing. Existing
protections against duplicate selection, in-flight refresh, stale callbacks, and concurrent
launches continue to apply.

### Launching

Launching is exposed through one routing interface with capability-specific strategies.

The browser strategy retains the existing trusted application resolution, executable
validation, profile arguments, normal/private behavior, and workspace launch path.

The mail strategy resolves the selected application's current installed URL by bundle
identifier, verifies that the target and application identities and capabilities match, then
uses `NSWorkspace` to open the original `mailto:` URL with that exact application. PickVia
does not parse or rewrite the URL before launch.

## Configuration and Migration

The persisted configuration schema advances from version 2 to version 3 and stores generalized
applications and targets.

Migration converts every existing browser application and target to its corresponding
generalized capability. It preserves:

- application and target identities;
- browser families;
- user labels;
- enabled states and sort order;
- detected and manual origins;
- availability;
- profile identifiers, display names, and identities;
- normal and private modes;
- pending default migrations and validation errors.

The migration is deterministic and idempotent. A validation or persistence failure keeps the
existing file unchanged and uses the established recovery presentation. Runtime-resolved app
and executable URLs remain excluded from persisted configuration.

## Chooser Experience

The mail chooser reuses the existing panel controller, density metrics, pointer-aware geometry,
scrolling, neutral initial selection, mouse interaction, arrow navigation, numbered and letter
shortcuts, Return selection, and Escape cancellation.

Its route-specific presentation is:

- heading: `Open email with`;
- one direct row for each enabled and available mail application;
- application icon and display name in every row;
- no groups, profiles, modes, or secondary detail;
- no request preview;
- no Copy action;
- Mail Settings and Cancel footer actions.

The empty state says that no mail applications are available and links the user to Mail
Settings. A launch failure keeps the chooser open, preserves its snapshot and selection, and
shows `Could not open the selected mail app.` The user may choose another app or cancel.

The web chooser's labels, URL preference, Copy action, grouping, and browser-settings action
remain unchanged.

## Settings

Settings gains a `Mail` destination alongside General, Browsers, and About.

Mail Settings contains:

- `mailto:` default-handler status;
- `Make PickVia Default` and `Refresh Status` actions;
- a Rescan action;
- one row per known mail application;
- enable or disable controls;
- drag ordering;
- a visible missing state for unavailable applications.

Unavailable or disabled applications do not appear in the chooser. Rescanning uses the
reconciliation rules above and refreshes an active mail chooser only when the existing routing
safety rules permit it.

The current chooser density preference applies to both route kinds. The
`Show URL in browser chooser` preference remains browser-only.

## First-Run Onboarding

The existing browser discovery, browser review, profile-access, and default-browser setup
remain required. After browser default status is confirmed, onboarding adds:

1. **Review mail apps**
   - shows the automatically discovered mail applications and whether each is enabled;
   - provides Rescan and Continue actions;
   - requires at least one enabled and available mail application to continue to default setup;
   - provides `Skip Mail Setup`, which completes onboarding without changing the mail handler.
2. **Make PickVia your default mail app**
   - shows current `mailto:` default-handler status;
   - provides `Set as Default`;
   - provides `Skip Mail Setup`;
   - completes onboarding after macOS confirms PickVia as the handler or the user skips.

Skipping mail setup never changes the current `mailto:` handler. Mail setup remains available
later in Mail Settings.

The persisted onboarding state gains an explicit migration:

- installations already complete under the old flow map directly to the new completed state;
- installations incomplete at upgrade retain their corresponding browser step and continue
  into mail setup after browser setup;
- a completed existing user is never reopened into onboarding solely because mail support was
  added.

## Default-Handler Services

Default-handler state becomes scheme-aware while retaining explicit typed views for web and
mail status. HTTP and HTTPS continue to be requested and reported together for browser setup.
`mailto` is requested and reported independently.

After a default-handler request, PickVia queries macOS again and advances onboarding only from
confirmed status. Partial browser confirmation and failed or unknown mail confirmation leave
the relevant step open and show the existing sanitized error treatment.

## Privacy and Security

The original URL exists only in the active in-memory routing request and is released when that
request finishes. Mail request content is never rendered, copied, logged, stored in
configuration, or written to preferences.

All launch decisions use the immutable routing snapshot shown to the user. A selected
application is re-resolved from its bundle identifier at launch time rather than trusting a
persisted path. Application-target capability mismatches, unavailable apps, self-routing, and
unsupported URL schemes fail closed.

## Error Handling

- Non-authoritative mail discovery preserves the last valid mail configuration and surfaces a
  Mail Settings error.
- Invalid discovered entries are skipped without invalidating valid entries.
- An empty authoritative result marks prior mail apps unavailable rather than deleting user
  state.
- A mail launch failure is reported with the generic mail-specific message and does not expose
  the URL or underlying system error.
- Configuration migration, validation, and persistence retain the established recovery
  behavior and never partially publish a new routing snapshot.
- Browser discovery, profile access, configuration, and launch errors retain their current
  behavior.

## Testing

Automated tests will cover:

- version 2 to version 3 migration, idempotence, and lossless browser-state preservation;
- generalized model validation and rejection of mismatched capabilities;
- mail discovery normalization, deduplication, self-exclusion, stable ordering, default
  enablement, missing-app retention, and reinstall restoration;
- independent browser and mail discovery failure behavior;
- case-insensitive classification of supported schemes and rejection of unsupported or
  malformed input;
- mixed web/mail FIFO routing, cancellation, refresh, stale selection, in-flight launch
  protection, and sanitized failures;
- unchanged browser launch-plan behavior;
- trusted mail application resolution and unchanged `mailto:` launch URLs;
- mail chooser row construction, neutral selection, shortcuts, scrolling, empty and error
  states, absence of request content, and contextual footer actions;
- Mail Settings rescanning, enablement, ordering, availability, and default status;
- onboarding success, failure, retry, and both Skip Mail Setup paths;
- migration of completed and incomplete onboarding states;
- web chooser and browser settings regressions.

Verification will run:

```zsh
swift test -Xswiftc -warnings-as-errors
zsh scripts/build-app.sh
zsh scripts/smoke-test.sh build/PickVia.app
```

Manual verification will confirm:

- existing HTTP and HTTPS chooser behavior is unchanged;
- browser profile access and profile-specific launches still work;
- `mailto:` opens the mail chooser without showing request content;
- at least two installed mail handlers can be selected successfully;
- enablement and ordering changes appear on the next chooser;
- Skip Mail Setup leaves the existing handler unchanged;
- default-handler status survives quit and relaunch;
- mixed browser and mail requests are serialized correctly.

## Acceptance Criteria

- PickVia can register for and become the default handler for `mailto:`.
- Every valid installed macOS application registered for `mailto:` is discovered automatically,
  except PickVia itself.
- Newly discovered mail applications are enabled by default.
- Users can disable, enable, reorder, and rescan mail applications in Mail Settings.
- A `mailto:` request presents app-level choices only and never displays request content.
- Selecting a mail application opens the unchanged request in that application.
- Browser and mail requests share one safe queue and preserve established chooser interaction.
- Existing browser configuration and behavior survive migration unchanged.
- Existing completed users are not returned to onboarding.
- New onboarding presents mail setup and always offers Skip Mail Setup.
- Tests, production build, smoke test, and manual browser/mail verification pass.
