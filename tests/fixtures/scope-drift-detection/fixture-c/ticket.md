# Bug: handle_request() raises AttributeError when request.headers is None

## Description

The `handle_request()` function in `src/handlers/request_handler.py` raises an
`AttributeError` when `request.headers` is `None`. The function attempts to
iterate over `request.headers.items()` without a None guard.

## Expected Behavior

When `request.headers` is `None`, `handle_request()` should treat it as an
empty dict and continue processing without raising an exception.

## Steps to Reproduce

1. Create a request object with `headers=None`
2. Call `handle_request(request)`
3. Raises `AttributeError: 'NoneType' object has no attribute 'items'`

## Acceptance Criteria

- `handle_request()` does not raise when `request.headers` is `None`.
- Headers default to empty dict when `None`.
- No changes to files outside the handler module.
