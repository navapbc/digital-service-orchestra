# Known Issues and Workarounds

Operational patterns discovered during development. Add entries when 3+ similar incidents occur or when a pattern is worth encoding for future sessions.

---

## INC-001: Closed-Bug-Trailer Race Condition

**Symptom**: A sub-agent commit's `DSO-Bug:` trailer references a ticket that was closed by another sub-agent in the same parallel batch execution. Integration fails or logs an unexpected trailer.

**Cause**: Parallel batch execution can close a bug ticket between the time a sub-agent starts work and the time it commits. The trailer references the now-closed ticket ID.

**Workaround**: Route to `--force-route-to-pending` rather than aborting integration. Log the SHA and closed-ticket-id for post-session manual attribution. Do not stall the integration loop over a stale trailer reference.

**Context**: Bug-Fix Mode in `/dso:debug-everything` and sprint batch execution; see `plugins/dso/skills/debug-everything/SKILL.md` Bug-Fix Mode Execution step 3.

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

---

## INC-004: CI `llm-review` Blocks on False-Positive Findings

**Symptom**: CI's required `llm-review` check (ci.yml) reports `failure` on a PR with a finding the engineer believes is wrong — e.g., a hallucinated type mismatch, a missing-file claim against a script that exists under a different subdirectory, or a misread of the diff against stale line numbers. All other required checks pass. The engineer is blocked from merging despite the underlying code being correct.

**Cause**: The CI reviewer is a single LLM dispatch and is nondeterministic. Common FP signatures observed in session 2026-05-17:
- Type-tracing FPs: the reviewer claims `int(x) == y` is comparing int-to-string when `y` was already int-coerced earlier in the same script (the reviewer didn't trace the parse site).
- Missing-file FPs: pre-PR-#213, the reviewer issued a literal-path `read_files` and reported missing when the file lived under a subdirectory the consuming script's shim resolves automatically (mitigated by the multi-path cascade in PR #213 but not eliminated).
- Reviewer duplication: both `Per-Story LLM Review` (per-branch-review.yml) and `llm-review` (ci.yml) run on the same commit for `story/**`, `bug-batch/**`, `fix/**` branches. Two independent rolls compound the per-commit FP probability (bug f127-03ef-fd14-4da1 — open).

**Workaround — `/dso:fp-recovery`**: when CI llm-review blocks on a finding the engineer believes is an FP, invoke `/dso:fp-recovery <pr-number>`. The skill dispatches `dso:code-reviewer-standard` at opus tier on the PR diff. If the manual review returns 0 critical / 0 important / 0 fragile findings AND the dispatch did real work (≥10 tool calls, ≥60s runtime), the engineer is cleared to force-merge with an auditable annotation in the merge commit message. The annotation is mandatory — it makes the override discoverable via `git log --grep "Force-merged: manual dso:code-reviewer-standard"`. Coverage is preserved: every force-merge through this path has a real reviewer review behind it, just at opus tier with full reasoning.

**When NOT to use this workflow**:
- Test failures (fix the failing tests, don't force-merge).
- Intermittent CI failures (re-push or wait — see bug 53f9-a218-8799-49be).
- Findings the engineer is genuinely uncertain about — use the defense-store path instead (write a defense, let the resolution loop or arbiter adjudicate).
- Routine PRs — this is an escape valve, not a default path.

**Context**: `/dso:fp-recovery` skill at `${CLAUDE_PLUGIN_ROOT}/skills/fp-recovery/SKILL.md`; workflow at `${CLAUDE_PLUGIN_ROOT}/docs/workflows/FP-RECOVERY-WORKFLOW.md`. CLAUDE.md Rule 18 has a cross-reference. The skill is a temporary escape valve intended to bridge to the longer-term fixes (swap-maple-flyby arbiter wiring, side-pane-tithe metrics, future reviewer-prompt §C–§E improvements). When the rolling-30-day FP rate drops below ~10%, the skill can be retired or restricted to security-overlay-only escalation.
