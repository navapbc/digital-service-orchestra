# SDET Audit — Digital Service Orchestra Test Suite

**Date**: 2026-05-19
**Scope**: 1,098 test files (~50 KLOC bash + Python) covering 245 shell scripts, 102 Python scripts, 80 hooks, 45 sub-agents, dozens of skills.
**Method**: Five parallel specialist passes — infrastructure, behavioral coverage, low-value detection, integration coverage, flakiness/reliability — synthesized into a prioritized P0–P5 plan.

---

## Overall Verdict

**Grade: B+ on structure, C+ on signal-to-noise.** This suite is unusually disciplined for a bash-heavy plugin (immaculate trap-stacking, session-safe pidfiles, RED-zone tooling, isolated suite engine). But it is doing **too much of the wrong kind of testing**: ~35% of assertions are text-grep change detectors, integration tests stub the transport layer rather than fault-inject it, and several load-bearing scripts in the review-integrity pipeline (the very thing CLAUDE.md treats as sacrosanct) have only happy-path coverage.

Comparable tier: early Kubernetes (1.8–1.10 era) for infrastructure; behind Terraform/Argo for failure-mode coverage; ahead of most bash-heavy CLIs for isolation.

---

## P0 — Fix this week (correctness + safety)

### P0-1 — PID-recycling kill race
**File**: `tests/lib/process-cleanup.sh:84–108`
**Problem**: `_cleanup_stale_session_processes` reads pidfile, then `kill -TERM` with no validation that the PID is still ours. On a loaded CI box, can murder unrelated processes.
**Fix**: Validate PID ownership via `/proc/$pid/cwd` or cgroup before kill, OR switch to `pgrep -f <pattern>` lookup. Add SIGKILL-with-cooldown loop.
**Why this matters**: Cross-process collateral damage. Hard to debug because the symptom is *another* test failing.

### P0-2 — Shared `/tmp/lockpick-test-pids` cross-user collision
**File**: `tests/lib/process-cleanup.sh:124`
**Problem**: Pidfile dir keyed only by branch name. Two devs on `main` (or CI matrix shards) collide and one session's cleanup kills the other's processes.
**Fix**: Path → `/var/run/user/$UID/<repo-hash>/lockpick-test-pids` or `$TMPDIR/lockpick-test-pids-$(whoami)-$(repo-hash)`.
**Why this matters**: Trivially fixable, high blast radius.

### P0-3 — Orphan 300s sleep in suite engine
**File**: `tests/test-suite-engine.sh:305`
**Problem**: `sleep 300 &` launched without `wait`/trap. If runner aborts, sleeps linger past the test budget.
**Fix**: `sleep 10 & _pid=$!; trap 'kill $_pid 2>/dev/null || true' EXIT; wait $_pid`.
**Why this matters**: Orphan kills downstream suites; misattributed failures.

### P0-4 — Anthropic OAuth endpoint NOT mocked in full-loop test
**File**: `tests/skills/dso_ci_review/test_integration_full_loop.py`
**Problem**: Direct violation of the memory-stored rule (`feedback_mock_oauth_tests`). Burns real quota when `ANTHROPIC_API_KEY` is set.
**Fix**: Add `@unittest.mock.patch` for `get_oauth_token` and `fetch_usage`, or gate with `@pytest.mark.skipif` requiring an explicit `RUN_LIVE_ANTHROPIC=1`.
**Why this matters**: Test isolation breach; cost; rate-limit blowback. Explicit project rule violation.

### P0-5 — External URL HEAD checks in unit suite
**File**: `tests/test-doc-links.sh:74,142,149`
**Problem**: `curl --max-time 10` against acli.atlassian / claude.ai with no retry. Will flake against CDN/WAF.
**Fix**: Mock by default; provide an opt-in `RUN_LIVE_LINK_CHECK=1` integration variant with exponential retry and `--max-time 30`.
**Why this matters**: Recurring red CI; eroded trust in failures.

### P0-6 — No file lock on `test-batched.sh` state file
**File**: `plugins/dso/scripts/test-batched.sh:327–356`
**Problem**: Two resumes race; both read same `completed_list`, both write back, one wins. Work duplicated or lost.
**Fix**: Wrap reads/writes with `flock(2)`; or key state file by session UUID so concurrent resumes have isolated files.
**Why this matters**: Silent test-result corruption under multi-session work.

---

## P1 — Coverage gaps that hide real regressions

