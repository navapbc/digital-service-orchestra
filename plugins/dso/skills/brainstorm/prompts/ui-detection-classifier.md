# UI Intent Classifier Prompt

## Purpose

Dispatched by Phase 1 Gate Step 1.5 when the keyword scan returns `ambiguous`. Classifies whether the feature described in the Understanding Summary is UI-facing.

## Input

The full confirmed Understanding Summary text from Phase 1 Gate Step 1.

## Classification Task

Read the Understanding Summary carefully. Determine whether this feature requires a user-facing interface (a web page, form, screen, widget, or other visual interactive surface).

**Respond with exactly one word — nothing else:**
- `ui` — the feature is UI-facing (it presents a visual interface that users interact with)
- `non-ui` — the feature is not UI-facing (background job, internal API, data migration, CLI tool, configuration, or infrastructure with no user-visible surface)

## Failure Handling

If you cannot determine the classification with confidence, respond with `non-ui`. Any response other than `ui` or `non-ui` is treated as a classifier failure by the calling orchestrator and falls through to `non-ui` with a degradation notice.
