# Remediation Plan — Finding #3 (fail-open enforcement hooks) & #4 (fragile parse/classify)

Verified against `origin/main` HEAD `7f16f682d8` (worktree identical, 0 diff). Incorporates opus design review (2026-05-30).

## STATUS (2026-05-30 cost/benefit decision)
After review, the per-call fail-closed *dispatch rewrite* (Finding #3 Phases 0-3) was judged NOT worth its hot-path/brick risk vs. a conjunction-of-narrow-events threat that Layer 1 (already fail-closed) + CI shellcheck/hook-tests largely cover. **Executed instead (the cheap, off-hot-path, high-leverage subset):**
- **Item 1 — DONE:** sentinel allow-on-unparsed → fail-closed with `json.loads` recovery (`review-gate-bypass-sentinel.sh`; closes the `--no-verify`-skips-Layer-1-when-sentinel-silently-disabled hole without adding common-case hot-path cost). Tests: `tests/hooks/test-review-gate-bypass-sentinel.sh` (54/54).
- **Item 2 — DONE:** off-hot-path `check-hook-integrity.sh` (present + executable + `bash -n`), enforced two ways: a direct `hook-integrity-check` pre-commit entry (commit-time, runs when any `hooks/` file changes) AND `tests/scripts/test-check-hook-integrity.sh` in the CI Script Tests suite — committed hook breakage is blocked at commit and turns CI red.
- **Finding #3 dispatch rewrite — DEFERRED / evidence-gated:** revisit only if the existing `~/.claude/logs/dso-hook-errors.jsonl` telemetry shows real silent-degradation incidents. The full design below is retained for that contingency.

## Executive summary
- **Goal (precise):** in `dso.workflow=local` mode the git pre-commit gates (Layer 1) are already fail-closed and are the real review/test enforcement; the genuine hole is that a *silently-disabled bypass sentinel* (Layer 2, PreToolUse) lets `git commit --no-verify` / `core.hooksPath=` / `commit-tree` skip Layer 1. This plan closes that, and replaces the sentinel's allow-on-unparsed-input with fail-closed — without bricking the interactive hot path.
- **Disposition:** fail-CLOSED on guard-*logic* errors and unparsable input; stay fail-OPEN (logged) on *environmental* errors; keep advisory hooks fail-open; defer the high-risk regex→classifier rewrite behind compare-only.

## Why now / what's actually broken (verified)
Local-mode enforcement chain:
- **Layer 1 (the real gate, already fail-closed):** `pre-commit-review-gate.sh` (allowlist + `review-status=passed` + diff-hash, exit 2/1 at `:448-524`) and `pre-commit-test-gate.sh` (fail-closed on missing/not-passed/hash-mismatch/timeout). Run via `pre-commit-wrapper.sh`/`bash -c` — NOT through `run-hook.sh`.
- **Layer 2 (PreToolUse bypass prevention, currently fail-OPEN):** `hook_review_bypass_sentinel` blocks `--no-verify`/`core.hooksPath`/`commit-tree`/gate-file & `.tickets-tracker` writes (`review-gate-bypass-sentinel.sh`).
- **CI (`ci-pr` only):** `llm-review` runs only on `base==main` (`ci.yml:349,485`); in `local` mode there is no PR, so Layer 1 is the sole enforcement.

Fail-open points (the bug):
- `run-hook.sh`: missing/empty hook → `exit 0` (L35-38); `bash -n` syntax error → log + `exit 0` (L85-96).
- `dispatcher.sh` `run_hooks()`: non-executable skipped (L46-48); only exit 2 blocks, any other non-zero = allow (L62).
- `pre-bash.sh` `_pre_bash_dispatch`: only `_fn_exit==2` blocks (L116-120).
- `pre-bash-functions.sh`: every guard's `trap '…log…; return 0' ERR` fails open on ANY error.
- Sentinel: skips entirely under `dso.workflow=ci-pr` (L35); **allows on empty/unparsed command** (L50-52); `python3` already required for quote-strip (L68-82).

## Cross-cutting constraints
- **Hot path:** runs on every Bash/Edit/Write call — no new per-call `python3` forks; measure before/after with the existing `~/.claude/hook-timing-enabled` instrumentation (`run-hook.sh:52-62`).
- **No mass-brick:** the fail-open→fail-closed flip ships behind shadow mode + an auditable recovery valve — except the integrity trio (below), which enforces immediately.
- **Single source of truth:** reuse the existing `# hook-boundary: enforcement` annotation + `pre-commit-enforcement-boundary-check.sh` — do NOT introduce a parallel classification map.
- **TDD:** extend `tests/hooks/{run-hook-tests,test-review-gate-bypass-sentinel,test-dispatcher-framework,test-deps}.sh`; author NEW hook fixtures (the `tests/fixtures/degradations/fail-open` fixture is a PRECONDITIONS fixture, not a hook one).

---

## Finding #3 — fail-closed for enforcement hooks

**Phase 0 — Classify via the existing mechanism.** Extend the `# hook-boundary: enforcement` convention to the PreToolUse guards and teach `pre-commit-enforcement-boundary-check.sh` about per-function annotations; update its doctrine so an enforcement guard may emit a structured `GATE_UNAVAILABLE` log without counting as "uses the fail-open handler." Classification:
- **Enforcement:** `hook_test_failure_guard`, `hook_review_bypass_sentinel`, `hook_review_integrity_guard`, `hook_blocked_test_command`, `hook_tickets_tracker_bash_guard`, `hook_no_force_merge`, `hook_no_edit_on_main`, `hook_force_close_guard`, worktree guards.
- **Advisory (stay fail-open):** `hook_commit_failure_tracker` (`pre-bash-functions.sh:117` "NEVER BLOCKS"), timing/logging.

**Phase 1 — Fail-closed dispatch, discriminating error class.**
- Guard ERR traps: block (`return 2`) only on guard-**logic** failure; on **environmental** I/O failure (e.g. `hook_no_edit_on_main`'s `git rev-parse` at `:508-518`, worktree guards' git calls) fail-OPEN with a logged `GATE_UNAVAILABLE` record — mirror the Tier-A `_dso_gate_unavailable` pattern. This is the single biggest false-denial risk; a blanket flip would brick every Edit/Bash on a transient git hiccup.
- `pre-bash.sh` (L116-120): enforcement fn unexpected non-zero (not 0/2) → `return 2` + diagnostic; advisory → allow+log.
- `dispatcher.sh` (L46-62): non-executable / unexpected-exit enforcement hook → block; advisory → skip/allow.
- `run-hook.sh` (L35-38, 85-96): for a **hardcoded literal** allowlist of enforcement PreToolUse dispatchers (`dispatchers/pre-bash.sh`, `pre-edit.sh`, `pre-write.sh`), missing-file/syntax-error → `exit 2` + structured message; all other dispatchers (Post/Stop/SessionStart) keep fail-open.
- Preserve `_dso_enforcement_gate_check`'s default-to-`local`/enforce on read-config failure (`enforcement-gate.sh:43-47`).

**Phase 2 — Auditable recovery valve (scoped).** `DSO_HOOK_RECOVERY_BYPASS=<hook_name>` + non-empty paired reason (mirror `DSO_*_ACTIVE_BYPASS_REASON`), JSONL-audited. **No escape** for the integrity trio: `review_bypass_sentinel`, `review_integrity_guard`, `no_force_merge`.

**Phase 3 — Shadow rollout (with carve-out).** `DSO_HOOK_ENFORCEMENT_MODE=shadow|enforce`, default shadow one release (log `WOULD-HAVE-BLOCKED`, still allow) → then enforce. The integrity trio is **excluded from shadow** (enforces immediately) — otherwise the release-long shadow window reopens the `--no-verify` hole.

**Phase 4 — Tests.** New hook fixtures + extend: run-hook-tests (enforcement dispatcher syntax-error → exit 2; advisory → 0; environmental error → fail-open + `GATE_UNAVAILABLE`); dispatcher-framework (enforcement returns 3 → block); recovery-valve requires reason + audits; integrity-trio has no escape and is shadow-exempt.

---

## Finding #4 — harden parsing; defer the classifier rewrite

**Phase 1 — Fix allow-on-unparsed in the sentinel (highest value, lowest risk).** Sentinel L50-52: when `tool_name==Bash` and command extraction is empty/unparsable, fail-CLOSED (block "could not parse command") instead of `return 0`. Harden the parse using `json.loads` **only within the sentinel's already-`python3` span** (the quote-strip at `:68-82`), so no new hot-path fork is added.

**Phase 2 — Keep `parse_json_field` pure-bash on the hot path.** It is the zero-fork input consumer for the whole guard chain (`deps.sh:49-168`, called ~2-10×/tool-call); do NOT route it through `python3`. Hardening lives in the sentinel (the actual security boundary), not the shared parser.

**Phase 3 — Table-driven classifier (SEPARATE, compare-only project; not bundled).** `hooks/libexec/bash_command_classifier.py` tokenizes and classifies by kind (git commit / `update-ref` / `commit-tree` / gate-file & `.tickets-tracker` writes), handling redirects/quoting/substitution. Run alongside the regex sentinel, log divergences, build a corpus seeded with the existing tuned cases (WIP exemption L56, quoted-desc bug 63a6, two-path detection bug 4600), then cut over. Defer because a clean-room rewrite of 11 FP-tuned regexes is the riskiest change here.

**Phase 4 — Tests.** Extend test-deps (json.loads: nested/escaped quotes, multiline, unicode); extend sentinel test (unparsable Bash command → block; ALL existing bypass + FP cases still pass: WIP, quoted descriptions, `--no-verify`, `commit-tree`, `.git/hooks`, `.tickets-tracker`).

---

## Sequencing
1. **#3 Phase 0-1 + #4 Phase 1-2 together** (a parse failure becomes a fail-closed block), shipped **shadow → enforce**, integrity trio enforcing immediately.
2. **#4 Phase 3** as a separate compare-only project.

## Success criteria
- A syntax-errored / missing / chmod-stripped **bypass sentinel** can no longer let `git commit --no-verify` reach a commit in `local` mode (the closed hole).
- A transient `git rev-parse`/IO failure inside an enforcement guard does NOT block the tool call (no session-brick); it logs `GATE_UNAVAILABLE`.
- Integrity trio enforces in shadow and has no env escape.
- Hot-path latency delta is measured (timing instrumentation) and within noise; zero new `python3` forks in `parse_json_field`.
- Layer 1 git gates remain untouched and primary.

## Out of scope / risks
- This does not change Layer 1 (already fail-closed) or `ci-pr` behavior (CI is the backstop there).
- Biggest residual risk: misclassifying an environmental error as a logic error → false denial. Mitigated by error-class discrimination + shadow mode + the timing/divergence telemetry.
- All files here are safeguards (`rule:no-safeguard-edits`) and shared with the CI/PR workstream → requires explicit approval + coordination before implementation.
