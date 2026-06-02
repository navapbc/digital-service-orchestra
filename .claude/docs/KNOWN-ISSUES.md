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

---

## INC-008: Jira fetcher — JRACLOUD-94632 + 1000-result ceiling + SilentTruncationError

**Symptom**: The dso_reconciler fetcher (`plugins/dso/scripts/dso_reconciler/fetcher.py`) raises `SilentTruncationError` and the reconciler pass aborts before emitting any mutations.

**Background**: ACLI's paginated JQL fetch has a 1000-result hard ceiling (JRACLOUD-94632). Above this size, the Jira API silently truncates the working set without exposing a `total` or `isLast` signal that the client can use to detect the truncation. Worse: under the JRACLOUD-94632 bug, ACLI's `nextPageToken` cursor can return the same token twice in a row when the working set is at the ceiling — a "stuck cursor" that would loop forever without explicit detection.

The fetcher mitigates both failure modes:

1. **Hard-ceiling gate**: once cumulative fetched issues reach 1000 AND the most recent page is exactly `page_size` (suggesting more issues exist), the fetcher raises `SilentTruncationError` before yielding the violating page.
2. **Same-token-twice fallback**: if `_iter_pages` observes two consecutive pages with an identical `nextPageToken` (or identical first key when token is unavailable), it raises `SilentTruncationError(reason='same-token-twice')`.

The fetcher prefers `startAt` pagination over `nextPageToken` precisely because `startAt` is robust to JRACLOUD-94632 — but the same-token-twice gate exists as a defense-in-depth for whatever ACLI mode is in effect at runtime.

**Why this design**: silent truncation is the load-bearing correctness issue from epic 3a03 — the prior reconciler architecture failed live verification because a truncated working set was indistinguishable from a "no-change" pass, leading to direction-inversion mutations.

**First-check when SilentTruncationError fires**:
1. Tighten the JQL scope. The current default `project = DIG AND (resolution = Unresolved OR updated >= -1h)` should keep the working set well under 1000 in steady state. If the working set has genuinely exceeded 1000 issues, the operator must triage the unfiltered backlog before resuming reconciler passes.
2. Check `alert_store` contents for `fetcher-dedup-suppressed` records — these indicate per-issue dedup is firing on consecutive pages, which is correlated with same-token-twice cursor stalls.
3. Verify `JRACLOUD-94632` has not been reverted/regressed in the ACLI version pinned by the reconciler's runtime environment.

**Related epics**: 4047 (Derivable level-triggered Jira reconciler) successor to 3a03 (failed cumulative cutover).
## INC-009: Inbound probe: 4-branch classifier + stdlib-urllib + GET-only invariant

**Symptom**: Reconciler dispatches an (inbound, probe) Mutation for a jira_key that disappeared from the working set.

**Contract**: `plugins/dso/scripts/dso_reconciler/inbound_probe.py` exposes a 4-branch classifier:
- `PRESENT_RESOLVED` — issue exists with status in {Resolved, Done, Cancelled}
- `PRESENT_FILTERED` — issue exists but no longer matches the JQL filter
- `ARCHIVED_OR_MOVED` — 404/410/403
- `UNREACHABLE` — 5xx/401/network/timeout

**stdlib-urllib choice**: deliberately avoids adding a third-party HTTP client. stdlib `urllib.request` is sufficient for a single GET per probe and aligns with the no-risky-dep policy (CLAUDE.md `rule:risky-dep`).

**GET-only invariant**: every Request constructed by the probe uses `get_method() == 'GET'`. POST/PUT/DELETE would be a contract violation — the probe is a pure observability primitive.

**Routing in reconcile.py**: see `route_inbound_probe(mutation, probe_result)` for the 4-branch mapping. hard_delete (ARCHIVED_OR_MOVED) emits (inbound, delete). trash_restore (PRESENT_RESOLVED) and unreachable do not emit follow-ons (audit-log only).

**Operator action when probe returns UNREACHABLE**: do NOT classify the issue as missing — UNREACHABLE means the probe could not determine state. Re-run the next pass; persistent UNREACHABLE across passes indicates a network/credential problem, not a workflow gap.

## INC-010: Outbound status push — comment-fallback heuristic on 400 illegal-transition

**Symptom**: A reconciler pass sees a Jira issue's status field rejected when applying an outbound update. The applier emits an `add_comment` to the issue containing `local status changed to <status>`.

**Why this happens**: Jira's workflow engine forbids some status transitions (e.g., Open → Done directly when an intermediate step is required). When `update_issue(key, status=...)` returns HTTP 400 with an `illegal transition` body, the applier does NOT retry — the request is logically valid but workflow-rejected. Instead, the applier falls back to a comment so the human assignee can see the local intent without breaking the Jira workflow gate.

