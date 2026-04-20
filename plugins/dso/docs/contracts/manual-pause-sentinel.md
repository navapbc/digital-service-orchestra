# Contract: MANUAL_PAUSE_SENTINEL Comment Interface

- Signal Name: MANUAL_PAUSE_SENTINEL
- Status: accepted
- Scope: sprint-manual-drain.sh (emitter) → completion-verifier.md (parser, Step 3b added by task 2cfe-9b03)
- Date: 2026-04-19

## Purpose

This document defines the MANUAL_PAUSE_SENTINEL comment interface written by `sprint-manual-drain.sh` to each `manual:awaiting_user` story ticket after the in-session handshake completes. The sentinel is the authoritative record that the manual step occurred and its outcome.

`dso:completion-verifier` reads this sentinel at Step 10a closure to determine whether to mark done definitions PASS, SKIP, or FAIL — without re-executing the manual step or re-prompting the user.

---

## Comment Format

The sentinel is written as a ticket comment whose body starts with the literal prefix `MANUAL_PAUSE_SENTINEL: ` followed by a single-line JSON payload:

```
MANUAL_PAUSE_SENTINEL: {"audit_token":"2026-04-19T23:00:00Z:abc123","verification_command_exit_code":0,"user_input":null,"story_id":"abc1-2345","handshake_outcome":"done"}
```

---

## Schema Fields

| Field | Type | Required | Description |
|---|---|---|---|
| `audit_token` | string | yes | ISO 8601 UTC timestamp + session hash suffix, e.g. `"2026-04-19T23:00:00Z:abc123"`. Generated at handshake time. |
| `verification_command_exit_code` | integer \| null | yes | Exit code from running `verification_command` (0=pass, non-zero=fail). `null` when no `verification_command` was present. |
| `user_input` | string \| null | yes | Confirmation token text typed by the user when `confirmation_token_required=true` on the dependency entry. `null` when a `verification_command` was run instead. |
| `story_id` | string | yes | Ticket ID of the manual story this sentinel covers (e.g., `"abc1-2345"`). |
| `handshake_outcome` | enum | yes | One of `"done"`, `"skip"`, or `"done_with_story_id"`. |

---

## Field: `handshake_outcome` — Accepted Values

| Value | Meaning |
|---|---|
| `done` | User typed `done` — current story in the prompt list was accepted. |
| `done_with_story_id` | User typed `done <story-id>` — a specific story was targeted by ID. |
| `skip` | User typed `skip` — story and its transitive dependents are deferred. |

---

## Emitter: sprint-manual-drain.sh

`sprint-manual-drain.sh` writes the sentinel via:

```bash
.claude/scripts/dso ticket comment <story-id> "MANUAL_PAUSE_SENTINEL: <JSON>"
```

One sentinel per story, written after the handshake for that story resolves.

---

## Parser: completion-verifier.md Step 3b

> **Implementation note**: Step 3b does not yet exist in `${CLAUDE_PLUGIN_ROOT}/agents/completion-verifier.md`. It is added by task 2cfe-9b03 in this epic. Implementers should insert the step after the existing Step 3 (Evaluate Each Criterion).

`dso:completion-verifier` reads sentinel comments at story closure:

| Sentinel state | Verdict |
|---|---|
| Absent | `PENDING` — story may be mid-handshake; do not count as FAIL |
| Present, `handshake_outcome=done` or `done_with_story_id`, `verification_command_exit_code=0` | All done definitions `PASS` |
| Present, `handshake_outcome=done` or `done_with_story_id`, `verification_command_exit_code=null`, `user_input` non-null | All done definitions `PASS` (confirmation token confirmed) |
| Present, `handshake_outcome=skip` | All done definitions `SKIPPED` (not FAIL) |
| Present, `handshake_outcome=done` or `done_with_story_id`, `verification_command_exit_code != 0` | Done definitions `FAIL` |
| Present but JSON malformed | Treat as absent (`PENDING`) |

**The verifier must never re-execute `verification_command` or re-prompt the user. The sentinel is the authoritative record.**

---

## Notes

- Absent sentinel is not an error condition — it means the story has not yet reached the handshake, or the session was interrupted before writing. The verifier must not fail on absent sentinel.
- The `verification_command` itself is logged separately in a `MANUAL_VERIFICATION_PRE_EXEC` comment before execution; the sentinel captures only the exit code.
- Confirmation tokens are also logged separately in `MANUAL_CONFIRMATION_TOKEN` comments; the sentinel captures only the token text in `user_input`.

---

## Changelog

| Version | Date | Change |
|---|---|---|
| 1.0 | 2026-04-19 | Initial contract definition |
