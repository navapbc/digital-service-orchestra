# Known Issues and Workarounds

Operational patterns discovered during development. Add entries when 3+ similar incidents occur or when a pattern is worth encoding for future sessions.

---

## INC-001: Closed-Bug-Trailer Race Condition

**Symptom**: A sub-agent commit's `DSO-Bug:` trailer references a ticket that was closed by another sub-agent in the same parallel batch execution. Integration fails or logs an unexpected trailer.

**Cause**: Parallel batch execution can close a bug ticket between the time a sub-agent starts work and the time it commits. The trailer references the now-closed ticket ID.

**Workaround**: Route to `--force-route-to-pending` rather than aborting integration. Log the SHA and closed-ticket-id for post-session manual attribution. Do not stall the integration loop over a stale trailer reference.

**Context**: Bug-Fix Mode in `/dso:debug-everything` and sprint batch execution; see SKILL.md Bug-Fix Mode Execution step 3.

---

## INC-002: Stale `.debug-active` Marker After SIGKILL

**Symptom**: A new `/dso:debug-everything` invocation detects an existing `.debug-active` marker from a session that was killed without Phase K cleanup.

**Cause**: If the debug session process is killed (SIGKILL, terminal close, system shutdown) before Phase K runs, the `.debug-active` marker is never removed.

**Workaround**: Phase A's stale-detection logic reads the `debug-session-id=<YYYYMMDD-HHMMSS>-...` field from the marker and compares its age against `debug.session_ttl_hours` (default: 24h). If the marker is older than the TTL, Phase A automatically removes it and logs: `"Phase A: removed stale .debug-active marker (age > N hours)"`. If the marker has no parseable timestamp or uses schema_version < 1, Phase A exits with an error prompting manual removal.

**Manual recovery**: `rm -f "$(git rev-parse --show-toplevel)/.debug-active"`

**Context**: Phase A stale-detection block in `plugins/dso/skills/debug-everything/SKILL.md`.

---

## INC-003: DEBUG_BRANCH_TRACKING Parser Accidentally Matches WORKTREE_TRACKING Comments

**Symptom**: After compaction recovery in `/dso:debug-everything` ci-pr mode, the orchestrator reads the wrong sub-branch from ticket comments — specifically, it parses a sprint `WORKTREE_TRACKING:` comment instead of a `DEBUG_BRANCH_TRACKING:` comment.

**Cause**: A substring or loose prefix match (e.g., `grep 'TRACKING:'`) accidentally matches both `DEBUG_BRANCH_TRACKING:` comments from debug sessions and `WORKTREE_TRACKING:` comments from sprint sub-agent worktrees when both are present on the same epic or linked tickets.

**Fix**: Use exact-prefix match: `grep '^DEBUG_BRANCH_TRACKING: '` (note the trailing space). This isolates debug-session branch anchors from all other tracking comment types.

**Context**: COMPACTION_RESUME block in `plugins/dso/skills/debug-everything/SKILL.md`. This exact-prefix isolation is a regression test requirement.