**Comment shape**: `local status changed to <status>` substring (asserted by `test_400_illegal_transition_falls_back_to_comment`).

**Structured log**: a JSON record with `{action: 'comment_fallback', issue_key, attempted_status, reason: '400_illegal_transition'}` is written to stderr for operator triage.

**Retry semantics**: zero `update_issue` retries on 400 illegal-transition (call_count == 1). Workflow rejections are state errors, not transient — retrying would only re-fire the same rejection.

**Operator action**: review the structured log periodically; if the same `issue_key` appears repeatedly, either the local workflow needs a missing intermediate step OR the Jira workflow needs an additional permitted transition.

**Status gating**: comment-fallback fires regardless of `DSO_RECONCILER_STATUS_GATING`. The env gate controls whether status fields are even DISPATCHED (preflight scan + draft-5 routing); the comment fallback is the applier-side resilience layer for status writes that DO get through.

## INC-011: Dual-identity invariant — quarantine + repair_property failure flows

**Symptom**: `invariants.check_dual_identity_complete(local, jira)` returns a non-empty `quarantine_keys` set and/or a `seed_repair_property_mutations` list. The reconciler suppresses all mutations on quarantined keys and prepends the repair seeds before the differ pass.

**Failure modes detected by `check_dual_identity_complete`**:
1. **Missing back-pointer** — local ticket has `dso_local_id` set but no `jira_key`; the matched Jira issue points back via `dso_local_id`. Seeds an `(inbound, repair_property)` Mutation to write the missing back-pointer.
2. **Conflicting back-pointer** — local's `jira_key` does not match the Jira issue whose `dso_local_id` equals the local's. Quarantines the local key.
3. **Double-bind** — two or more Jira issues claim the same `dso_local_id`. Quarantines the local key AND every colliding Jira key.

**Per-pass cap**: `_DUAL_IDENTITY_CAP_PER_PASS = 50`. Above that, the invariant emits a single `bridge-alert:invariants-cap-hit` and stops adding entries. Operators must triage the cap-hit before the next pass.

**Repair_property failure flow** (task 44e6): when the applier dispatches an `(inbound, repair_property)` mutation and `client.set_issue_property` raises:
- The applier calls `client.remove_label(target, 'dso-id-<local_id>')` as cleanup (best-effort; secondary errors suppressed).
- Returns an outcome dict with `follow_on={'kind': 'schema_drift', ...}`.
- The reconcile.py post-emit filter (52f3) scans for these and invokes `invariants.report_schema_drift(target, observed, expected)` which fires a BRIDGE_ALERT with dedup_key `bridge-alert:schema-drift:<issue_key>`.

**Operator action when quarantine fires**: investigate the local→jira mapping table for the quarantined keys. Run `check_dual_identity_complete` ad-hoc to confirm the failure mode. For double-bind, decide which Jira issue is canonical and clear the `dso_local_id` field from the duplicates.

**Why this matters**: dual-identity is the foundation of direction-tagged mutation safety (epic 4047, successor to the failed 3a03 cutover). A silently broken binding produces inversion bugs at scale.

# INC-012: ProvenanceLedger — stateless content-hash echo-suppression invariant

**Symptom**: A reconciler pass emits zero update mutations even when local and Jira states differ at the byte level for a given field.

**Cause**: The differ's `ProvenanceLedger` integration suppresses any mutation whose target+payload `content_hash` matches the ledger's last recorded entry for that target. This is the "echo" case: the same value just came back from the other side and should NOT trigger a duplicate write.

**Stateless content-hash invariant**: `is_echo(key, value)` compares `hash(value)` against the ledger's last entry — NOT the full write history. This is deliberate. The ledger is a sliding-window memory, not a persistent provenance log.

**Why not persistent provenance**: persistent storage of per-element provenance was considered (story 26de-eb67-29d2-48ae) and REJECTED as a "fix" for echo suppression. Reasons:
1. Hash equality is sufficient for the echo case — full history adds complexity without behavioral benefit.
2. Persistent storage introduces a coordination hazard between reconciler passes (which pass owns the history? what happens on partial-pass failures?).
3. The reconciler is designed to be stateless across pass boundaries — adding persistent provenance breaks the design contract that any single pass is sufficient to bring the bridge to a consistent state.

