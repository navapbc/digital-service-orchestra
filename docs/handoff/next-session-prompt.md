# Next-Session Handoff Prompt (paste into a fresh Claude Code session)

Last updated: 2026-05-21. Authored at the close of session 2026-05-20–21 on branch `worktree-20260520-153616`.

---

## Paste-ready prompt

> We are continuing the **Closure Checks schema migration** under epic `a03c-d55e-1393-4f27`. The prior session (2026-05-20–21) closed stories `5362-7f18-4f37-4fa9` and `ad70-f38a-7684-4e00`, ran the Phase 3.5 coherence walkthrough to PASS against a03c, and executed the first batch of the Phase 4 bulk classifier migration: **13 of 70 brainstorm:complete-tagged epics processed**, audit comments and SC→CC moves landed per the contract, `MIGRATION_RUN_SUMMARY` recorded on a03c with `migration_run_id=ccd7b51c-6e50-4e6d-ad9b-1bfbae5c705c`.
>
> **Do two things in this session:**
>
> **(A) Continue the bulk migration for the remaining 57 epics, in batches.**
>
> Read `docs/handoff/closure-checks-migration-batch-2.md` — it contains the canonical list of 57 pending epic IDs, the driver script, the plan/apply orchestration flow, and the per-item ack heuristics learned from session 1. Then:
>
> 1. Pick 10–20 epic IDs from the pending list. Paste them into the driver script's `REMAINING_EPICS` array.
> 2. Mint a fresh `migration_run_id` (UUID4). Run the driver to write plan files into `$WORKDIR`.
> 3. Aggregate the needs-ack items across plans. Present each via `AskUserQuestion` (4 items per call max). Apply the same heuristics from the handoff doc: durable-state items stay in SC even with past-tense verbs; one-time verification/validation tasks move SC→CC; documentation references under schema definitions stay in SC.
> 4. Write per-epic decisions JSON files. Invoke `closure-checks-classifier-pass.sh --apply-from-plan` per epic.
> 5. Post a `MIGRATION_RUN_SUMMARY` comment on `a03c-d55e-1393-4f27` with the new `migration_run_id`, start/end timestamps, and per-epic counts.
> 6. Repeat batches until all 57 pending epics are migrated. Honor the 25-ack-per-session budget (DD5).
>
> Expect each batch to cover ~10–20 epics and consume ~25 user prompts via `AskUserQuestion`. The script's `r=5` auto-apply policy keeps the manual surface small.
>
> **(B) Brainstorm and execute the last story under a03c: `e26d-b59d-5484-4e1f`.**
>
> Story title: *"As a release engineer, synthetic end-to-end LLM dispatch tests verify brainstorm routing and verifier refused-closure behavior"*. The story has `scrutiny:pending` and 6 DDs (DD1–DD6) that re-implement epic SC7 + the SC9-rejection test.
>
> Use the **enrich-in-place** brainstorm path (matching how 5362 and ad70 were handled). Lock decisions, write to the story description, then execute directly per the user's "drop the ceremony" pattern: build artifacts, commit, dispatch the named `dso:completion-verifier` agent, close on PASS.
>
> **Key design decision for e26d's brainstorm (the user has not yet chosen):** DD4 lists three test-infrastructure options:
>
> 1. **Recorded-fixture LLM dispatches** (JSONL cassettes; precedent: `tests/mocks/jira-cassette-loader.py`)
> 2. **Mocked HTTP** (stdlib HTTP server stubbing the Anthropic endpoint; precedent: `tests/mocks/github-api-server.py`)
> 3. **Structural proxy** (precedent: `verifier-corpus-replay.sh` wiring mode + `tests/fixtures/verifier-corpus/`)
>
> **Important constraint to surface to the user:** SC7 and SC9 verify the behavior of `/dso:brainstorm` as a **SKILL dispatch** (Claude interpreting `SKILL.md`), not a script calling the Anthropic API. None of the three options cleanly tests "Claude interpreting a SKILL.md". The brainstorm decision is which proxy is closest to acceptable:
>
> - **Structural proxy** (the orchestrator's preliminary recommendation): test the RULES that drive routing — parse `verifiable-sc-check.md` and assert litmus + accept/reject examples; parse `brainstorm/SKILL.md` and assert it cites the litmus at the right gate; parse `approval-gate.md` and assert `## Closure Checks` renders in the Gate Template; parse the refusal copy and assert it names the one-shot-verifiable requirement for SC9. Pros: deterministic, fast, no API key, no precedent gap. Cons: doesn't catch "rules say X but model does Y" failure mode (mitigated in practice by frequent dev-lifecycle brainstorm dispatches).
> - **Hybrid** (structural proxy in CI + smoke-test recipe `scripts/closure-checks-e2e-smoke.sh` for operators to run periodically with real LLM dispatch): same CI behavior as #1 plus a manual fidelity-check path.
>
> Ask the user to choose between **structural proxy alone** vs **hybrid (proxy + smoke-test recipe)**. The two live-dispatch options (recorded fixtures, mocked HTTP) are less aligned with what SC7/SC9 actually verify.
>
> After the test-infra decision: also lock decisions about (a) what fixture inputs the structural tests load (one SC of each kind embedded in test fixtures? Or grep against the SKILL.md+prompts directly?); (b) where the tests live (`tests/scripts/` or `tests/hooks/` — both have precedents); (c) the regression-detection guarantee for DD6.
>
> **Execution mirrors 5362/ad70**: build artifacts, smoke-test, commit via `git commit` (review-gate skipped under `dso.workflow=ci-pr`), dispatch `dso:completion-verifier` on e26d, close on `P1: PASS`.
>
> **Reference commits from the prior session** (branch `worktree-20260520-153616`):
> - `251c119f62` feat(5362): six-chunk coherence walkthrough infrastructure
> - `a30e415a41` feat(ad70): `--classify` flag on `migrate-closure-checks.sh`
> - `1afe9c849b` fix(ad70): preview script field-name fix
> - `4b1691c520` fix(a03c): coherence walkthrough remediation (chunks A and D)
> - `2892927664` feat(ad70): Claude-driven ack flow (`--plan-output` / `--apply-from-plan`)
> - `ce2ec1a65c` fix(ad70): smart extraction + auto-apply r=5 (DD4 amendment)
> - `a8829be0df` fix(ad70): apply-from-plan honors proposed_target + override_target
> - `0ad7cb86d6` fix(ad70): remediate 3 IMPORTANT review findings
> - `31f5974b2d` fix(ad70): remediate re-review findings (mktemp + synthetic test IDs)
> - `d35f63727c` docs: session handoff for batch 2+
>
> **Reference artifacts**:
> - Story `e26d-b59d-5484-4e1f` description (read with `.claude/scripts/dso ticket show e26d-b59d-5484-4e1f`)
> - Migration handoff doc: `docs/handoff/closure-checks-migration-batch-2.md`
> - Audit contract: `plugins/dso/docs/contracts/closure-checks-classifier-audit.md`
> - Classifier helper: `plugins/dso/scripts/closure-checks-classifier-pass.sh`
> - Smoke tests: `tests/scripts/test-closure-checks-classifier-pass.sh`, `tests/scripts/test-coherence-walkthrough.sh`, `tests/scripts/test-closure-checks-migration-preview.sh`
>
> **Workflow constraints carried over from the prior session**:
> - `dso.workflow=ci-pr` is configured; local review-gate skips; pre-commit hooks still enforce contract-schema, plugin-self-ref, shellcheck, and compliance-verifier.
> - `always:mktemp-tmp`: any write to /tmp must use mktemp. Tests must not hardcode session-ids or paths.
> - Bug `9894-a463-090a-43e5` (CLI alias rejection) is open and not blocking — use full canonical IDs (`a03c-d55e-1393-4f27`, `e26d-b59d-5484-4e1f`) until that fixes.
> - The tickets-tracker-guard pre-bash hook blocks direct grep/ls on the orphan ticket-tracker directory — go through `.claude/scripts/dso ticket *` commands instead.
>
> Begin with (A) since the migration is operational continuation; (B) is a fresh decision point. Confirm the user's choice on test infra before drafting e26d's brainstorm description.

---

## Where this lives

This document is committed at `docs/handoff/next-session-prompt.md`. Copy the block above (everything between the two `---` lines), paste it into a fresh Claude Code session, and the session will have the context it needs.

The pasted prompt assumes the new session is opened on branch `worktree-20260520-153616` (or its successor after merge to main, in which case the commit SHAs above will be unchanged and discoverable via `git log`). If the session opens on a different branch, the first action should be a `git checkout` to a worktree that has access to these commits and the handoff docs.