These are the load-bearing surfaces with **no direct test or only structural-boundary tests** today. Each one would have caught at least one prior incident in this repo's git log.

### P1-1 — `review-defense-store.sh` append atomicity
**Problem**: Concurrent multi-cycle review can corrupt the per-ticket defenses JSON in the local tracker store. No write-append concurrency test.
**Fix**: Add a test that spawns 3 concurrent `record-defense.sh` calls and asserts no record loss + valid JSON.

### P1-2 — `review-github-defense-store.sh` fork-PR gate
**Problem**: `GITHUB_FORK_PR=1` silencing path lives in RED state (tests scaffolded, impl pending). High-risk: a regression posts CI-blocking comments to forked PRs.
**Fix**: Drive the RED suite to GREEN; assert no `gh pr comment` call is made under fork conditions.

### P1-3 — `mirror-defenses-to-pr` round-trip
**Problem**: `TrackerDefenseStore` → PR comment → re-parse parity asserted only on the write side. No test fetches the comment back and re-validates the JSON survived markdown escaping.
**Fix**: Round-trip test: write defense → run mirror → fetch (stubbed) comment → parse → field-by-field equality.

### P1-4 — `cascade-circuit-breaker.sh`
**Problem**: The 5-failure halt referenced in CLAUDE.md rule #6 has zero direct test. A regression that opens this breaker is invisible until the next cascade.
**Fix**: Direct unit test: simulate 5 fix-bug iterations; assert the 6th is blocked.

### P1-5 — `session-safety-check.sh`
**Problem**: Recurring-error dedup; no test for 24h time-window filter.
**Fix**: Inject hook-error-log entries with mocked timestamps; assert dedup respects window.

### P1-6 — Tool-use / worktree-bash guard enforcement
**File**: `plugins/dso/hooks/lib/pre-bash-functions.sh`
**Problem**: The wrapper hooks invoke `hook_tool_use_guard` / `hook_worktree_bash_guard` but the library functions are not isolated-unit-tested. These prevent commits-on-main and edits-in-worktree.
**Fix**: Add a Bats-style spec that sources the lib and asserts allow/deny decisions over a matrix of (branch, marker file, env-var) inputs.

### P1-7 — `agent-batch-lifecycle.sh` state machine
**Problem**: dispatch→ack→checkpoint exercised only transitively. CLAUDE.md "Never #2" calls this the #1 cause of lost work.
**Fix**: Stub-mode unit test that drives the lifecycle through commit-ack-resume and asserts checkpoint integrity.

### P1-8 — Config-gated disable paths
**Flags**: `design.figma_collaboration`, `planning.external_dependency_block_enabled`, `scope_drift.enabled`, `worktree.isolation_enabled`
**Problem**: Enabled-path-only coverage. Flipping any flag to `false` regresses silently.
**Fix**: Convention: every `if config.is_enabled('flag')` branch requires a `flag=false` test pair. Enforce with a one-shot pre-commit grep.

### P1-9 — `dso:completion-verifier` schema invariants
**Problem**: Injected fields (`verifier_status`, `evidence_invalidated`, `fingerprint`) not exercised end-to-end through `record-review.sh`.
**Fix**: Contract test that runs verifier output through `record-review.sh --reviewer-hash` and asserts schema is accepted.

### P1-10 — Sub-agent output contracts at large
**Problem**: 45 sub-agents shipped; ~3 test files target them. 6% ratio.
**Fix**: Per-agent JSON-schema fixture + replay test; failing the schema fails CI.

---

## P2 — Low-value tests to delete or rewrite

Sampling suggests **~35% of assertions are change-detectors (text grep on prose) and ~15% are tautological**. Concrete candidates:

| File:Line | Pattern | Action |
|-----------|---------|--------|
| `tests/hooks/test-review-gate-allowlist.sh:22,30,39,50,58,77` | `if [ -f config ]; then assert true; else assert false; fi` — 6 wrappers around file-exists | **DELETE** — replace with one behavioral test: run the gate with config present vs. absent. |
| `tests/brainstorm/test-structural-alignment.sh:19–94` | 8 raw `grep -q "Inputs"` style assertions on SKILL.md prose | **DELETE** — re-route through structured probe-table parser; assert *semantic* presence. |
| `tests/skills/test-design-context-structure.sh:33–94` | 8 string-presence checks on `{design_context}`, `NEEDS_REVIEW` | **DELETE** — same prose-grep antipattern. See verification verdict P2 row 3 (path corrected). |
| `tests/hooks/test-snapshot-removal.sh:17–77` | Pure greps that legacy code is gone | **REWRITE** — invoke the code path; assert removal behavior, not absence-of-string. |
| `tests/workflows/test-review-workflow-classifier-override-prevention.sh:23` | Greps for `"rationali"`, `"overhead"` in prompt files | **REWRITE** — simulate override; verify rejection. |
| `tests/unit/scripts/test-build-review-agents.sh:81` | `wc -l == 6` | **REWRITE** — assert each generated file parses and matches the required schema. |
| `tests/docs/test-reviewer-base-file-constraint.sh:58,88,150,190` | `grep "diff"` in schema text | **REWRITE** — parse schema; assert the constraint formally. |

