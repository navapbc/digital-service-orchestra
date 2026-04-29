# Jira Bridge Audit: ID Format Migration (3e74-56da)

## Summary

Audit searched all source files (`.py`, `.sh`, `.js`, `.ts`, `.rb`) for code that
assumes the current short ticket ID format `xxxx-xxxx` (8 hex chars + 1 dash = 9
characters total). The proposed migration widens this to `xxxx-xxxx-xxxx-xxxx` (16
hex chars + 3 dashes = 19 characters).

**No dedicated Jira bridge source files contain ID format assumptions.** Bridge files
(`bridge-inbound.py`, `bridge-outbound.py`, `ticket-bridge-fsck.py`,
`ticket-bridge-status.sh`) treat ticket IDs as opaque strings — they pass IDs
through to directory names and event fields without any length check or slice.

The only location where a length/format assumption exists is in the **ID generation
code** itself (`ticket-create.sh` and `ticket-lib-api.sh`), which explicitly slices
a UUID to produce the current 8-char format. All other code is format-agnostic.

**Overall safety assessment: safe to proceed.** No migration changes are required to
bridge files or downstream ticket consumers. Only the ID generation sites need to be
updated when the 16-hex format is adopted.

---

## Grep Patterns Used

1. **8-hex ID regex pattern** — `[a-f0-9]{4}-[a-f0-9]{4}` in `*.py`, `*.sh`, `*.js`, `*.ts`
2. **ID length assertions** — `len.*== *9`, `length.*== *9`, `-eq 9`, `\.length == 9`
3. **9-char slice operations** — `[:9]`, `.slice(0, 9)`, `[0:9]`
4. **Hardcoded format strings** — `xxxx-xxxx`, `[a-f0-9]{4}-[a-f0-9]{4}` in `*.md`
5. **ID generation pattern** — `u[:4]`, `u[4:8]`, short-id extraction from UUID

---

## Findings

| File | Line | Pattern | Current Code | Disposition | Notes |
|------|------|---------|--------------|-------------|-------|
| `plugins/dso/scripts/ticket-create.sh` | 172 | ID generation slice | `ticket_id = u[:4] + '-' + u[4:8]` | **migrated** (generation site) | Slices first 8 hex chars from UUID4. Must change to `u[:4] + '-' + u[4:8] + '-' + u[8:12] + '-' + u[12:16]` for 16-hex format. |
| `plugins/dso/scripts/ticket-lib-api.sh` | 770 | ID generation slice | `ticket_id = u[:4] + '-' + u[4:8]` | **migrated** (generation site) | Duplicate of the same inline Python block inlined in the bash-native `_ticketlib_create` function. Needs identical update. |
| `plugins/dso/docs/ticket-cli-reference.md` | 150 | Format description | "Generates a collision-resistant 8-character ID (format: `xxxx-xxxx`)" | **migrated** (documentation) | Describes the current ID shape. Must be updated to "18-character ID (format: `xxxx-xxxx-xxxx-xxxx`)" when the format changes. |
| `plugins/dso/docs/ticket-cli-reference.md` | 29, 240, 297, 300, 549, 583, 586 | Example IDs | `"ab12-cd34"`, `"w21-a3f7"`, etc. | confirmed-safe | Example IDs in documentation that use 8-hex format for illustration. These are illustrative only; no code depends on their length. Update examples when format changes for consistency, but not load-bearing. |
| `plugins/dso/docs/contracts/bridge-alert-event.md` | 73 | Example ID | `"w21-5mr1"` | confirmed-safe | Example in contract doc. No format enforcement. |
| `plugins/dso/docs/contracts/sync-event-format.md` | 46, 71, 84 | Example IDs / `local_id` description | `"w21-5mr1"`, `"w21-gykt"` | confirmed-safe | `local_id` described as "non-empty string matching the local ticket ID convention" — no length or regex constraint enforced by contract. |
| `plugins/dso/scripts/bridge-inbound.py` | (all) | ticket_id handling | Reads `local_id` from SYNC events as opaque string; uses as directory name key | confirmed-safe | No length check, no slice. ID flows through unchanged. |
| `plugins/dso/scripts/bridge-outbound.py` | (all) | ticket_id handling | Iterates ticket dirs, passes `ticket_id` as `local_id` in SYNC event | confirmed-safe | No length check, no slice. Directory name is used as-is. |
| `plugins/dso/scripts/ticket-bridge-fsck.py` | (all) | ticket_id handling | Uses `ticket_dir.name` as `ticket_id`; stores/compares as dict key | confirmed-safe | No length assumption; treats ID as opaque string key. |
| `plugins/dso/scripts/ticket-bridge-status.sh` | (all) | ticket_id handling | No ticket ID handling; reads `.bridge-status.json` aggregates only | confirmed-safe | Not involved in per-ticket ID operations. |
| `tests/scripts/bridge_test_helpers.py` | 42, 61, 88 | Event filename construction | `f"{ts}-{event_uuid}-{event_type}.json"` | confirmed-safe | Constructs event filenames from timestamp + uuid4 + event_type. Ticket directory name (the ID) is set by the caller; no format assumption. |
| `plugins/dso/scripts/ticket-exists.sh` | (all) | Directory check | `[ -d "$ticket_dir" ]` — derives path from argument | confirmed-safe | No format validation; accepts any string as ticket ID. |
| All other ticket scripts (`ticket-list.sh`, `ticket-ready.py`, `ticket-graph.py`, `ticket-reducer.py`, `ticket-unblock.py`, `ticket-comment.sh`, etc.) | — | ticket_id usage | Use ticket IDs as opaque strings (directory names, dict keys, JSON field values) | confirmed-safe | None performs length checks, regex validation, or slicing on ticket IDs. |

---

## Conclusion

**Safe to proceed.** The ID format migration requires changes to exactly two code
locations and one documentation paragraph:

1. **`plugins/dso/scripts/ticket-create.sh` line 172** — the Python inline that
   generates the short ticket ID must be updated from `u[:4] + '-' + u[4:8]` to
   produce a 16-hex four-segment format.

2. **`plugins/dso/scripts/ticket-lib-api.sh` line 770** — identical inline Python
   block in the bash-native create function; must be updated in lockstep with
   `ticket-create.sh`.

3. **`plugins/dso/docs/ticket-cli-reference.md` line 150** — the documentation
   description "8-character ID (format: `xxxx-xxxx`)" must be updated to match the
   new format. Example IDs throughout the CLI reference and contract docs should also
   be refreshed to use the new format for consistency, but they are not load-bearing.

No bridge code, no downstream consumers, and no test infrastructure contains length
or format assumptions beyond the generation sites above. The bridge treats `local_id`
and all ticket IDs as opaque non-empty strings by design (see
`plugins/dso/docs/contracts/sync-event-format.md` line 56: "the parser must not
enforce format beyond non-empty").
