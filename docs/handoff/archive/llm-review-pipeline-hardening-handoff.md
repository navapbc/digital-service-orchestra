> **HISTORICAL** — captured during a prior planning iteration. Live system state has evolved.
> For current architecture, see `docs/contracts/sub-pr-enforcement.md` (if exists) and this handoff doc.

# Handoff: LLM Review Pipeline Hardening (post-PR-442)

Continuation of the original LLM-review-enforcement audit captured in
`docs/handoff/llm-review-enforcement-handoff.md`. After PR-3 (#438) and
PR-4 (#442) landed, two NEW classes of CI llm-review failure surfaced
on subsequent PRs. This document captures the remediation plan and
current state.

## Where we are

Two bugs filed and partially fixed in parallel. Two PRs open on the
remediation. Several follow-up PRs scoped but not yet started.

### Bugs filed this session

| Ticket | Title (short) | Status |
|--------|---------------|--------|
| `f148-2cb6-8b7e-4cdd` | LLM returns non-JSON + Reviews API 422 → stale prior-cycle findings as blocking (the original f432/f439 failure mode) | in_progress; PR-A in flight |
| `7f55-d357-dbf6-43b5` | Strategy F multi-cluster aggregator crashes on str-shaped per-cluster findings (`'str' object has no attribute 'get'`) | in_progress; PR open |
| `12a6-d063-875e-4ed0` | Ticket-CLI push fails with stale "merge conflict, attempt 1" warning (dirty WD on reconciler-owned .bridge_state/*) | **CLOSED — merged via #444** |
| `34b2`, `3706`, `a530` | Host-portability P0 bugs (check-skill-refs.sh, qualify-skill-refs.sh, check-test-isolation.sh REPO_ROOT resolves to plugin cache) | open; deferred |
| `3bda`, `8229` | Host-portability P2 (fixture paths not shipped, lint hook for SCRIPT_DIR/.. anti-pattern) | open; deferred |

### Active PRs

- **#448 — bug 7f55 fix** (branch `fix-7f55-strategy-f-attribute-error`):
  - 2 commits: `35b505b4db` (fix + 9 tests) and `ff7373f6d0` (drop
    hardcoded line numbers from test comments — addressed llm-review
    finding on cycle 1).
  - Status: CI re-running on `ff7373f6d0`.
  - Three producer-side type guards in `runner._run_cluster` +
    `aggregator._synthesize_via_llm` + log reframe at `runner.py`
    "ERROR: LLM call failed" → "review pipeline crashed".

- **#449 — bug f148 PR-A** (branch `fix-f148-llm-review-infra-pr-a`):
  - 3 commits: `67f75a2be6` (R1+R2+R3+R5 + 4 fixtures + 13 tests),
    `079bda43e0` (per-test ANTHROPIC_API_KEY monkeypatch — CI fix),
    `2f1ed329fc` (autouse ANTHROPIC_API_KEY fixture in tests/conftest.py
    — repo-wide hardening per user request).
  - Status: CI re-running on `2f1ed329fc`.
  - Original CI failure: `Python Skill/Doc Tests` → `ConfigError:
    Missing ANTHROPIC_API_KEY`. Test invoked `dispatch_review` which
    validates provider config before the mocked litellm.

### PRs merged this session (context)

- **#438** PR-3 (required-checks manifest cleanup + ruleset 15629023
  PATCH adding Actionlint + merge-pipeline-checks)
- **#440** Dispatcher logging additions (BASE/HEAD SHAs banner, DECISION
  lines on silent skip paths) + merge-to-main.sh PR-body fix
- **#442** PR-4 (sub-PR ruleset redesign: include=["~ALL"],
  exclude=["refs/heads/main"]; host-portable DEFAULT_BRANCH; jq→python3
  port; shared lib/default-branch.sh)
- **#444** Bug 12a6 fix (ticket-lib.sh _push_tickets_branch dirty-WD
  recovery via stash+merge+pop)
- **#446** Bug-audit F3/F4 (assert-review-liveness.sh +
  match-session-branch.sh)

## The R1–R7 remediation plan for bug f148

Identified during the f148 investigation; reviewed twice by opus
reviewer subagents (REVISE → APPROVE after 8 must-dos addressed).
Multi-PR sequencing. **PR-A (R1+R2+R3+R5) is PR #449 — shipped.**
PR-B/C/D remain.

### PR-A — recurrence prevention core (PR #449 — IN FLIGHT)

- **R1** `runner._resolve_pr_head_sha` event-aware. On
  `pull_request` / `pull_request_target` events, GITHUB_SHA is the
  synthesized merge-commit SHA, not the PR HEAD → Reviews API 422.
  Reorder to prefer `gh pr view --json headRefOid` on PR events;
  fall back to GITHUB_SHA with WARNING. Extracted `_gh_pr_head_oid`
  helper.
- **R2** `dispatch.py` dispatch chain: insert `except ValueError as
  parse_exc: ... continue` BEFORE the generic `except Exception`. Prior
  behavior was to `break` on the re-raised ValueError, exhausting the
  context chain on the first parse failure.
- **R3** `dispatch.py:_parse_response`: log first 1024 bytes of
  raw_content (control-chars escaped, newlines escaped) on stderr when
  parsing fails. The pre-fix log only emitted `length=275` with no body
  — undiagnosable.
- **R5** `providers/anthropic.py:74-80`: legacy adapter had bare
  `json.loads`. Apply the same `_extract_json_from_text` rescue that
  `dispatch._parse_response` uses (mirrors the modern path for shape
  consistency).

### PR-B — JSON-only retry rescue (NOT STARTED)

- **R6** New helper inside `dispatch_arch_synthesis` (or sibling). On
  `ValueError` from `_parse_response`, single retry with system-prompt
  suffix `"CRITICAL: Return ONLY a JSON object. No preamble, no
  markdown, no explanation. Start your response with '{' and end with
  '}'."`. Idempotency guard via structured sentinel
  (`name="__dso_json_only_retry__"` private message — NOT literal-string
  match per reviewer MD-2). Single-retry, ValueError-only, append hop
  record so defense ledger sees the rescue. Config-gated for rollback:
  `DSO_REVIEW_JSON_ONLY_RETRY_ENABLED`.

### PR-C — exit code 4 for infrastructure failure (NOT STARTED)

- **R4** When `arch_all_synthetic == True` (specialist findings only,
  arch synthesis failed), `main()` returns 4 instead of 1. CI workflow
  step "Classify llm-review failure" reads the exit code and surfaces
  "infrastructure failure" rather than "review found problems". Update
  `plugins/dso/docs/contracts/review-defenses.md` to document. Feature
  flag: `DSO_INFRA_EXIT_CODE_ENABLED`. **Ship alone for clean
  rollback** — couples runner.py to ci.yml.

### PR-D — cycle-counter SHA-reset (DISCOVERY SPIKE FIRST)

- **R7** The original diagnosis (force-dispatch on every merge-SHA
  reset) was misdirected at `llm-review-dispatch-or-skip.sh:154`. That
  script already uses PR HEAD SHA (`gh api .../pulls/${PR}.head.sha`).
  The real reset is somewhere in `cycle_dispatcher.py:228, 242, 282`
  and `cycle_ledger.py`. LEDGER-SAFE comments at `runner.py:2627`,
  `:2658`, `:2676` explicitly document the SHA-reset behavior as
  intentional under the cycle-1 short-circuit.
- **Deliverable**: `docs/findings/cycle-ledger-sha-reset-spike.md`
  documenting (a) the exact code path where cycle counter resets to 1,
  (b) what SHA-key the defense ledger uses (merge vs HEAD), (c) whether
  the reset is intentional under any operational scenario, (d) proposed
  fix design + which LEDGER-SAFE comments need updating.
- Code change ONLY after spike is reviewed.

## Cross-cutting items the plan reviewer flagged

1. **Replay fixtures** (shipped with PR-A): 4 files under
   `tests/fixtures/llm-review-replay/`:
   - `non-json-275.txt` — 275-byte refusal matching original PR #432 failure
   - `markdown-fenced.txt` — valid JSON in ``` ```json fence ``` ```
   - `friendly-preamble.txt` — preamble + JSON
   - `refusal.txt` — safety refusal with no JSON at all
2. **Contract doc update**: `plugins/dso/docs/contracts/review-defenses.md`
   needs the exit code 4 semantics added (with PR-C / R4).
3. **LEDGER-SAFE comment updates**: `runner.py:2627`, `:2658`, `:2676`
   when R7 lands.
4. **Rollback feature flags** (all default 1):
   - `DSO_REVIEW_PARSE_RESCUE_ENABLED` (R5 + R6 path)
   - `DSO_INFRA_EXIT_CODE_ENABLED` (R4)
   - `DSO_REVIEW_JSON_ONLY_RETRY_ENABLED` (R6)
5. **Repo-wide test fixture** (shipped with PR-A): autouse
   `_dso_dummy_anthropic_api_key` in `tests/conftest.py` — sets a
   non-functional `sk-test-...` key so provider-config-validated paths
   work in CI jobs without secrets exposure. Negative tests that probe
   missing-key (`test_providers_config.py:110`) continue to work via
   per-test `monkeypatch.delenv`.

## Key files and concepts

### Source-of-truth files

- `plugins/dso/scripts/dso_ci_review/runner.py` —
  `_resolve_pr_head_sha` (PR-A R1), `_run_cluster` (bug 7f55), `main()`
  exit code (PR-C R4 future), LEDGER-SAFE comments (PR-D R7 future).
- `plugins/dso/scripts/dso_ci_review/dispatch.py` —
  `_parse_response` (PR-A R3), fallback chain `except ValueError`
  (PR-A R2), `dispatch_arch_synthesis` (PR-B R6 future).
- `plugins/dso/scripts/dso_ci_review/aggregator.py` —
  `_synthesize_via_llm` shape guard (bug 7f55), `_deduplicate_findings`
  (consumer that crashed on bug 7f55).
- `plugins/dso/scripts/dso_ci_review/providers/anthropic.py` —
  legacy adapter rescue (PR-A R5).
- `plugins/dso/scripts/dso_ci_review/cycle_dispatcher.py` +
  `cycle_ledger.py` — PR-D R7 spike targets.
- `plugins/dso/scripts/dso_ci_review/findings.py:21` —
  `_extract_json_from_text` (the rescue function R5 imports).

### Investigation reports

Two opus investigation subagents ran during this session. Both
returned strong RESULT envelopes with multiple confirmed hypothesis
tests. Findings are quoted verbatim in commit messages of `67f75a2be6`
(PR-A) and `35b505b4db` (PR #448).

## How to check status

```bash
# PR state
gh pr view 448 --json state,mergeStateStatus,headRefOid,title
gh pr view 449 --json state,mergeStateStatus,headRefOid,title
gh pr checks 448
gh pr checks 449

# Bug tickets
.claude/scripts/dso ticket show f148-2cb6-8b7e-4cdd
.claude/scripts/dso ticket show 7f55-d357-dbf6-43b5

# Watch PRs to terminal
bash plugins/dso/scripts/wait-for-pr.sh 448
bash plugins/dso/scripts/wait-for-pr.sh 449
```

## Worktree map

| Worktree | Branch | Purpose |
|----------|--------|---------|
| `worktree-20260527-171753` | (session worktree, post-PR-442 base) | This handoff doc; orchestrator-level work |
| `worktree-f148-20260528-201232` | `fix-f148-llm-review-infra-pr-a` | PR #449 (PR-A: R1/R2/R3/R5) |
| `worktree-7f55-20260528-202212` | `fix-7f55-strategy-f-attribute-error` | PR #448 (bug 7f55 Strategy F) |
| `worktree-pr4-20260528-174507` | merged | Prior PR-4 worktree (#442) |
| `worktree-f3f4-20260528-194349` | merged | Prior F3/F4 worktree (#446) |
| `worktree-logging-20260528-170557` | merged | Prior logging worktree (#440) |
| `worktree-pr3-20260528-122306` | merged | Prior PR-3 worktree (#438) |
| `worktree-12a6-20260528-184534` | merged | Prior bug 12a6 worktree (#444) |

The merged worktrees can be `git worktree remove`'d safely; left for now
in case of follow-up needed.

## Next steps once PR #449 and #448 merge

1. **Bug 7f55**: ticket transition to closed with the `--reason="Fixed:
   ..."` summary captured in PR #448's commit message.
2. **Bug f148 PR-B (R6)**: start the JSON-only retry rescue. New
   worktree off origin/main. Single-retry, ValueError-only,
   sentinel-tagged idempotency guard. Hop record emission.
   Config-gated.
3. **Bug f148 PR-C (R4)**: exit code 4 for arch-all-synthetic.
   Coordinates runner.py + ci.yml + contract doc. Ship alone.
4. **Bug f148 PR-D spike**: write `docs/findings/cycle-ledger-sha-reset-spike.md`.
   No code change. Hand to user for review of proposed fix design before
   implementing.
5. **Host-portability P0s** (bugs 34b2, 3706, a530): the
   `REPO_ROOT=SCRIPT_DIR/..` pattern in three plugin-scripts. Fix is
   `REPO_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel)}"`.
   Established pattern at `check-rule-anchors.sh:48`.

## Audit history (for context)

The independent opus audit prompt from
`docs/handoff/llm-review-enforcement-handoff.md` was re-run on the
post-PR-442 state and identified additional gaps (F3/F4 — fixed via
PR #446; F1/F2/F5 deferred):

- **F1** Live ruleset 16961402 was missing 7 of 12 patterns — fixed by
  PR #442 ruleset PATCH.
- **F2** Routine admin merges on red llm-review — STILL OPEN. PRs #432,
  #439, #419, #425, #430, #435, #448, #449 all admin-merged or pending.
  Recommended: require bypass_reason audit-log artifact. Not started.
- **F3** Review liveness gated on code_changed=true — fixed by PR #446.
- **F4** API cross-branch fallback regex hardcoded to ^worktree- —
  fixed by PR #446.
- **F5** Sub-PR ruleset bypass_mode=`always` — STILL OPEN. PR-5 in the
  original handoff. Not started.

## Open questions

1. Should bug 7f55 transition to closed automatically after PR #448
   merges, or wait for user confirmation? (User instruction earlier in
   session: "do not execute any ticket operations until I tell you
   otherwise" — that gate is still active as of the last user message.)
2. PR-B/C/D sequencing — user previously approved A/B/C/D split but
   may want to reprioritize given the host-portability and admin-merge
   backlogs.
3. The 5 host-portability bugs (34b2/3706/a530/3bda/8229) were filed
   but deferred. They block host projects from using these scripts
   correctly. Worth a focused mini-epic.