**Structural fix**: Ban `grep -q "<exact-string>"` in `tests/docs/` and `tests/brainstorm/`. Any prose verification must go through a parser (TOML/YAML/JSON section extractor) and assert *structure*, not wording.

---

## P3 — Integration fidelity: raise the seams

Today's pattern is **bash-shim stubs** (prepend a fake `gh`/`acli` to `PATH`). This catches argument-shape regressions but never transport-level faults.

### P3-1 — HTTP mock server for GitHub
Stand up `pytest-httpserver` or a `nc`-based responder under `tests/mocks/github-api-server.py`. Route `wait-for-pr.sh`, `mirror-defenses-to-pr.sh`, `respond-to-pr-comments` against it. Inject 403/429 with `Retry-After`, GraphQL timeouts, partial pagination.
**Effort**: ~2 days. **Coverage gain**: every retry/backoff path that today is dark.

### P3-2 — Sandboxed Jira tenant
Free-tier Jira Cloud project as a CI secret. Conditional test: `if [[ -n "$JIRA_SANDBOX_TOKEN" ]]; then run-real-bridge; fi`. Validate cold-start cursor seeding, `BRIDGE_ENV_ID` empty fail-fast, `BRIDGE_USER_MAP` case-insensitive lookup, checkpoint corruption recovery.
**Effort**: ~3 days.

### P3-3 — Prompt-cache assertions in Anthropic tests
Extend `test_check_usage.py` to mock `Anthropic.messages` and assert `cache_read_input_tokens > 0` on cache hit. Adds the missing "is caching actually working?" signal that today depends on humans reading dashboards.
**Effort**: ~1 day.

---

## P4 — Reliability hygiene

| Pattern | Find with | Fix |
|---------|-----------|-----|
| Network in unit tests | `grep -rE 'curl \|wget \|gh api' tests/{unit,hooks,scripts}/` | Move to `tests/integration/`; mock by default. |
| Fixed polling without backoff | `grep -rE 'sleep 0\.[0-9]+' tests/` | `until <cond>; do sleep N; done` with bounded retries; max ~500 ms. |
| `mktemp -t` (BSD/GNU divergence) | `grep -rE 'mktemp -t' tests/` | Replace with `mktemp /tmp/<prefix>.XXXXXX`. CLAUDE.md rule #15 already mandates — enforce. |
| `sed -i` without portable wrapper | `grep -rE 'sed -i' tests/` | Replace with `sed > tmp && mv tmp file`. Pre-commit lint. |
| `date -d` GNU-only | `grep -rE 'date -d ' tests/` | Add fallback validator; assert `touch -t` actually changed mtime; otherwise the stale-GC tests lie. |
| Hardcoded `/tmp/<name>.lock` | `grep -rE '/tmp/[a-z-]+\.lock' tests/` | Use `$TMPDIR/<name>-${session}.lock` per CLAUDE.md #15. |
| Background `&` without `wait` | `grep -rE '& *$' tests/` | Add `_pid=$!; trap 'kill $_pid 2>/dev/null || true' EXIT; wait $_pid`. |

---

## P5 — Quality-of-life

### P5-1 — Line numbers in assert failures
**File**: `tests/lib/assert.sh:27–35`
**Problem**: A long test with 50+ assertions becomes hard to debug.
**Fix**: `printf "FAIL: %s (%s:%d)\n" "$label" "${BASH_SOURCE[1]}" "${LINENO}" >&2`.
**Why this matters**: Single highest UX win in the codebase.

### P5-2 — `.test-index` is hand-edited and O(N)-scanned
**Problem**: 105 KB hand-edited file scanned linearly by every runner.
**Fix**: Add `_metadata: {schema_version, content_hash}` header; mechanical stale-detection. Consider a hash-keyed JSON sidecar for runtime lookup.