**Operator warning**: do NOT extend ProvenanceLedger with persistent storage as a "fix" for surprising echo-suppression behavior. The right response to an unexpected suppression is: (a) verify the suppression actually was the right outcome (the values DO match), or (b) audit the upstream emission site to see what was recorded.

**Related epic**: 4047 (Derivable Jira reconciler), story 26de-eb67-29d2-48ae (per-element provenance for conflict resolution).

---

## INC-013: Reconciler Orchestrator — Mode flag, pass-lock, phase-gate, 9-leaf dispatch

**Story**: 9e3f-3208-af65-4b34 (orchestrator integration: mode + concurrency guards + dispatch table)

### Mode flag

`plugins/dso/scripts/dso_reconciler/mode.py` (task 0fb4) defines a strictly ordered `Mode` enum with 4 members:

| Value | Meaning |
|---|---|
| `dry-run` | Read-only diff analysis; no writes emitted |
| `bootstrap-strict` | Write-enabled, one mutation per pass; phase-gate required |
| `bootstrap-throttle` | Write-enabled, throttled batch size; phase-gate removed |
| `live` | Fully operational; no throttle |

Ordering: `dry-run < bootstrap-strict < bootstrap-throttle < live`. There is **no `--force` override** that skips mode checks — the flag is a rollout-safety knob enforced in the main guard sequence (`plugins/dso/scripts/dso_reconciler/__main__.py`, task f516). `dry-run` is the fail-fast pre-fetcher mode: it runs the full fetch + diff pipeline but suppresses all applier calls.

**Drift modes vs rollout modes**: `inject-and-heal.sh --mode=orphan|mislabel|missing-prop` is a shell-script `case` parameter for that script only. It is orthogonal to `reconcile.py`'s Mode enum — the two namespaces do not overlap.

### Pass-lock (`.reconciler-pass-lock`)

`.reconciler-pass-lock` is an **advisory** lock file stored on the `tickets` orphan branch. It complements — but does not replace — the GitHub Actions `concurrency: cancel-in-progress: false` setting at `.github/workflows/reconcile-bridge.yml` lines 21–23.

**How it works** (implementation: `plugins/dso/scripts/dso_reconciler/_advisory_lock.py`, task a2ba):

- The main guard sequence (`__main__.py`) acquires the lock at pass start via `git show tickets:.reconciler-pass-lock` to check for an existing holder.
- A second invocation observes the lock file via `git show tickets:.reconciler-pass-lock` and exits non-zero in the pre-fetcher phase — before any fetch I/O occurs.
- Acquire and release use the `_concurrency.rebase_retry` pattern to handle concurrent `tickets`-branch commits.

**Why advisory**: the lock does not prevent concurrent execution at the OS level. The GHA `cancel-in-progress: false` ensures the workflow queue does not auto-cancel a running pass, and the advisory lock ensures a second invocation that races through the queue gate self-aborts without conflicting writes.

**Operator action on stuck lock**: if `.reconciler-pass-lock` persists after a crashed pass, remove it manually: `git checkout tickets && git rm .reconciler-pass-lock && git commit -m 'release stuck pass-lock' && git checkout -`.

### Phase-gate (`.reconciler-phase-gate`)

`.reconciler-phase-gate` is a presence-based sentinel on the `tickets` orphan branch. Its presence signals that the reconciler is in `bootstrap-strict` mode. **Removing the file advances the rollout to `bootstrap-throttle`.**

**Exact advance command** (operator-run; requires tickets-branch write access):

```bash
git checkout tickets && git rm .reconciler-phase-gate && git commit -m 'advance phase gate' && git checkout -
```

The main guard sequence (`__main__.py`) checks for the gate file at startup. If `Mode == bootstrap-strict` and the gate file is absent, the orchestrator treats the mode as `bootstrap-throttle` for the current pass. This is the designed advance path — do not edit `mode.py` or the CLI invocation to skip the gate.

### 9-leaf dispatch table

`plugins/dso/scripts/dso_reconciler/reconcile.py` (task 577c) builds a lazy `_DISPATCH_TABLE` keyed by `(direction, action)` pairs. The 9 primary dispatch leaves are:

| Leaf key | Applier symbol |
|---|---|
| `inbound_create` | `_apply_inbound_create` |
| `inbound_update` | `_apply_inbound_update` |
| `inbound_delete` | `_apply_inbound_delete` |
| `inbound_clean_label` | `_apply_inbound_clean_label` |
| `inbound_repair_property` | `_apply_inbound_repair_property` |
| `inbound_probe` | `_apply_inbound_probe` |
| `outbound_create` | `_apply_outbound_create` |
| `outbound_update` | `_apply_outbound_update` |
| `outbound_delete` | `_apply_outbound_delete` |

