# Chooser Neutral Initial State Design

Date: 2026-07-23
Status: Approved design

## Goal

Remove the selected-row effect that appears automatically on the first browser option when the chooser opens.

## Behavior

- A newly opened chooser has no selected target.
- No row displays the selected tint or inset border until the user makes a selection.
- Return does nothing while no target is selected.
- Pressing Down with no selection selects the first target.
- Pressing Up with no selection selects the last target.
- Subsequent Up and Down presses retain the existing wraparound behavior.
- Clicking a row launches it immediately, unchanged.
- Number and letter shortcuts launch their assigned targets immediately, unchanged.
- If an error rerenders the same request after the user has selected a row, preserve that selection.
- If an error rerenders the same request before the user selects a row, keep the neutral state.

## Implementation Boundary

This change belongs in `ChooserPresentation`, which owns selected-index state and keyboard movement. The view already renders selected styling only when its row matches `selectedIndex`, so it requires no visual workaround or new state.

`ChooserPanelController` continues to preserve an existing selected target across same-request rerenders when one exists. A nil selection remains nil.

## Testing

Update chooser-model and controller tests to verify:

- initial `selectedIndex` is nil;
- Return produces no action before selection;
- Down selects index 0 from nil;
- Up selects the last index from nil;
- wraparound still works after selection;
- same-request rerenders preserve an explicit selection;
- same-request rerenders preserve the neutral state; and
- direct number/letter shortcuts remain unchanged.

Run the complete warning-as-errors test suite, rebuild the production app, and manually confirm the chooser opens without a selected row.

## Acceptance Criteria

- The first row has no selected effect when the chooser appears.
- No browser can be launched by Return until the user explicitly selects a row.
- Arrow keys, clicks, and direct shortcuts remain predictable and functional.
