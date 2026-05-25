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
- Reviewer duplication (RESOLVED): `per-branch-review.yml` was deleted (bug 576b). Replaced by `review-sub-pr.yml` (per-story review, PRs targeting session branches) and `ci.yml llm-review` (session→main review). These are mutually exclusive by base_ref — no duplicate reviews.
- Branch naming dependency: `review-sub-pr.yml` and `ci.yml merge-pipeline-checks` trigger patterns must match the session branch naming convention. Current patterns: `session/**`, `session-**`, `session_**`, `bug-batch/**`, `worktree-**`. If session branch naming changes, update these patterns — otherwise per-story CI review silently skips. `per-worktree-review-commit.md` Step 2 has a fallback that detects pattern mismatches and runs local review (bug 5f3a-a794).

**Workaround — `/dso:fp-recovery`**: when CI llm-review blocks on a finding the engineer believes is an FP, invoke `/dso:fp-recovery <pr-number>`. The skill dispatches `dso:code-reviewer-standard` at opus tier on the PR diff. If the manual review returns 0 critical / 0 important / 0 fragile findings AND the dispatch did real work (≥10 tool calls, ≥60s runtime), the engineer is cleared to force-merge with an auditable annotation in the merge commit message. The annotation is mandatory — it makes the override discoverable via `git log --grep "Force-merged: manual dso:code-reviewer-standard"`. Coverage is preserved: every force-merge through this path has a real reviewer review behind it, just at opus tier with full reasoning.

