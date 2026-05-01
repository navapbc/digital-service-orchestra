# UI Intent Detection: Keyword Trigger and Classifier Stub

## Default Surface-Lexicon

The following keywords indicate UI intent when found in the confirmed Understanding Summary. Count keyword hits:
- **≥3 hits**: `clear-ui`
- **0 hits**: `clear-non-ui`
- **1-2 hits**: `ambiguous` (dispatch classifier)

Default keywords:
web, form, screen, page, button, input, UI, user interface, dashboard, modal, dialog, navigation, sidebar, dropdown, toggle, menu, layout, component, widget, render, display, click, hover, scroll, responsive, view, panel, wizard, table, chart, grid, card, tab, toast, tooltip, icon

## Config Override: `brainstorm.ui_keywords`

Set `brainstorm.ui_keywords` in `dso-config.conf` to REPLACE (not merge with) the default lexicon entirely.

Format: comma-separated keywords.

Example:
```
brainstorm.ui_keywords=form,wizard,panel,chart,grid
```

When set, ONLY these keywords are used — the default lexicon above is completely replaced.

## Classifier Stub (Testing/Mock)

Set `BRAINSTORM_UI_CLASSIFIER_STUB` environment variable to bypass live classifier dispatch:

| Value | Effect |
|-------|--------|
| `ui` | Short-circuit to UI result (probes fire) |
| `non-ui` | Short-circuit to non-UI result (probes skip) |
| `fail` | Short-circuit to classifier failure (degradation fallthrough to non-ui) |
| unset/empty | Live classifier dispatch via `ui-detection-classifier.md` |
