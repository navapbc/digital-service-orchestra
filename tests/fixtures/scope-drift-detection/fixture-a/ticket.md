# Bug: get_user_status() logging uses unstructured format

## Description

The `get_user_status()` function in `src/services/user_service.py` currently
uses plain string interpolation for log messages. This makes log aggregation
and searching difficult in production.

## Expected Behavior

All log calls in `get_user_status()` should use structured logging format
(key=value pairs) instead of f-string interpolation.

## Steps to Reproduce

1. Call `get_user_status(user_id="abc123")`
2. Observe log output: `"Fetching status for user abc123"`
3. Expected: `"action=fetch_status user_id=abc123"`

## Acceptance Criteria

- All `logger.info()` and `logger.debug()` calls in `get_user_status()` use
  structured format with key=value pairs.
- No change to function behavior or API contract.