Each leaf maps one `(direction, action)` combination to a bound applier method. The table is built lazily on first dispatch call. An unknown `(direction, action)` key raises `UnknownDispatchLeaf` — it is never silently skipped.

---

## INC-014: Noisy auto-bug creation — telemetry tickets and duplicate defer tickets (cf57)

**Pattern A — Recurring tool error tickets**: `end-session/error-sweep.sh` creates bug tickets for error categories that reach THRESHOLD. With the old threshold of 50, routine tool errors produced noise tickets with no actionable defect. Fixed by raising THRESHOLD to 500.

**Pattern B — Duplicate defer tickets**: `/dso:respond-to-pr-comments` Step 4 processes each deferred comment by calling `pr-comment-response.sh --classify-as <id>:defer` in a loop. If the LLM parallelizes these calls (Bash tool `run_in_background`), the defer handler's consolidation lookup races — all calls query `ticket list` before any ticket is created, so each creates a separate ticket instead of consolidating into one. Fixed by adding an explicit **CRITICAL — Sequential processing required for defer actions** note in Step 4 of the SKILL.md.

**Prevention**: When adding new ticket auto-creation paths, enforce deduplication at the creation site and ensure the guidance explicitly prohibits parallel dispatch when shared state (ticket list, shared JSON file) is involved.

---

## INC-015: Two-tier staged merge-to-main flow stuck → recovery (and direct-mode fallback)

**Symptoms** (under `dso.workflow=ci-pr`, the two-tier `source → staged-* → main` flow):
- `merge-to-main.sh --resume` aborts with `cross-strategy mismatch: state file was written with strategy='direct', but current config resolves to strategy='pr'` (a `pr`-mode run mis-recorded `merge_strategy=direct`; bug `3d23-becc`).
- `--resume` advances to an **empty** `staged-*` branch sitting at `main` HEAD and "loses" the work (bug `b7bf-c3b9`; fixed in `merge-to-main-pr.sh` — the advance predicate now requires the staged branch to carry work).
- A bare re-invocation mints a **duplicate** `staged-*` ref + PR1 (bug `73b5`; fixed — advance detection now runs unconditionally).
- PR1 (`source → staged-*`) is blocked by `check-staged-head` even though it targets `staged-*`, because a `base=main` **umbrella draft PR** (sprint Phase A `GitHubPRDefenseStore` substrate) fails `check-staged-head` on the shared head SHA and contaminates PR1 (bug `1f5f`; fixed — `check-staged-head` passes draft PRs).
- Repeated `review-sub-pr` false positives on the same diff across cycles.

**Recovery — pick by where you are in the flow:**

1. **Mid-flight (PR1 has already merged into `staged-*`)** — do NOT start over or switch strategy (switching to direct mid-flight is what triggers the cross-strategy abort). Complete **PR2** (`staged-* → main`):
   - Re-run `merge-to-main.sh --resume`. If it aborts on cross-strategy mismatch, patch the `/tmp` state file: set `merge_strategy` (NOT `strategy` — the guard at `merge-to-main.sh:86` reads `merge_strategy`) to `pr`, then re-resume. Keep `staged_branch` intact — deleting the state file loses it and `--resume` can no longer advance.
   - If PR2's `llm-review` false-positives (PR1's `review-sub-pr` was FP-recovered, so the commits aren't provenanced and the full-diff review re-runs), clear it via `/dso:fp-recovery <PR2>` or a human admin-merge.

2. **Starting fresh (no PRs opened yet)** — if the two-tier flow is fighting you, fall back to **direct mode** for the session: set `dso.workflow=local` (resolves `MERGE_STRATEGY=direct`). This opens a single `source → main` PR instead of the staged tiers.
   - **Caveat (important):** direct mode reviews the **full feature diff at once**, NOT the smaller sub-PR diffs the two-tier model is built around (reviewing small sub-PRs is the two-tier's primary goal). Use direct mode as a recovery / small-change path, not the default. The change still gets a full LLM review — it is coarser, not skipped.

**Direction of travel:** the MQ migration (epic `1a6c`, MQ-4) retires the `staged-*`/PR1/PR2 two-tier entirely in favor of `session → main` direct through the GitHub Merge Queue — direct-mode-shaped, but with required checks re-run on the queue's combined candidate. This INC is a bridge until then.

**Config reference:** `dso.workflow` (`ci-pr` | `local`) — see `plugins/dso/docs/CONFIGURATION-REFERENCE.md` and the two-channel semantics in `plugins/dso/docs/CI-INTEGRATION.md`.
