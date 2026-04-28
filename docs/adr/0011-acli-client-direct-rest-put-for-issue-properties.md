# ADR 0011: AcliClient `_direct_rest_put()` for Jira Issue Properties

**Status:** Accepted
**Date:** 2026-04-27
**Epic:** 86c8-2d40 (File impact as first-class ticket field with Jira bridge surfacing)

---

## Context

The DSO Jira bridge uses ACLI (the Atlassian CLI client) as its primary interface for Jira operations. ACLI wraps the Jira REST API behind a set of named subcommands that cover common operations: creating issues, adding comments, transitioning statuses, and syncing field values.

The `FILE_IMPACT` feature (epic 86c8-2d40) requires syncing structured file impact data to Jira so that it is visible and queryable outside the DSO ticket system. The right Jira primitive for structured, non-comment data attached to an issue is an **issue property** — a key-value store exposed via `PUT /rest/api/3/issue/{issueKey}/properties/{propertyKey}`. Issue properties are indexed, queryable via JQL, and do not pollute the issue comment stream.

ACLI has no subcommand for setting issue properties. There is no CLI flag, no plugin, and no workaround that exposes this REST endpoint through ACLI's existing command surface.

---

## Decision

`AcliClient._direct_rest_put(path, data)` was added to `acli-integration.py` as a thin wrapper that calls the Jira REST API directly using the same authenticated session that ACLI uses. A higher-level `AcliClient.set_issue_property(jira_key, property_key, value)` method wraps it with the Jira issue-properties API contract (`PUT /rest/api/3/issue/{key}/properties/{prop}`). The FILE_IMPACT bridge handler (`handle_file_impact_event()` in `bridge/_outbound_handlers.py`) calls `set_issue_property()` to write `dso.file_impact` as an issue property, then calls the standard ACLI comment subcommand to post a human-readable summary.

This breaks the convention that the bridge communicates with Jira exclusively via ACLI subcommands.

---

## Rationale

No alternative achieves the goal within the existing ACLI-only constraint:

- Storing file impact as a comment is insufficient — comments are unstructured, cannot be queried via JQL, and pollute the comment stream.
- Storing file impact as a custom field requires Jira admin access and a schema change outside the bridge's operational scope.
- Patching ACLI to add an issue-properties subcommand is not feasible in the near term and would introduce a hard dependency on an external release timeline.

Issue properties are the correct Jira primitive. The REST API call is small, authenticated via the same credentials already in use, and isolated to a single method.

---

## Consequences

1. **Partial-failure semantics are explicit.** The property PUT and the comment add are independent operations. Neither rolls back the other. `handle_file_impact_event()` always attempts both and emits separate `BRIDGE_ALERT` events for each channel independently: `FILE_IMPACT_SYNC_FAILED` (property PUT failure) and `FILE_IMPACT_COMMENT_SYNC_FAILED` (comment add failure). Callers must handle the case where one succeeds and the other does not.

2. **`_direct_rest_put()` is intentionally narrow.** The method is private and its only documented caller is `handle_file_impact_event()`. Future bridge features that need additional REST endpoints should either add a dedicated private method with the same pattern or reassess whether a new ACLI subcommand has become available.

3. **Tests must mock the REST call.** Unit tests for `handle_file_impact_event()` must mock `AcliClient.set_issue_property()` (or the underlying `_direct_rest_put()` / HTTP layer) so they never hit a live Jira instance. This is consistent with the existing mock-OAuth policy in the test suite.