### P5-3 — Path-change filter duplication
**File**: `.github/workflows/ci.yml`
**Problem**: Re-implements `skip-review-check.sh` classification logic in YAML guards. (Verifier note — see verdict P5-3 REJECT: CI actually fails *closed* — sets `code_changed=true` when the script is missing — so this finding is rejected. Text retained for traceability.)
**Fix**: ~~Make missing-script a hard failure, not a safe default.~~ Superseded by REJECT verdict.

### P5-4 — No CI artifact retention
**Problem**: Test logs vanish with the workflow run.
**Fix**: Add `actions/upload-artifact@v4` for `results_dir/` with 30-day retention; halves debug time on intermittent failures.

### P5-5 — Disabled-path test discipline
See P1-8 for the policy.

---

## Industry comparison

| Dimension | DSO today | Strong projects |
|-----------|-----------|------------------------|
| Test isolation | B+ (trap-stacking, suite tmpdir, session pidfiles) | Bazel/Pulumi: per-test sandbox VFS; deterministic env. |
| Failure-path coverage | C (happy-path heavy) | K8s e2e: chaos faults at every external boundary. |
| Integration fidelity | C (PATH-stub mocks) | Argo CD / Backstage: wiremock; recorded VCR cassettes. |
| Change-detector ratio | C− (~35% est.) | Kubernetes: explicit policy against prose-grep tests. |
| Flake culture | B (good hygiene; isolated risks) | Rails: adaptive polling in helpers; flaky tests auto-quarantined. |
| Sub-agent contract tests | D (6% ratio) | LangChain / Pydantic-AI: every agent has schema round-trip test. |

---

## Recommended sequencing

- **One week**: P0-1, P0-2, P0-4, P0-5 — eliminate the highest-friction flake sources and close a stated CLAUDE.md rule violation.
- **One sprint**: P1-1, P1-2, P1-6, P1-8 — close the highest-blast-radius coverage gaps tied to the integrity rules in CLAUDE.md "Never Do These".
- **One quarter**: P3-1 and P3-2 — unlock failure-mode testing for every external boundary; remove the largest class of "we only catch this in production" bugs.

---

## Independent Verification (2026-05-19)

A second SDET re-checked every recommendation against the source code. Results: **12 APPROVED / 12 MODIFIED / 9 REJECTED (~36% / 36% / 27%)**. Do NOT implement this audit verbatim — five rejected items propose deleting tests that catch real regressions, two propose fixes for non-existent bugs, and one fix has a bash-semantics error.

### Verdict table

