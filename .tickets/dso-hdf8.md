---
id: dso-hdf8
status: in_progress
deps: []
links: []
created: 2026-03-22T00:58:03Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-bwfw
---
# Contract: comment sync dedup interface (UUID marker + Jira comment ID)

Define the comment dedup interface used by the Jira bridge outbound (emitter) and inbound (parser).

## Interface specification

**UUID marker format**: A local COMMENT event's UUID is embedded in the Jira comment body as an HTML comment on the last line: `<!-- origin-uuid: {event_uuid} -->`. This hidden marker survives display rendering but may be stripped by Jira rich-text editor operations.

**Dedup state file**: `.tickets-tracker/<ticket-id>/.jira-comment-map` — a JSON object mapping:
- `uuid_to_jira_id`: dict mapping local event UUID (string) → Jira comment ID (string)
- `jira_id_to_uuid`: dict mapping Jira comment ID (string) → local event UUID (string)

**Primary dedup key (inbound)**: Jira comment ID — present in every comment returned by ACLI `getComments` action. Survives rich-text editor marker stripping.

**Secondary dedup key (inbound)**: Extracted UUID from `<!-- origin-uuid: ... -->` marker — used to confirm origin but NOT relied on for dedup when absent (stripped by editor).

**Outbound echo prevention**: Before writing a local COMMENT event on inbound pull, check `jira_id_to_uuid` in the dedup state file. If the Jira comment ID is already present, skip (it was pushed by local outbound).

**Contract file**: Create `plugins/dso/docs/contracts/comment-sync-dedup.md`

## test-exempt justification

test-exempt: static assets only — this task creates a Markdown contract document with no executable logic. No conditional branching; a test would be a change-detector. Criterion 3 of unit exemption criteria applies.

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] Contract file exists at `plugins/dso/docs/contracts/comment-sync-dedup.md`
  Verify: test -f $(git rev-parse --show-toplevel)/plugins/dso/docs/contracts/comment-sync-dedup.md
- [ ] Contract file defines UUID marker format `<!-- origin-uuid: {event_uuid} -->`
  Verify: grep -q 'origin-uuid' $(git rev-parse --show-toplevel)/plugins/dso/docs/contracts/comment-sync-dedup.md
- [ ] Contract file defines `.jira-comment-map` dedup state file schema with `uuid_to_jira_id` and `jira_id_to_uuid` keys
  Verify: grep -q 'jira_id_to_uuid' $(git rev-parse --show-toplevel)/plugins/dso/docs/contracts/comment-sync-dedup.md && grep -q 'uuid_to_jira_id' $(git rev-parse --show-toplevel)/plugins/dso/docs/contracts/comment-sync-dedup.md
- [ ] Contract file identifies primary dedup key as Jira comment ID and secondary as UUID marker
  Verify: grep -qi 'primary' $(git rev-parse --show-toplevel)/plugins/dso/docs/contracts/comment-sync-dedup.md


## Notes

**2026-03-22T01:06:09Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-22T01:06:15Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-22T01:06:18Z**

CHECKPOINT 3/6: Tests written (none required) ✓

**2026-03-22T01:06:56Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-22T01:17:11Z**

CHECKPOINT 6/6: Done ✓
