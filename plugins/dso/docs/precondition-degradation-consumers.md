# Precondition Degradation Consumers

This document enumerates all components that read or act on `data.degradation` or `data.degradation_type` from `PRECONDITIONS` events, or that read ACK events produced by `preconditions-ack`. Consumers are listed here so that contract changes to the ACK event format (`contracts/ack-event-format.md`) or the degradation fields of the PRECONDITIONS schema (`contracts/preconditions-schema-v2.md`) can be propagated correctly.

---

## Consumer Registry

### 1. `${CLAUDE_PLUGIN_ROOT}/scripts/harvest-worktree.sh`

**Reads**: `data.degradation` from PRECONDITIONS events for the story being harvested.

**Action on `degradation=true`**: Logs a warning that the story has unresolved degradations. The degradation notice is included in the harvest output so the orchestrator is aware of any graceful-degradation fallthrough that occurred during precondition checking. Does not block or fail the harvest.

---

### 2. `dso:completion-verifier`

**Reads**: `data.degradation` from PRECONDITIONS events associated with the story under verification.

**Action on `degradation=true`**: Reports degradation presence as a consideration in the verification verdict. A degradation entry does not itself block verification — the verifier flags it in the report and leaves the verdict decision to the orchestrator. Degradation entries are surfaced in the verifier's structured JSON output under a `degradation_notices` key.

---

### 3. Sprint Step 18 (`check-unacked-degradations.sh`)

**Reads**: `data.decision_ids` from all `*-PRECONDITIONS.json` files for a `story_id`, and the corresponding `*-ACK.json` files for the same story.

**Action**: Compares decision_ids from degradation PRECONDITIONS events against decision_ids recorded in ACK events. If any `decision_id` from a `degradation=true` PRECONDITIONS event has no matching ACK, blocks story closure and instructs the practitioner to acknowledge via `preconditions-ack`. The sprint orchestrator invokes this check at the story-closure gate (Step 18).

---

### 4. `${CLAUDE_PLUGIN_ROOT}/scripts/preconditions-record.sh`

**Reads**: n/a — this is a writer, not a reader of degradation data.

**Action**: Writes PRECONDITIONS events. Accepts `--degradation` and `--degradation-type <type>` flags when called by the sprint orchestrator to record a graceful-degradation fallthrough. Sets `data.degradation=true` and `data.degradation_type=<type>` in the emitted JSON. Also sets `data.condition_text` when `--condition-text <text>` is supplied.

Listed here so that changes to the degradation field schema in `contracts/preconditions-schema-v2.md` are reflected in this script's flag handling and output format.

---

### 5. `${CLAUDE_PLUGIN_ROOT}/scripts/check-unacked-degradations.sh`

**Reads**: All `*-PRECONDITIONS.json` and `*-ACK.json` files for a given `story_id` in `.tickets-tracker/<story_id>/`. # tickets-boundary-ok

**Action**:
- Scans PRECONDITIONS files where `data.degradation=true`, collecting their `data.decision_ids`.
- Scans ACK files, collecting all `decision_ids` acknowledged.
- Exits `0` if every degradation `decision_id` has a corresponding ACK entry.
- Exits `1` if any degradation `decision_id` is unacknowledged, printing the unacked IDs to stderr.

This is the enforcement point for the acknowledgement requirement. It is invoked directly by Sprint Step 18 and may also be called by CI validation.

---

## Updating This Registry

When a new component begins reading `data.degradation`, `data.degradation_type`, or ACK events:

1. Add an entry to this registry before or alongside the code change.
2. Reference this file from the contract file that governs the field being consumed (`contracts/ack-event-format.md` or `contracts/preconditions-schema-v2.md`).
3. If the ACK event format contract changes, update all consumers listed here before merging.