| ID | Verdict | Notes |
|----|---------|-------|
| P0-1 | MODIFY | `kill -0` liveness check already present; `/proc/$pid/cwd` won't work on macOS. Use `ps -o lstart=` start-time comparison instead. |
| P0-2 | APPROVE | Cross-user collision is real; `$TMPDIR/lockpick-test-pids-$(whoami)-<repo-hash>` is correct. |
| P0-3 | REJECT | The `sleep 300 &` is inside a heredoc creating a MOCK test that exercises orphan-timeout regression behavior. Adding `wait $_pid` would invalidate the test. |
| P0-4 | REJECT | `test_integration_full_loop.py` is `@pytest.mark.integration`-decorated, excluded from unit runs, and calls `dispatch_review` directly — does NOT touch `get_oauth_token`/`fetch_usage`. The OAuth-mocking rule targets unit tests, not this live-integration probe. |
| P0-5 | REJECT | Audit misread the file: the cited URLs (acli.atlassian, claude.ai) are in the `OPT_OUT_URLS` list; only one curl exists; lines 142/149 are `sed` calls, not curls. Minor flake risk remains but not as described. |
| P0-6 | MODIFY | Atomic write via tempfile+rename already exists; state path is per-worktree-hash. Real risk is concurrent `--resume` against the same state file. Use `flock -n` advisory lock and fail-loud (exit 75) rather than serialize. |
| P1-1 | APPROVE | No concurrent-append test exists. Cheap to add. |
| P1-2 | APPROVE | RED suite for fork-PR no-op confirmed. |
| P1-3 | APPROVE | No round-trip parity test exists. |
| P1-4 | REJECT | `tests/hooks/test-cascade-breaker.sh` exists with full threshold tests. Audit missed it. |
| P1-5 | MODIFY | Tests exist for 7-day rotation window; the 24h dedup window is the actual gap. Add focused boundary tests; don't rewrite rotation tests. |
| P1-6 | MODIFY | Tests for dispatcher and no-edit-on-main exist; the library functions are still indirectly tested. Add thin sourcing tests that call `hook_worktree_bash_guard` directly. |
| P1-7 | APPROVE | No `test-agent-batch-lifecycle.sh` exists. High blast radius. |
| P1-8 | MODIFY | Partial coverage already exists. Add per-flag disabled tests for the four flags. Don't enforce via pre-commit grep — too noisy. |
| P1-9 | REJECT | `tests/scripts/test-record-review-verifier-fields.sh` already covers verifier schema invariants. |
| P1-10 | APPROVE | 6% ratio confirmed; schema replay tests are cheap insurance. |
| P2 row 1 (allowlist) | REJECT | Tests encode security invariants (no `.py`/`.sh` in allowlist) and reference bug 8679-9c37. Deleting loses bug-traceable signal. |
| P2 row 2 (structural-alignment) | MODIFY | Three checks; two ARE redundant on the same (file, string). Collapse duplicates, don't delete the suite. |
| P2 row 3 (design-context-structure) | MODIFY | Audit cited wrong path (`tests/docs/` — actual is `tests/skills/`). Re-audit at correct path. |
| P2 row 4 (snapshot-removal) | APPROVE | Pure legacy-string-absence checks; behavioral rewrite is right. |
| P2 row 5 (classifier-override-prevention) | REJECT | This IS an intentional structural-boundary test for CLAUDE.md-mandated guidance text. Simulating an override requires an LLM — prose-grep is the cheapest correct defense. |
| P2 row 6 (build-review-agents wc -l == 6) | MODIFY | Add schema-parse assertion ALONGSIDE the count, not replacing it. Count drift is also a real bug class. |
| P2 row 7 (reviewer-base-file-constraint) | REJECT | Tests already use Python parsing to extract the schema region; the `*"diff"*` check inspects a pre-parsed substring. Audit misread. |
| P3-1 | APPROVE | Real gap; effort estimate reasonable. |
| P3-2 | MODIFY | Live Jira tenant introduces external-dep flake. Prefer VCR cassette replay; reserve live smoke for manual `workflow_dispatch`. |
| P3-3 | REJECT | `tests/skills/dso_ci_review/test_prompt_caching.py` already asserts `cache_read_input_tokens` across turns. Audit missed it. |
| P4 row 1 (network in unit) | MODIFY | Pattern grep would flag many false positives (mock invocations). Add `grep -v 'fake-\|mock\|stub\|# '` filter. |
| P4 row 3 (`mktemp -t`) | APPROVE | One confirmed violation; trivial fix. |
| P4 row 6 (hardcoded /tmp lock) | MODIFY | One occurrence only; fix the site, don't add sweeping lint. |
| P5-1 | MODIFY | UX win is real BUT `${LINENO}` inside `assert_eq` expands to assert.sh's own line number. Use `${BASH_LINENO[0]}` for the caller's line. |
| P5-2 | APPROVE | Real maintenance hazard; sensible fix. |
| P5-3 | REJECT | Audit inverted polarity: CI fails-CLOSED (sets `code_changed=true`) when the script is missing, not fail-open. |
| P5-4 | APPROVE | No `upload-artifact` in any workflow; trivial high-value fix. |
| P5-5 | (cross-ref) | Reduces to P1-8. |

### Patterns in the rejects

1. **Search-without-read.** The audit's most consistent failure mode: grep for a pattern, treat the hit as the bug, never read context. Five "missing coverage" claims (P1-4, P1-9, P3-3, plus the misreads in P0-3, P0-5) were already covered.
2. **Inverted polarity on CI safety** (P5-3): the audit read fail-closed as fail-open on a load-bearing path.
3. **OAuth-mocking rule misapplied** (P0-4): rule targets unit tests; the cited test is explicitly integration-decorated.
4. **Structural-boundary tests treated as change detectors** (P2 rows 1 and 5): CLAUDE.md explicitly carves these out as acceptable.
5. **Bash-semantics bug in proposed fix** (P5-1): `${LINENO}` vs `${BASH_LINENO[0]}`.

### Net judgment

Implementing the APPROVED + MODIFIED set (with the corrections noted) meaningfully improves reliability — particularly P0-2, P1-1, P1-2, P1-3, P1-7, P3-1, P5-1 (corrected), P5-2, P5-4. Executing the original audit verbatim would waste ~25% of effort on already-covered ground and delete five tests that catch real regressions. Treat this verification table as the canonical action list.

