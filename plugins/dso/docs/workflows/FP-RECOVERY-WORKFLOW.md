# FP Recovery Workflow

Manual escalation path when CI `llm-review` blocks a PR on a finding that looks like a false positive. This workflow preserves the coverage guarantee (every merge has a real LLM review behind it) while unblocking shipping when the CI reviewer hallucinates.

This is an **escape valve**, not a routine path. Routine PRs ship through `/dso:commit` + `merge-to-main.sh` as normal. This workflow is invoked only when CI `llm-review` is failing on a finding the engineer believes is invalid.

---

## When to invoke

All of the following must hold:

1. The PR's required check `llm-review` (ci.yml) has reported `failure`.
2. All other required checks pass (or have known intermittent failures filed as bugs — see bug `53f9-a218-8799-49be`).
3. The PR's CI output does **NOT** contain an `OVER_BOUND:` marker. OVER_BOUND means the PR exceeded the `max_files × max_calls` hard upper bound before the LLM reviewer ran — there is no LLM finding to adjudicate. Use Step 0's eligibility check to confirm.
4. The engineer believes the blocking finding is an FP after reading it. Common FP signatures:
   - Claims about variable types that can be refuted by reading the script (e.g., the int-vs-string FP on PR #213 cycle 1).
   - Claims about missing files that exist under a different subdirectory (mitigated by the cascade fix in PR #213 but not eliminated).
   - Speculative reachability assertions ("an attacker could control X") without naming a specific re-shelling sink (NOT-flag Rule 4 in the standard reviewer).
   - Misreads of the diff against stale line numbers from earlier cycles (Stale-context detection should catch but sometimes doesn't).

If the finding is genuinely uncertain — not clearly an FP — do NOT use this workflow. Use the standard defense-store path (write a defense, let the resolution loop or arbiter adjudicate).

---

## Procedure

### Step 0: OVER_BOUND pre-check (mandatory — do this before anything else)

Before capturing the diff or dispatching any reviewer, verify that the PR's CI llm-review status is `FP-suspected` (i.e., the LLM actually ran and produced a finding), not `OVER_BOUND` (i.e., the PR was rejected before LLM dispatch due to exceeding the `max_files × max_calls` hard upper bound).

```bash
# Fetch the llm-review job log for the PR's head commit
PR_NUMBER="<the PR number>"
CI_LOG_FILE=$(mktemp /tmp/fp-recovery-ci-log.XXXXXX)
gh run list --workflow=ci.yml --branch "$(gh pr view "$PR_NUMBER" --json headRefName --jq '.headRefName')" \
    --limit=1 --json databaseId --jq '.[0].databaseId' \
    | xargs -I{} gh run view {} --log 2>/dev/null | grep -A5 "Run LLM review" > "$CI_LOG_FILE" || true

# Run the eligibility check
DSO_CI_LOG="$CI_LOG_FILE" bash "${CLAUDE_PLUGIN_ROOT}/scripts/check-fp-recovery-eligibility.sh"
```

If the eligibility check exits non-zero (OVER_BOUND detected), **stop immediately** and emit:

> `OVER_BOUND PRs are not eligible for FP-recovery — these require admin attention (chunking budget exceeded, not a false-positive).`
> `The CI llm-review never ran on this PR because it exceeded the max_files × max_calls hard upper bound.`
> `Next step: request admin review or split the PR into smaller chunks.`

Do NOT proceed to Step 1 for an OVER_BOUND PR. The `check-fp-recovery-eligibility.sh` script emits these messages to stderr when it detects the `OVER_BOUND:` marker in the CI log. Surface them to the user and exit.

If the eligibility check exits 0, continue to Step 1.

### Step 1: Capture the PR diff

Capture the diff from the PR's merge-base on `main` (or whichever base the PR targets) to the PR HEAD:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
PR_NUMBER="<the PR number>"
PR_HEAD_SHA=$(gh pr view "$PR_NUMBER" --json headRefOid --jq '.headRefOid')
PR_BASE_REF=$(gh pr view "$PR_NUMBER" --json baseRefName --jq '.baseRefName')

# Per CLAUDE.md "Always Do These" #15 — use mktemp for /tmp writes to avoid
# collisions under parallel invocation. The reviewer dispatch in Step 2 writes
# reviewer-findings.json into this directory; a fixed shared path would collide
# across concurrent FP-recovery runs on different PRs.
ARTIFACTS_DIR=$(mktemp -d /tmp/fp-recovery.XXXXXX)
DIFF_FILE="$ARTIFACTS_DIR/pr-${PR_NUMBER}-diff.patch"
git fetch origin "$PR_BASE_REF" >/dev/null 2>&1
git diff "origin/${PR_BASE_REF}...${PR_HEAD_SHA}" > "$DIFF_FILE"
wc -l "$DIFF_FILE"
git diff "origin/${PR_BASE_REF}...${PR_HEAD_SHA}" --stat | tail -10
```

The diff file is the input to the manual reviewer dispatch. Carry `ARTIFACTS_DIR` through to Step 2 as the `WORKFLOW_PLUGIN_ARTIFACTS_DIR` value.

### Step 2: Dispatch `dso:code-reviewer-standard` at opus tier

Use the Agent tool with the named DSO sub-agent. Override the model to `opus` regardless of what the agent file's frontmatter defaults to — opus's stronger reasoning is the whole point of this escape valve.

Required dispatch shape:

```
Agent tool:
  subagent_type: "dso:code-reviewer-standard"
  model: "opus"
  description: "FP-recovery manual review of PR #<N>"
  prompt: |
    DIFF_FILE: <DIFF_FILE from Step 1>
    REPO_ROOT: <repo root>
    WORKFLOW_PLUGIN_ARTIFACTS_DIR: <ARTIFACTS_DIR from Step 1 — the mktemp-generated path>
    SELECTED_TIER: standard
    REVIEW_CONTEXT: ci

    === DIFF STAT ===
    <paste from Step 1>

    === ISSUE CONTEXT ===
    Manual FP-recovery dispatch. CI llm-review (ci.yml) reported a failing finding
    that appears to be a false positive: <one-sentence description of the suspected FP>.

    The CI finding's full text:
    <paste the CI llm-review finding verbatim>

    Apply the full standard-tier checklist. Verify every type / reachability claim
    by reading the actual code via Read/Grep. Pay particular attention to the
    Verify-Before-Assert and Caller-input verification gates.
```

This dispatches the real DSO reviewer agent (not a generic agent with the prompt inlined). The agent will:
- Read its own prompt file from `${CLAUDE_PLUGIN_ROOT}/agents/code-reviewer-standard.md` automatically (subagent_type resolves to it)
- Read the diff file
- Apply the standard-tier checklist + AI blindspot annotations + reachability/caller-input gates
- Write `reviewer-findings.json` to `WORKFLOW_PLUGIN_ARTIFACTS_DIR`
- Emit the 3-line `REVIEWER_HASH=… / FINDING_COUNT=N / FILES: …` shape

A real review should use multiple tool calls and take at least 30 seconds. If the dispatch returns in under 30 seconds or uses fewer than 5 tool calls, treat the result as invalid and re-dispatch with stricter verification instructions. Earlier thresholds (10 calls / 60s) over-fired on legitimately concise reviews — lowered after a focused review on a tightly-scoped diff hit 7 calls / 52s on its first dispatch and was incorrectly rejected, then produced the same verdict on the forced re-dispatch (21 calls / 84s) without changing the outcome.

### Step 3: Read the findings

```bash
cat "$ARTIFACTS_DIR/reviewer-findings.json"
```

The schema is documented in `${CLAUDE_PLUGIN_ROOT}/docs/contracts/review-findings-schema.md`. For this workflow, classify each finding:

- `severity: critical` — fix-required; do NOT force-merge
- `severity: important` — fix-required; do NOT force-merge
- `severity: fragile` — fix-required (treated as important for merge gating); do NOT force-merge
- `severity: minor` — informational; OK to force-merge
- `severity: suggestion` (if relation auto-downgraded) — informational; OK to force-merge

### Step 4: Verdict

**Clearance criteria** — ALL must hold:

1. Zero findings with severity `critical`.
2. Zero findings with severity `important`.
3. Zero findings with severity `fragile`.
4. The manual review dispatch used ≥5 tool calls and ≥30s of runtime (proxy: did the reviewer actually do the work). Earlier 10/60 thresholds over-fired on focused reviews.

If any criterion fails, do NOT force-merge. Either:
- Fix the underlying issue and push a new commit (CI re-reviews).
- File a bug describing the finding and the disagreement, then escalate to the maintainer.

If all four hold, you are **cleared to force-merge**.

### Step 5: Force-merge with explicit annotation

Use `gh pr merge --admin` (or whatever admin-override your project supports). The merge commit message MUST include the FP-recovery annotation:

```
Force-merged: manual dso:code-reviewer-standard at opus tier confirmed
  0 critical / 0 important / 0 fragile findings (N minor — informational).

CI llm-review finding classified as FP because: <one-sentence reason>.

Manual review artifact: <DIFF_FILE from Step 1>
Manual review hash: <REVIEWER_HASH from Step 2>
```

The annotation is **mandatory** — it makes the force-merge auditable. A retro-analyst should be able to:
- Find every FP-recovery force-merge via `git log --grep "Force-merged: manual dso:code-reviewer-standard"`
- Tie each one to a specific REVIEWER_HASH for the manual review's findings JSON
- See the engineer's stated FP rationale

### Step 6: Label the PR

Add the `force-merged-fp-recovery` label to the closed PR (or, if labels aren't set up in the project, post a PR comment with `FP_RECOVERY: pr_number=<N> manual_reviewer_hash=<hash> fp_rationale=<reason>`).

This is the data source for future FP-rate measurement once `side-pane-tithe` ships the telemetry substrate.

---

## What this workflow does NOT do

- **Does NOT lower the merge bar.** Every force-merge through this path still has a real DSO standard-tier review behind it — at opus tier with full reasoning, run by a human-initiated dispatch. The CI review is supplemented, not skipped.
- **Does NOT change CI config.** No edits to `required-checks.txt`, branch protection, or workflow files. The escape valve is procedural, not infrastructural.
- **Does NOT apply to test failures.** If `Hook Tests`, `Script Tests`, `actionlint`, etc. are failing, fix the failing tests. This workflow is review-specific.
- **Does NOT apply to intermittent CI failures.** If `Script Tests` is failing intermittently (bug `53f9-a218-8799-49be`), the path is to re-push or wait for re-run, not to force-merge.
- **Does NOT apply to OVER_BOUND PRs.** If the PR's CI output contains an `OVER_BOUND:` marker, the LLM reviewer never ran — there is no finding to adjudicate as an FP. Step 0 rejects these PRs early. The correct path for OVER_BOUND PRs is admin review or PR splitting.

---

## Future deprecation

This workflow is a **temporary escape valve** intended to bridge the gap until:

1. `swap-maple-flyby` (cycle-end arbiter) ships and stops oscillation/FP-amplification at the source.
2. `side-pane-tithe` ships and provides quantitative FP-rate measurement.
3. Proposed §C–§E reviewer-prompt improvements (vocabulary grounding, SC/DD context injection, calibrated confidence) reduce the per-review FP rate.

When the FP rate drops below ~10% on rolling-30-day measurement, this workflow can be retired or restricted to security-overlay-only escalation.

---

## Trigger phrases (for `/dso:fp-recovery` skill)

- "force merge this PR"
- "the CI review is wrong"
- "false positive from llm-review"
- "manual review override"
- "FP recovery"
