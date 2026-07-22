# PickVia Chooser UI Polish Design

Date: 2026-07-21
Status: Approved design

## Goal

Polish the browser chooser so long browser/profile lists are easier to scan and use. The chooser will use compact one-line entries, a quieter selection treatment, three user-selectable density presets, and more useful defaults for detected private targets.

## Scope

This change covers:

- chooser row layout and selection appearance;
- chooser density preferences;
- panel sizing derived from density;
- default enabled states for automatically detected browser targets;
- one-time migration of existing detected targets; and
- tests for the new presentation, preferences, discovery defaults, and migration.

It does not change routing rules, browser launch arguments, keyboard shortcut assignment, pointer anchoring, profile discovery, the Browser Settings row design, or footer actions.

## Visual Direction

Use the approved "Grouped and quiet" direction.

- A browser with multiple enabled targets has one group header containing its application icon and name.
- Each selectable target occupies one line: its configured label on the left and its shortcut badge on the right.
- A browser with one enabled target remains a direct row and shows its application icon in that row.
- Target rows do not show a second line. Remove repeated browser names, profile names, and the `Normal` or `Private` detail subtitle.
- Long labels truncate at the tail. Shortcut badges keep their current fixed visual position.
- The selected row uses a low-opacity accent fill and a subtle inset accent border. It has no drop shadow.
- Hover uses a lighter accent fill. Keyboard and pointer selection use the same selected appearance.

The heading, optional URL, errors, empty state, scrolling behavior, and footer remain structurally unchanged.

## Density Preference

Expose a segmented picker in General Settings under Behavior with these options:

1. Compact
2. Balanced
3. Spacious

Compact is the default for new and existing installations when no valid preference is stored.

Each density preset owns a complete set of chooser layout metrics rather than scattering conditionals through the view. The preset controls:

- panel content width;
- outer padding;
- main vertical spacing;
- browser-group spacing;
- row horizontal and vertical padding;
- group-header padding; and
- footer/control size where useful.

Font sizes remain within standard macOS text styles. Compact mode gains space primarily through padding and spacing, not substantially smaller text.

The density preference is stored as an integer through the existing preferences abstraction. A missing or unknown stored value resolves to Compact. A chooser reads the current preference when a new request is presented; changing the setting does not resize an already visible chooser.

## Detected Target Defaults

For Chromium and Firefox browsers, automatically detected targets use this enabled-state matrix:

| Target | Enabled |
| --- | --- |
| Browser default, normal | Yes |
| Browser default, private | Yes |
| Named profile, normal | Yes |
| Named profile, private | No |

Safari continues to expose its normal browser target only.

Manual targets retain the enabled state chosen by the user.

## Existing Configuration Migration

Increase the configuration schema version once. When loading an older supported configuration, normalize every automatically detected Chromium or Firefox target to the matrix above:

- targets without a profile identity are browser-default targets;
- targets with a profile identity are named-profile targets;
- normal and private modes determine the corresponding matrix row; and
- manual targets are not modified.

The migration occurs only while upgrading the schema. Once the configuration is saved at the new schema version, later loads and rescans preserve user changes using the catalog's existing merge behavior.

Newly discovered targets use the same matrix at candidate creation time, so fresh installs and newly installed browsers behave consistently with migrated installations.

## Components and Data Flow

### Chooser density model

An app-level value type represents the three presets, their persisted integer values, display names, and layout metrics. Invalid persistence values map to Compact.

### App model and settings

`AppModel` loads and stores the density through `PreferencesStoring`, alongside the existing URL-visibility preference. `GeneralSettingsView` binds a segmented picker to this value.

### Chooser controller and layout

`ChooserPanelController` reads density from an injected provider when presenting a new routing request and passes the resolved preset to `ChooserView`. Panel width and fitting calculations use that preset. Existing pointer placement and screen-edge clamping calculations consume the resulting panel size without changing their placement policy.

### Chooser view

`ChooserView` uses the preset's metrics, renders one-line rows, and applies the flat selected/hover treatment. Presentation grouping, shortcut assignment, selection state, and target lookup remain in `ChooserPresentation`.

### Configuration and discovery

`PickViaConfig.validatedAndMigrated()` performs the one-time schema migration. `BrowserCatalog` assigns the approved enabled state when creating new detected candidates. Existing catalog reconciliation preserves post-migration user choices.

## Error Handling

- Invalid density persistence values fall back to Compact and do not prevent app startup.
- Configuration validation still rejects unsupported future schema versions.
- The enabled-state migration changes only recognized detected Chromium and Firefox targets; unknown or manual data follows existing validation and preservation behavior.
- Existing chooser launch errors remain visible above the target list and do not alter the current selection.

## Accessibility

- Every target remains a native button with its full label available to accessibility APIs.
- The visual selection state remains backed by the existing selection model rather than color alone.
- Standard macOS text styles and sufficient contrast are retained across appearance modes.
- Keyboard navigation, Return, Escape, and sequential number/letter shortcuts remain unchanged.

## Testing

Add or update tests for:

- Compact as the missing/invalid preference fallback;
- persistence and restoration of all three density values;
- the metric set and panel width for each density;
- one-line chooser row structure with no detail subtitle;
- selected-row styling without a drop shadow;
- discovery defaults for browser-default normal/private and named-profile normal/private targets;
- migration of existing detected targets to the matrix;
- preservation of manual target enabled states during migration;
- preservation of detected-target user changes after the schema has already migrated;
- unchanged shortcut assignment, arrow navigation, pointer placement, scrolling, and footer actions; and
- a full warning-as-errors test run and production app build.

## Acceptance Criteria

- The chooser no longer displays duplicate second-line information for targets.
- Selected rows look flat and native, without the current shadow artifact.
- General Settings offers Compact, Balanced, and Spacious chooser densities.
- Compact is the default and visibly fits more targets than the current chooser.
- Existing and newly discovered detected targets follow the approved four-state matrix.
- Manually added targets are not changed by migration.
- All existing chooser interaction behavior continues to work.