**When NOT to use this workflow**:
- Test failures (fix the failing tests, don't force-merge).
- Intermittent CI failures (re-push or wait — see bug 53f9-a218-8799-49be).
- Findings the engineer is genuinely uncertain about — use the defense-store path instead (write a defense, let the resolution loop or arbiter adjudicate).
- Routine PRs — this is an escape valve, not a default path.

**Context**: `/dso:fp-recovery` skill at `${CLAUDE_PLUGIN_ROOT}/skills/fp-recovery/SKILL.md`; workflow at `${CLAUDE_PLUGIN_ROOT}/docs/workflows/FP-RECOVERY-WORKFLOW.md`. CLAUDE.md Rule 18 has a cross-reference. The skill is a temporary escape valve intended to bridge to the longer-term fixes (swap-maple-flyby arbiter wiring, side-pane-tithe metrics, future reviewer-prompt §C–§E improvements). When the rolling-30-day FP rate drops below ~10%, the skill can be retired or restricted to security-overlay-only escalation.

---

## INC-005: UI/UX Corpus Manifest Drift After Adding New Domain Files

**Symptom**: After adding new YAML domain files to `plugins/dso/data/ui-reference/`, `ref-query.sh` does not return results from the new files. No error is emitted.

**Cause**: `_index.yaml` in `plugins/dso/data/ui-reference/` is a static manifest that must be updated manually when new domain files are added. If the step is skipped, the new files are silently excluded from BM25 retrieval.

**Fix**: After adding new corpus domain files, update `plugins/dso/data/ui-reference/_index.yaml` to include the new file entries, then commit both the domain file(s) and the updated `_index.yaml` together.

**Context**: `plugins/dso/scripts/ref-query.sh`; enforced at schema level by `check-corpus-schema.sh` pre-commit hook (tag vocabulary only — manifest completeness is not automatically checked).

---

## INC-006: Flaky Tests from Hardcoded `/tmp/<prefix>` Bypassing the Per-Test TMPDIR Sandbox

**Symptom**: A `tests/scripts/test-*.sh` test passes consistently locally (often 5/5 runs at ~1–2s each) but the Script Tests CI job intermittently reports it as failed with **truncated output** — test description echo lines appear but the per-test PASS/FAIL summary is missing. The failure does not reproduce on a re-run.

**Cause**: `tests/lib/suite-engine.sh` sets a per-test `TMPDIR=<isolated-dir>` before invoking each test specifically so that `mktemp` calls inside the test land in an isolated sandbox. Tests that call `mktemp -d /tmp/<prefix>.XXXXXX` use an **absolute path** that bypasses `$TMPDIR`, dropping the fixture into the shared `/tmp` namespace. Under parallel CI execution (MAX_PARALLEL=8 by default) this causes cross-test contention on shared `/tmp` paths — directory enumeration races, inode-cache pressure, sometimes lock contention — that manifests as test runs getting truncated, killed, or mis-classified by the suite engine.

**How to recognize this pattern**:
- `grep -nE 'mktemp -d /tmp/' tests/scripts/test-*.sh` — list every test that bypasses the sandbox. ~62 such tests existed at the time of writing; ~300 use the correct pattern.
- The failing test "passes locally, intermittently fails in CI under parallel load" combined with hardcoded `/tmp/<prefix>` usage is the diagnostic signal.

**Fix**: Change `mktemp -d /tmp/<prefix>.XXXXXX` to plain `mktemp -d` — it honors `$TMPDIR` (suite-engine's sandbox) and matches the dominant convention used by ~300 tests in the suite.

```bash
# Before — bypasses suite-engine sandbox; contends under parallel CI
tracker_dir=$(mktemp -d /tmp/test-my-thing.XXXXXX)

# After — honors $TMPDIR; isolated per test
tracker_dir=$(mktemp -d)
```

**Tension with CLAUDE.md `always:mktemp-tmp`**: that rule recommends `mktemp /tmp/<prefix>.XXXXXX` for **scripts** (where the issue is single-session-vs-multi-session conflict). Inside **tests** the suite-engine's per-test `$TMPDIR` sandbox is the stronger isolation contract — plain `mktemp -d` is correct in tests.

**Context**: First observed on PR #343 with `test-ticket-list-has-tag.sh` and `test-ticket-list-descendants-dispatcher.sh`. Fix landed in commit `2ecabb83a7`. The suite-engine sandbox is defined in `tests/lib/suite-engine.sh` `_run_single_test` (search for `TMPDIR=`).

---

## INC-007: Flaky Tests from Multiple Python3 Cold-Starts in Fixture Builders

**Symptom**: A bash test file that builds a few JSON / YAML fixtures takes longer under CI load than expected (1.5–3× local wall-clock). Combined with [[INC-006]], this can push a test across the truncation/timeout threshold and produce intermittent CI failures.

**Cause**: Bash test fixture builders that spawn one `python3 -c "..."` per fixture file (a common pattern for writing structured JSON) incur the full Python interpreter cold-start cost — typically ~50–100ms per invocation — for each subprocess. A fixture with 6 tickets × 4 hierarchy builds per test run = ~24 cold starts = ~1.2–2.4s of cumulative startup overhead before any test logic runs. Under parallel CI load (MAX_PARALLEL=8) interpreter startup is even slower due to process contention.

**How to recognize this pattern**:
- `grep -cE '^[[:space:]]*python3 -c' tests/scripts/test-<name>.sh` — count Python invocations in a test file. More than 2–3 per fixture-builder function is suspicious.
- Profile: `time bash tests/scripts/test-<name>.sh`. Files >1s of wall-clock that don't do any real I/O are candidates.

**Fix**: Consolidate per-fixture python3 calls into a single heredoc'd invocation that loops over the fixture data in-process:

```bash
# Before — 6 cold starts per fixture build (~300–600ms wasted)
python3 -c "import json; json.dump({'id': 'a', ...}, open('$dir/a.json', 'w'))"
python3 -c "import json; json.dump({'id': 'b', ...}, open('$dir/b.json', 'w'))"
# ... 4 more

# After — 1 cold start per fixture build
TRACKER_DIR="$dir" python3 - <<'PYEOF'
import json, os
tracker = os.environ['TRACKER_DIR']
tickets = [('a', ...), ('b', ...), ('c', ...), ('d', ...), ('e', ...), ('f', ...)]
for tid, ... in tickets:
    with open(os.path.join(tracker, tid + '.json'), 'w') as f:
        json.dump({...}, f)
PYEOF
```

Pass shell variables into the heredoc via env vars (`TRACKER_DIR="$dir" python3 - <<'PYEOF'`) — the single-quoted `'PYEOF'` delimiter prevents shell expansion inside the script, which is the bug-prone part of the unconsolidated `python3 -c "..."` form.

**Context**: First observed on PR #343 with `test-ticket-list-has-tag.sh` (3 → 1 python3 calls per fixture, 1.3s → 0.9s) and `test-ticket-list-descendants-dispatcher.sh` (6 → 1, 1.6s → 0.9s). Fix landed in commit `2ecabb83a7`. The same pattern likely exists in other fixture-heavy tests — when investigating new flaky tests in `tests/scripts/`, run `grep -cE '^[[:space:]]*python3 -c' <file>` early.
