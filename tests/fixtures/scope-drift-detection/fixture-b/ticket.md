# Bug: process_items() should return [] not None when input is None/empty

## Description

The `process_items()` function in `src/processing/item_processor.py` currently
returns `None` when the input list is `None` or empty. Callers expect an empty
list `[]` in these cases, not `None`.

## Expected Behavior

When called with `None` or an empty list, `process_items()` should return `[]`
instead of `None`.

## Steps to Reproduce

1. Call `process_items(None)` -- returns `None`, should return `[]`
2. Call `process_items([])` -- returns `None`, should return `[]`

## Acceptance Criteria

- `process_items(None)` returns `[]`
- `process_items([])` returns `[]`
- Non-empty input behavior unchanged.
