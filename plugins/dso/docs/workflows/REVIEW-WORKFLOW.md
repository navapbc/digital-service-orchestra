# Code Review Workflow

Review the current code diff using a classifier-selected named review agent for analysis of bugs, logic errors, security vulnerabilities, code quality, and adherence to project conventions.

## Config Reference (from dso-config.conf)

Replace commands below with values from your `.claude/dso-config.conf`:

- `commands.format` (default: `make format`)
- `commands.lint` (default: the project's configured lint command)
- `commands.type_check` (default: the project's configured type-check command)
- `commands.test_unit` (default: `make test-unit-only`)
- `review.max_resolution_attempts` (default: `5`) — max autonomous fix/defend attempts before escalating to user

The artifacts directory is computed by `get_artifacts_dir()` in `hooks/lib/deps.sh` and resolves to `/tmp/workflow-plugin-<hash-of-REPO_ROOT>/`.

---

**CRITICAL**: Steps 0-5 are mandatory and sequential. Step 0 clears stale artifacts — always start here, even when restarting. Step 1 runs auto-fixers (format/lint/type-check) BEFORE Step 2 captures the diff hash — this ordering prevents pre-commit hooks from invalidating the hash. You MUST dispatch the code-reviewer sub-agent in Step 4. Skipping the sub-agent and recording review JSON directly is fabrication — it violates CLAUDE.md rule #15 regardless of how "simple" the changes appear.

**This workflow reviews CODE (diffs, commits). To review a PLAN or DESIGN, use `/dso:plan-review` instead.** See CLAUDE.md "Always Do These" rule 10 for the review routing table.

---

## Step 0: Clear Stale Review Artifacts

**Always run this step first.** Clear any leftover review state from prior sessions or earlier review passes. This ensures the current review computes a fresh diff hash and does not accidentally reuse a stale `review-status` that would let a commit bypass the review gate.

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
# Resolve CLAUDE_PLUGIN_ROOT if not set by the caller (e.g., manual run outside Claude Code)
if [[ -z "${CLAUDE_PLUGIN_ROOT:-}" ]]; then
    _cfg="$REPO_ROOT/.claude/dso-config.conf"
    if [[ -f "$_cfg" ]]; then
        CLAUDE_PLUGIN_ROOT="$(grep '^dso\.plugin_root=' "$_cfg" 2>/dev/null | cut -d= -f2-)"
    fi
    # Final fallback: resolve via the shim (handles plugin-cache installs and sentinel detection)
    if [[ -z "${CLAUDE_PLUGIN_ROOT:-}" ]]; then
        CLAUDE_PLUGIN_ROOT="$(. "$REPO_ROOT/.claude/scripts/dso" --lib && echo "$DSO_ROOT")"
    fi
fi
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/deps.sh"
ARTIFACTS_DIR=$(get_artifacts_dir)
mkdir -p "$ARTIFACTS_DIR"
rm -f "$ARTIFACTS_DIR/review-status"
rm -f "$ARTIFACTS_DIR"/review-diff-*.txt
rm -f "$ARTIFACTS_DIR"/review-stat-*.txt
```

If restarting the review workflow after a failed attempt, this step guarantees a clean slate.

## Step 1: Pre-commit Auto-fix Pass (format/lint/type-check before hash capture)

**Why this step exists**: Pre-commit hooks run format, lint, and type-check on commit. If the diff hash is captured before these auto-fixers run, any file modifications they make will invalidate the hash, forcing a re-review. Running the same checks here — before hash capture — ensures the hash reflects the final post-auto-fix state.

**Skip check**: If a validation state file exists and is fresh (< 60 seconds old), skip Step 1 and go directly to Step 2:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/deps.sh"  # or: ${CLAUDE_PLUGIN_ROOT}/hooks/lib/deps.sh
ARTIFACTS_DIR=$(get_artifacts_dir)
mkdir -p "$ARTIFACTS_DIR"
VALIDATION_STATUS="$ARTIFACTS_DIR/validation-status"
if [ -f "$VALIDATION_STATUS" ]; then
    status_content=$(head -n 1 "$VALIDATION_STATUS")
    if [ "$(uname)" = "Darwin" ]; then
        status_age=$(( $(date +%s) - $(stat -f %m "$VALIDATION_STATUS" 2>/dev/null || echo 0) ))
    else
        status_age=$(( $(date +%s) - $(stat -c %Y "$VALIDATION_STATUS" 2>/dev/null || echo 0) ))
    fi
    if [ "$status_content" = "passed" ] && [ "$status_age" -lt 60 ]; then
        # Validation is fresh — skip to Step 2
    fi
fi
```

If the file is missing, stale (>60s), or shows "failed", execute Step 1 as normal:

Run these checks in order. They mirror the pre-commit hook suite so the diff hash is stable through commit.

1. **Format**: `cd app && make format` — run first so lint/type checks see the final formatted state.
   - After format, check if any files were changed: `git diff --name-only`
   - If format changed files, **re-stage them**: `git add -u`
   - This keeps the staged diff in sync with the formatted state.
2. **Lint check**: `cd app && $commands.lint 2>&1 | tail -3` (on success, only summary needed; re-run with full output on failure)
3. **Type check**: `cd app && $commands.type_check 2>&1 | tail -5` (on success, only summary needed; re-run with full output on failure)
4. **Unit tests**: `cd app && make test-unit-only 2>&1 | tail -5` (on success, only summary needed; re-run with full output on failure)

If Docker is not available, use `python3 -m py_compile` on changed Python files as a lint fallback.

**If any check fails:**
- Do NOT proceed with the code review
- Fix the issue and restart from Step 0

## Step 2: Capture Diff Hash (after auto-fixers have run)

The diff hash is captured here — AFTER Step 1's format/lint/type-check pass — so it reflects the final post-auto-fix state. This prevents pre-commit hooks from invalidating the hash at commit time.

1. **Capture the diff hash**:
   ```bash
   DIFF_HASH=$("$REPO_ROOT/.claude/scripts/dso" compute-diff-hash.sh)
   DIFF_HASH_SHORT="${DIFF_HASH:0:8}"
   ```

2. **Capture the diff to a hash-stamped file** (not inline in context):
   ```bash
   DIFF_FILE="$ARTIFACTS_DIR/review-diff-${DIFF_HASH_SHORT}.txt"
   STAT_FILE="$ARTIFACTS_DIR/review-stat-${DIFF_HASH_SHORT}.txt"
   "$REPO_ROOT/.claude/scripts/dso" capture-review-diff.sh "$DIFF_FILE" "$STAT_FILE"
   ```

3. **Read only the stat file** into context (small). Do NOT cat/read the full diff file — the sub-agent reads it from disk.

4. Store `DIFF_HASH`, `DIFF_FILE`, and `STAT_FILE` paths for use in Steps 2-5.

**Note**: The diff hash is staging-invariant for tracked file changes — `git add -u` produces the same hash as the pre-add state.

### Step 2b: Huge-Diff File-Count Gate

Run the file-count threshold check against the current staging state (`git diff --name-only HEAD`), which reflects the same working tree used by Step 2's diff hash:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
".claude/scripts/dso" review-huge-diff-check.sh
HUGE_EXIT=$?
```

- **Exit 0**: file count is below threshold → proceed to Step 3 (standard path)
- **Exit 2**: file count meets or exceeds `review.huge_diff_file_threshold` → divert:
  Follow REVIEW-WORKFLOW-HUGE.md and return; do not continue to Step 3
- **Exit 1**: configuration error (invalid threshold) → surface error to user; do not proceed

## Step 3: Classify Review Tier (MANDATORY — run the classifier, do not evaluate mentally)

**You MUST run this command and use its output.** Do NOT select a tier based on your assessment of diff complexity or file types — the classifier computes the tier deterministically from the diff.

```bash
# Run complexity classifier to determine review tier
CLASSIFIER_OUTPUT=$("$REPO_ROOT/.claude/scripts/dso" review-complexity-classifier.sh < "$DIFF_FILE" 2>/dev/null) || CLASSIFIER_EXIT=$?
if [[ "${CLASSIFIER_EXIT:-0}" -ne 0 ]] || ! echo "$CLASSIFIER_OUTPUT" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
    # Classifier failed — default to standard tier per contract (classifier-tier-output.md)
    REVIEW_TIER="standard"
    REVIEW_AGENT="dso:code-reviewer-standard"
else
    REVIEW_TIER=$(echo "$CLASSIFIER_OUTPUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["selected_tier"])')
    case "$REVIEW_TIER" in
        light)    REVIEW_AGENT="dso:code-reviewer-light" ;;
        standard) REVIEW_AGENT="dso:code-reviewer-standard" ;;
        deep)     REVIEW_AGENT="deep-multi-reviewer" ;;  # Dispatches 3 parallel sonnet agents — see Step 4 Deep Tier section
        *)        REVIEW_TIER="standard"; REVIEW_AGENT="dso:code-reviewer-standard" ;;
    esac
fi
echo "REVIEW_TIER=$REVIEW_TIER REVIEW_AGENT=$REVIEW_AGENT"
```

**Classifier failure invariant**: When the classifier exits non-zero or produces invalid JSON, `REVIEW_TIER` MUST be `standard` and `REVIEW_AGENT` MUST be `dso:code-reviewer-standard`. Do not downgrade to light tier. Do not rationalize that a small diff warrants a lighter review — a classifier failure means the diff could not be scored, not that it is simple. This invariant is mandatory regardless of perceived diff size, file types, or change scope.

**Merge-commit floor**: When `is_merge_commit` is `true` in the classifier output and `selected_tier` is `light`, treat the tier as `standard`. Merge commits consolidate work across branches; the light checklist (single-pass, haiku) cannot reliably analyze cross-branch integration risks. The classifier enforces this floor internally, but if you encounter a merge with `selected_tier: light` in the output (e.g., from a cached classifier version), apply this upgrade before dispatching.

### Step 3b: Size-Based Branching (post-classifier)

After tier selection, extract size fields from the classifier output and apply size-based routing. The `size_action` field determines whether the review proceeds normally, upgrades to opus, or emits a size warning. See `docs/contracts/classifier-size-output.md` for the full contract.

```bash
# Extract size fields from classifier output (defaults match failure contract)
SIZE_ACTION=$(echo "$CLASSIFIER_OUTPUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("size_action","none"))' 2>/dev/null || echo "none")
IS_MERGE=$(echo "$CLASSIFIER_OUTPUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(str(d.get("is_merge_commit",False)).lower())' 2>/dev/null || echo "false")
DIFF_SIZE_LINES=$(echo "$CLASSIFIER_OUTPUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("diff_size_lines",0))' 2>/dev/null || echo "0")

# REVIEW_PASS_NUM tracks initial vs re-review passes.
# Pass 1 = initial review dispatch; pass >= 2 = re-review from Autonomous Resolution Loop.
# Size limits apply ONLY to pass 1. The Autonomous Resolution Loop caller must set
# REVIEW_PASS_NUM before invoking this workflow for re-review passes.
REVIEW_PASS_NUM="${REVIEW_PASS_NUM:-1}"
# TIER LOCK: REVIEW_TIER is set once (above) and carried into all re-review passes.
# The classifier MUST NOT be re-run for re-review passes (REVIEW_PASS_NUM >= 2).
# Re-review passes use the REVIEW_TIER/REVIEW_AGENT from the initial Step 3 classification.

# Merge commits bypass size limits entirely (contract: is_merge_commit always checked first)
# re-review passes (REVIEW_PASS_NUM >= 2) bypass size limits (re-review exemption rule)
if [[ "$IS_MERGE" != "true" ]] && [[ "$REVIEW_PASS_NUM" -le 1 ]]; then
    # Size action branching (initial review, non-merge only)
    if [[ "$SIZE_ACTION" == "upgrade" ]]; then
        # Upgrade: size_action=upgrade triggers a model_override — use opus reviewer
        REVIEW_AGENT_OVERRIDE="dso:code-reviewer-deep-arch"  # model_override: opus
        # WARNING: deep-arch requires sonnet findings — Step 4 MUST use the full
        # Deep Tier dispatch (3 parallel sonnet agents → opus synthesis), NOT
        # a direct dispatch of deep-arch alone. See Step 4 Deep Tier section.
        echo "SIZE_UPGRADE: diff has ${DIFF_SIZE_LINES} scorable lines — upgrading to opus reviewer at ${REVIEW_TIER} tier scope"
    fi

    if [[ "$SIZE_ACTION" == "warn" ]]; then
        echo "SIZE_WARNING: ${DIFF_SIZE_LINES} scorable lines (≥600 threshold) — proceeding with review"
    fi
fi
```

Use the `REVIEW_TIER` and `REVIEW_AGENT` values in Step 4. When `REVIEW_AGENT_OVERRIDE` is set (size upgrade case), Step 4 dispatch uses `REVIEW_AGENT_OVERRIDE` instead of `REVIEW_AGENT`. Do not override the classifier's tier selection.

**TIER IMMUTABILITY**: Once `REVIEW_TIER` is set by the classifier output in Step 3, it is immutable for the lifetime of this review pass. You MUST NOT re-run the classifier, select a different tier, or interpret the re-review escalation table (REVIEW_PASS_NUM) as permission to move to a lighter tier. The re-review escalation table governs upward escalation only. Any rationalization for downgrading — including "stale diff," "false positives," "user preference context," or "sprint batch context" — is prohibited. Tier direction is one-way: light → standard → deep. Never standard → light or deep → standard.

**Deep tier + upgrade — no rationalization exemptions**: When `REVIEW_TIER=deep` and `SIZE_ACTION=upgrade`, you MUST dispatch the full deep tier (3 parallel sonnet agents + opus arch synthesis) with the opus model override. Do not substitute a lighter tier, a standard-tier agent, or a general-purpose agent due to perceived overhead, time constraints, or commit urgency. The deep tier exists precisely for high-blast-radius changes — "overhead" objections do not override the classifier.

## Step 4: Dispatch Code Review Sub-Agent (MANDATORY)

**You MUST launch a named `dso:code-reviewer-*` sub-agent.** There are no exceptions — not for documentation-only changes, not for "trivial" changes, not for config files. The sub-agent performs the review and assigns scores. Skipping this step and writing review JSON yourself is fabrication. Dispatching a generic agent with instructions to write `reviewer-findings.json` is also fabrication — the review MUST come from a named reviewer agent (`dso:code-reviewer-light`, `dso:code-reviewer-standard`, or `dso:code-reviewer-deep-*`), not a general-purpose agent with fabricated review instructions.

**Inline dispatch is mandatory — `dso:*` labels are agent file identifiers, NOT `subagent_type` values.** The Agent tool only accepts built-in types (`general-purpose`, `Explore`, `Plan`, etc.). For every dispatch below:
1. Read `agents/<agent-name>.md` inline (strip the `dso:` prefix to get the file name).
2. Use `subagent_type: "general-purpose"` and the `model:` value from the agent file's frontmatter.
3. Pass the agent file content verbatim as the prompt, appending only the per-review context items listed below.

**HARD GATE — VERBATIM IS NOT OPTIONAL**: This verbatim requirement applies to EVERY dispatch in this workflow — initial review, re-review, escalation. There are no exceptions. Constructing your own prompt instead of loading the agent file is fabrication, regardless of which step you are in or how "simple" the re-review context appears. Do NOT proceed with a dispatch until you have read the agent file and confirmed its content is the first thing in the prompt.

```bash
# Example: resolve agent file path and model for DISPATCH_AGENT="dso:code-reviewer-standard"
AGENT_NAME="${DISPATCH_AGENT#dso:}"          # strip dso: prefix → "code-reviewer-standard"
AGENT_FILE="${CLAUDE_PLUGIN_ROOT}/agents/${AGENT_NAME}.md"
AGENT_CONTENT=$(cat "$AGENT_FILE")
AGENT_MODEL=$(grep '^model:' "$AGENT_FILE" | awk '{print $2}')  # e.g. "sonnet"
```

**Do not substitute your own prompt structure** for the named agent's file content — constructing a custom prompt bypasses the scoring rules and output contract that the review gate validates. The agent file content must be present verbatim.

### Tier-to-Agent Dispatch

| `REVIEW_TIER` | `REVIEW_AGENT` | Model |
|---|---|---|
| `light` | `dso:code-reviewer-light` | haiku |
| `standard` | `dso:code-reviewer-standard` | sonnet |
| `deep` | 3 parallel sonnet agents (see Deep Tier below) | sonnet |

**Model is non-negotiable**: The `model:` field in each named agent's definition is authoritative. Do NOT override it at dispatch time (e.g., dispatching `dso:code-reviewer-light` with `model: sonnet`). If Sonnet capability is needed, the correct action is to increase the tier — re-run the classifier or manually escalate to `dso:code-reviewer-standard`. Pairing a lighter checklist with a heavier model defeats the tier system without improving review quality.

### Per-Review Context (prompt content)

Pass only these items in the sub-agent prompt — the named agent's system prompt handles the review procedure:

- `DIFF_FILE`: the `DIFF_FILE` path from Step 2 (the sub-agent reads the diff from disk)
- `STAT_FILE` content: the stat summary from Step 2 (inline in the prompt)
- `REPO_ROOT`: repository root path
- `{issue_context}`: Issue context (see below)

**Resolving `{issue_context}`**: If a ticket issue ID is known for the current work (e.g., passed from `/dso:sprint`, present in the task prompt, or tracked by the orchestrator), populate this with:

```
=== ISSUE CONTEXT ===
This change is for issue {issue_id}.
To view full issue details, run: .claude/scripts/dso ticket show {issue_id}
```

If no issue is associated with the current work, omit the issue context section.

### Dispatch (Light / Standard Tiers)

**VERBATIM REQUIRED** — you MUST read the agent file and pass its content as the first element of the prompt. Do NOT write a constructed prompt (e.g., "Review the code changes for correctness and security.") — that is fabrication and violates CLAUDE.md rule 8. This applies in every session state, including post-compaction and long-running sessions. If you have not yet executed the bash block below to read the agent file, STOP and do it now before filling in the `prompt:` field.

For `light` and `standard` tiers, dispatch a single named review agent. When `REVIEW_AGENT_OVERRIDE` is set (from the size upgrade path in Step 3b), use `REVIEW_AGENT_OVERRIDE` instead of `REVIEW_AGENT` — this ensures the opus upgrade takes effect at the current tier's scope:

```bash
# Resolve the dispatch agent — REVIEW_AGENT_OVERRIDE takes precedence when set
DISPATCH_AGENT="${REVIEW_AGENT_OVERRIDE:-$REVIEW_AGENT}"
```

```bash
# Resolve agent file and model from DISPATCH_AGENT (e.g., "dso:code-reviewer-standard")
AGENT_NAME="${DISPATCH_AGENT#dso:}"
AGENT_FILE="${CLAUDE_PLUGIN_ROOT}/agents/${AGENT_NAME}.md"
AGENT_CONTENT=$(cat "$AGENT_FILE")
AGENT_MODEL=$(grep '^model:' "$AGENT_FILE" | awk '{print $2}')
```

```
Agent tool:
  subagent_type: "general-purpose"
  model: "{AGENT_MODEL from agent file frontmatter — e.g. haiku, sonnet, opus}"
  description: "Review code changes"
  prompt: |
    {AGENT_CONTENT — verbatim content of ${CLAUDE_PLUGIN_ROOT}/agents/{AGENT_NAME}.md}

    DIFF_FILE: {DIFF_FILE from Step 2}
    REPO_ROOT: {REPO_ROOT}
    WORKFLOW_PLUGIN_ARTIFACTS_DIR: {ARTIFACTS_DIR}
    SELECTED_TIER: {REVIEW_TIER from Step 3 classifier — pass this so the reviewer can embed it in reviewer-findings.json via --selected-tier}

    === DIFF STAT ===
    {content of STAT_FILE from Step 2}

    {issue_context}
```

**NEVER set `isolation: "worktree"` on this sub-agent.** The reviewer must read `reviewer-findings.json` and run `write-reviewer-findings.sh` in the same working directory as the orchestrator. Worktree isolation gives the agent a separate branch where those files are not present, causing the review to fail.

**Per-worktree context note**: When dispatching from `per-worktree-review-commit.md`, the orchestrator runs all CWD-sensitive steps (0–3 and post-review Step 5) as its own Bash calls prefixed with `cd $WORKTREE_PATH &&`. Only the code analysis sub-agent (Step 4) is dispatched via the Agent tool. Since sub-agents always start in the orchestrator's primary CWD (not the worktree), the orchestrator passes `WORKFLOW_PLUGIN_ARTIFACTS_DIR=<worktree-artifacts-path>` in the sub-agent prompt so `write-reviewer-findings.sh` writes to the correct artifacts directory. The diff file is an absolute path with no CWD dependency.

### Deep Tier: 3 Parallel Sonnet Dispatch

When `REVIEW_TIER` is `deep`, dispatch 3 parallel sonnet sub-agents in a single message. Each agent focuses on a different review dimension. All three receive the same `DIFF_FILE`, `REPO_ROOT`, and `STAT_FILE` — no issue-context sharing is needed between them.

| Slot | Named Agent | Temp Findings File |
|------|-------------|-------------------|
| a | `dso:code-reviewer-deep-correctness` | `$ARTIFACTS_DIR/reviewer-findings-a.json` |
| b | `dso:code-reviewer-deep-verification` | `$ARTIFACTS_DIR/reviewer-findings-b.json` |
| c | `dso:code-reviewer-deep-hygiene` | `$ARTIFACTS_DIR/reviewer-findings-c.json` |

**SERIAL DISPATCH PROHIBITED**: All 3 sonnet agents MUST be launched in a single response as 3 parallel Agent tool calls. Dispatching them one at a time (serial) triples review time and is a critical workflow violation. A single response must contain all three Agent tool invocations with no waiting between them.

**VERBATIM REQUIRED** — read all three agent files inline before dispatching. Do NOT construct your own review instructions in any of the three prompt fields. Each prompt MUST begin with the verbatim agent file content.

Read the three agent files inline and dispatch all three in one message:

```bash
# Read all three agent files before dispatching
AGENT_A_CONTENT=$(cat "${CLAUDE_PLUGIN_ROOT}/agents/code-reviewer-deep-correctness.md")
AGENT_B_CONTENT=$(cat "${CLAUDE_PLUGIN_ROOT}/agents/code-reviewer-deep-verification.md")
AGENT_C_CONTENT=$(cat "${CLAUDE_PLUGIN_ROOT}/agents/code-reviewer-deep-hygiene.md")
# All three use model: sonnet (from agent file frontmatter)
```

Dispatch all three in a single message (parallel launch). Each agent writes directly to its slot-specific findings path — pass `FINDINGS_OUTPUT` in the prompt so the agent writes to the correct file via `write-reviewer-findings.sh --output`:

```
Agent tool [ALL THREE IN ONE RESPONSE — PARALLEL]:

Agent tool:
  subagent_type: "general-purpose"
  model: "sonnet"
  description: "Deep review: correctness"
  prompt: |
    {AGENT_A_CONTENT — verbatim content of ${CLAUDE_PLUGIN_ROOT}/agents/code-reviewer-deep-correctness.md}

    DIFF_FILE: {DIFF_FILE from Step 2}
    REPO_ROOT: {REPO_ROOT}
    WORKFLOW_PLUGIN_ARTIFACTS_DIR: {ARTIFACTS_DIR}
    SELECTED_TIER: {REVIEW_TIER from Step 3 classifier — pass this so the reviewer can embed it in reviewer-findings.json via --selected-tier}
    FINDINGS_OUTPUT: $ARTIFACTS_DIR/reviewer-findings-a.json

    === DIFF STAT ===
    {content of STAT_FILE from Step 2}

    {issue_context}

Agent tool:
  subagent_type: "general-purpose"
  model: "sonnet"
  description: "Deep review: verification"
  prompt: |
    {AGENT_B_CONTENT — verbatim content of ${CLAUDE_PLUGIN_ROOT}/agents/code-reviewer-deep-verification.md}

    DIFF_FILE: {DIFF_FILE from Step 2}
    REPO_ROOT: {REPO_ROOT}
    WORKFLOW_PLUGIN_ARTIFACTS_DIR: {ARTIFACTS_DIR}
    SELECTED_TIER: {REVIEW_TIER from Step 3 classifier — pass this so the reviewer can embed it in reviewer-findings.json via --selected-tier}
    FINDINGS_OUTPUT: $ARTIFACTS_DIR/reviewer-findings-b.json

    === DIFF STAT ===
    {content of STAT_FILE from Step 2}

    {issue_context}

Agent tool:
  subagent_type: "general-purpose"
  model: "sonnet"
  description: "Deep review: hygiene"
  prompt: |
    {AGENT_C_CONTENT — verbatim content of ${CLAUDE_PLUGIN_ROOT}/agents/code-reviewer-deep-hygiene.md}

    DIFF_FILE: {DIFF_FILE from Step 2}
    REPO_ROOT: {REPO_ROOT}
    WORKFLOW_PLUGIN_ARTIFACTS_DIR: {ARTIFACTS_DIR}
    SELECTED_TIER: {REVIEW_TIER from Step 3 classifier — pass this so the reviewer can embed it in reviewer-findings.json via --selected-tier}
    FINDINGS_OUTPUT: $ARTIFACTS_DIR/reviewer-findings-c.json

    === DIFF STAT ===
    {content of STAT_FILE from Step 2}

    {issue_context}
```

**No post-return copy step is needed** — each agent writes directly to its unique slot path, eliminating the parallel write race condition. The opus arch reviewer consumes all three slot files (`reviewer-findings-a.json`, `reviewer-findings-b.json`, `reviewer-findings-c.json`) after all sonnet agents complete.

### Deep Tier: Opus Architectural Review (after 3 parallel sonnet agents complete)

After all 3 parallel sonnet agents complete and their temp findings files are saved, dispatch the opus architectural reviewer `dso:code-reviewer-deep-arch`. This agent runs sequentially after the sonnet agents, not in parallel — it synthesizes their specialist findings into the authoritative final reviewer-findings.json.

**Single-writer invariant**: Only the arch reviewer (opus) writes the final authoritative `reviewer-findings.json` for deep tier reviews. The sonnet agents write only to their temp slot paths (`reviewer-findings-{a,b,c}.json`). This single-writer invariant ensures the final findings file is a coherent synthesis, not a race-condition artifact.

**Step 1: Read findings from each sonnet temp file:**

```bash
FINDINGS_A=$(python3 -c "import json; d=json.load(open('$ARTIFACTS_DIR/reviewer-findings-a.json')); print(json.dumps(d['findings']))")
FINDINGS_B=$(python3 -c "import json; d=json.load(open('$ARTIFACTS_DIR/reviewer-findings-b.json')); print(json.dumps(d['findings']))")
FINDINGS_C=$(python3 -c "import json; d=json.load(open('$ARTIFACTS_DIR/reviewer-findings-c.json')); print(json.dumps(d['findings']))")
```

**Step 2: Dispatch `dso:code-reviewer-deep-arch` (model: opus) with inline sonnet findings:**

**VERBATIM REQUIRED** — read the arch agent file inline before dispatching. Do NOT construct your own synthesis prompt — that is fabrication.

Read the arch agent file inline before dispatching:

```bash
AGENT_ARCH_CONTENT=$(cat "${CLAUDE_PLUGIN_ROOT}/agents/code-reviewer-deep-arch.md")
# model: opus (from agent file frontmatter)
```

```
Agent tool:
  subagent_type: "general-purpose"
  model: "opus"
  description: "Deep architectural review (opus) — synthesize sonnet findings"
  prompt: |
    {AGENT_ARCH_CONTENT — verbatim content of ${CLAUDE_PLUGIN_ROOT}/agents/code-reviewer-deep-arch.md}

    DIFF_FILE: {DIFF_FILE from Step 2}
    REPO_ROOT: {REPO_ROOT}
    WORKFLOW_PLUGIN_ARTIFACTS_DIR: {ARTIFACTS_DIR}
    SELECTED_TIER: {REVIEW_TIER from Step 3 classifier — pass this so the reviewer can embed it in reviewer-findings.json via --selected-tier}

    === DIFF STAT ===
    {content of STAT_FILE from Step 2}

    {issue_context}

    === SONNET-A FINDINGS (correctness) ===
    {FINDINGS_A}
    === SONNET-B FINDINGS (verification) ===
    {FINDINGS_B}
    === SONNET-C FINDINGS (hygiene/design) ===
    {FINDINGS_C}
```

**Step 3: The deep-arch agent writes the final authoritative `reviewer-findings.json`** — this is the sole writer of the final findings file for deep tier. Extract `REVIEWER_HASH` from the arch agent's output for use in Step 5.

**Step 4: Pass `REVIEWER_HASH` from the opus arch agent output to `record-review.sh` in Step 5** — not the REVIEWER_HASH from any of the sonnet agents.

**Retry on malformed output:** If the sub-agent does not return the fixed format (`REVIEW_RESULT:`, `REVIEWER_HASH=`, etc.) or does not include `REVIEWER_HASH=`, re-dispatch with a correction prompt. Never fabricate scores.

**NO-FIX RULE**: After dispatching the sub-agent in this step, you (the orchestrator) MUST NOT use Edit, Write, or Bash to modify any files until Step 5 is complete. Any file modification between dispatch and recording invalidates the diff hash and will be rejected by `--expected-hash`.

## Step 4a: ESCALATE_REVIEW Dispatch (after reviewer return, before overlay)

After Step 4 returns and before Step 4b overlay dispatch, check whether the reviewer requested escalation to a higher tier. Escalation may change finding severities, which affects whether overlays are warranted — this is why it runs before Step 4b.

### 1. Parse escalate_review from reviewer-findings.json

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/deps.sh"
ARTIFACTS_DIR=$(get_artifacts_dir)
FINDINGS_FILE="$ARTIFACTS_DIR/reviewer-findings.json"

ESCALATE_REVIEW=$(python3 -c "
import json, sys
try:
    d = json.load(open('$FINDINGS_FILE'))
    v = d.get('escalate_review')
    if v is None or not isinstance(v, list) or len(v) == 0:
        print('none')
    else:
        # Validate each element: finding_index (int) + reason (non-empty string)
        findings = d.get('findings', [])
        valid = []
        for e in v:
            fi = e.get('finding_index')
            reason = e.get('reason', '')
            if isinstance(fi, int) and 0 <= fi < len(findings) and isinstance(reason, str) and reason.strip():
                valid.append(e)
            else:
                print('WARN: malformed escalate_review element skipped: ' + str(e), file=sys.stderr)
        print('none' if not valid else json.dumps(valid))
except Exception as ex:
    print('WARN: could not parse escalate_review: ' + str(ex), file=sys.stderr)
    print('none')
" 2>&1 | (grep -v '^WARN:' || true) | tail -1)
# Capture any warnings to stderr so they are visible in debug output but do not block the workflow
python3 -c "
import json, sys
try:
    d = json.load(open('$FINDINGS_FILE'))
    v = d.get('escalate_review')
    if v is None or not isinstance(v, list) or len(v) == 0:
        pass
    else:
        findings = d.get('findings', [])
        for e in v:
            fi = e.get('finding_index')
            reason = e.get('reason', '')
            if not (isinstance(fi, int) and 0 <= fi < len(findings) and isinstance(reason, str) and reason.strip()):
                print('WARN: malformed escalate_review element (skipped): ' + str(e), file=sys.stderr)
except Exception as ex:
    print('WARN: could not parse escalate_review from reviewer-findings.json: ' + str(ex), file=sys.stderr)
" 2>&1 >&2 || true
```

Contract reference: `docs/contracts/escalate-review-signal.md` — defines the `escalate_review` field schema, validity rules, and fail-open failure contract.

**Failure contract**: If `escalate_review` is `null`, malformed JSON, or contains invalid elements (empty `reason`, out-of-bounds `finding_index`), treat the entire field as absent (no escalation). Log a warning to stderr. Do NOT halt or block the review workflow.

### 2. Skip if absent or empty

If `ESCALATE_REVIEW` is `"none"` (field absent, empty array, or all elements invalid), skip Steps 4a.3–4a.5 and proceed directly to Step 4b.

### 3. Determine escalation tier

**OPUS GUARD**: If the current reviewer tier is opus (i.e., `REVIEW_TIER=deep` after opus arch synthesis, or the single reviewer was `dso:code-reviewer-deep-arch`), log the following and skip escalation entirely:

```
Opus reviewer emitted ESCALATE_REVIEW — ignoring (opus is terminal tier)
```

Opus is the highest available tier. There is no higher tier to escalate to. Proceed to Step 4b.

Otherwise, apply the tier mapping to determine the escalation reviewer:

| Current tier / reviewer | Escalation reviewer |
|---|---|
| `light` (`dso:code-reviewer-light`, haiku) | `dso:code-reviewer-standard` (sonnet) |
| `standard` (`dso:code-reviewer-standard`, sonnet) | `dso:code-reviewer-deep-arch` (opus) — dispatched as a single opus reviewer with focused context |

```bash
case "$REVIEW_TIER" in
    light)
        ESCALATION_AGENT="dso:code-reviewer-standard"
        # Ratchet: record that this session has escalated to standard tier
        RATCHETED_TIER='standard'
        ;;
    standard)
        ESCALATION_AGENT="dso:code-reviewer-deep-arch"
        # Ratchet: record that this session has escalated to deep tier
        RATCHETED_TIER='deep'
        ;;
    deep)
        # Covered by OPUS GUARD above — skip escalation
        ESCALATION_AGENT=""
        ;;
    *)
        echo "WARN: unknown REVIEW_TIER '$REVIEW_TIER' for escalation — skipping"
        ESCALATION_AGENT=""
        ;;
esac
```

### 4. Dispatch escalation reviewer with focused context

Extract only the uncertain findings (those referenced by `finding_index` in `escalate_review`) and dispatch the escalation reviewer with focused context:

```bash
# Build focused findings subset for the escalation reviewer
UNCERTAIN_FINDINGS=$(python3 -c "
import json
findings_file = '$FINDINGS_FILE'
d = json.load(open(findings_file))
all_findings = d.get('findings', [])
escalate = json.loads('$ESCALATE_REVIEW')
uncertain_indices = {e['finding_index'] for e in escalate}
focused = [f for i, f in enumerate(all_findings) if i in uncertain_indices]
reasons = {e['finding_index']: e['reason'] for e in escalate}
print(json.dumps({'findings': focused, 'escalation_reasons': reasons}))
")
```

Dispatch the escalation reviewer sub-agent with this focused context. **VERBATIM REQUIRED** — you MUST read the agent file and pass its content as the first element of the prompt, exactly as Step 4 initial dispatch does. Do NOT write a constructed prompt — that is fabrication.

```bash
# Read the escalation agent file verbatim — MANDATORY before dispatch
ESCALATION_AGENT_NAME="${ESCALATION_AGENT#dso:}"
ESCALATION_AGENT_FILE="${CLAUDE_PLUGIN_ROOT}/agents/${ESCALATION_AGENT_NAME}.md"
ESCALATION_AGENT_CONTENT=$(cat "$ESCALATION_AGENT_FILE")
ESCALATION_AGENT_MODEL=$(grep '^model:' "$ESCALATION_AGENT_FILE" | awk '{print $2}')
```

```
Agent tool:
  subagent_type: "general-purpose"
  model: "{ESCALATION_AGENT_MODEL from agent file frontmatter}"
  description: "Escalated review — uncertain findings"
  prompt: |
    {ESCALATION_AGENT_CONTENT — verbatim content of ${CLAUDE_PLUGIN_ROOT}/agents/{ESCALATION_AGENT_NAME}.md}

    DIFF_FILE: {DIFF_FILE from Step 2}
    REPO_ROOT: {REPO_ROOT}

    === DIFF STAT ===
    {content of STAT_FILE from Step 2}

    === UNCERTAIN FINDINGS (subset requiring escalation) ===
    {UNCERTAIN_FINDINGS}

    === ESCALATION CONTEXT ===
    These findings were flagged for escalation by the primary reviewer. For each finding, the
    primary reviewer's reason for requesting escalation is included in escalation_reasons (keyed
    by finding index). Your severity determination for each finding replaces the primary reviewer's
    uncertain severity in the final merged findings.

    {issue_context}
```

**NEVER set `isolation: "worktree"` on this sub-agent.** It must access `reviewer-findings.json` in the shared working directory.

### 5. Merge escalated severity determinations

After the escalation reviewer returns, replace the severity of each uncertain finding in `reviewer-findings.json` with the escalated reviewer's determinations:

```bash
# Escalated severity determinations replace original uncertain finding severities
python3 -c "
import json
findings_file = '$FINDINGS_FILE'
d = json.load(open(findings_file))
findings = d.get('findings', [])
escalate = json.loads('$ESCALATE_REVIEW')
# Parse escalation reviewer output for updated severities
# (escalation reviewer returns findings in standard format — severity field per finding)
# escalated_findings: list of findings from the escalation reviewer, in index order matching uncertain_indices
uncertain_indices = sorted({e['finding_index'] for e in escalate})
# Replace severities in original findings
# (The escalation reviewer returns findings with updated severity — apply by position)
# NOTE: escalation reviewer findings are expected to correspond 1:1 to the uncertain_indices list
# If the escalation reviewer returns fewer findings, the remainder keep original severities
# Implementation note: the orchestrator reads the escalation reviewer's REVIEW_RESULT output
# and extracts severity updates before calling this merge step
print('Merge step: apply escalated severities from escalation reviewer output to reviewer-findings.json')
print('Uncertain finding indices: ' + str(uncertain_indices))
"
```

**Severity replacement rule**: The escalated reviewer's severity determination for each uncertain finding is authoritative. It replaces the original finding's severity in the merged `reviewer-findings.json`. Findings not referenced in `escalate_review` retain their original severities unchanged.

After merging, `reviewer-findings.json` reflects the escalated severities for uncertain findings. Proceed to Step 4b with the updated findings.

### 5b. Parse approach_viability_concern (Orchestrator Reading)

After Step 4a completes (escalation merged or skipped) and before entering Step 4b, parse `approach_viability_concern` from the reviewer's summary text. This signal is embedded in the `summary` field of `reviewer-findings.json` as a plain-text line — it is NOT a top-level JSON key.

```bash
APPROACH_VIABILITY_CONCERN=$(python3 -c "
import json, sys, re
try:
    d = json.load(open('$FINDINGS_FILE'))
    summary = d.get('summary', '')
    if re.search(r'approach_viability_concern:\s*true', summary, re.IGNORECASE):
        print('true')
    else:
        print('false')
except Exception as ex:
    print('false', file=sys.stderr)
    print('false')
" 2>/dev/null)
echo "APPROACH_VIABILITY_CONCERN=$APPROACH_VIABILITY_CONCERN"
```

**If `APPROACH_VIABILITY_CONCERN=true`**: log `"approach_viability_concern: true — implementation approach may need revision; signal available for routing to implementation-plan"`. Do NOT halt or block the workflow at this point. The signal is recorded so the calling orchestrator (sprint, commit workflow) can decide how to act after the review cycle completes. Proceed to Step 4b normally.

**If `APPROACH_VIABILITY_CONCERN=false`** (or absent, or unparseable): no action — proceed to Step 4b normally.

**Parsing note**: `approach_viability_concern` is a summary-embedded text signal (like `security_overlay_warranted`) — parse it from the `summary` field text, not from JSON structure. The pattern `approach_viability_concern: true` anywhere in the summary text (case-insensitive) sets the signal.

### 6. Deep-Tier Deduplication

**DEEP-TIER DEDUP** applies when `REVIEW_TIER=deep`. After the opus arch agent completes synthesis and writes the authoritative `reviewer-findings.json`, read `escalate_review` from the synthesized output. The arch agent is responsible for deduplicating escalation requests that refer to the same synthesized finding — the indices in the synthesized `reviewer-findings.json` reference the synthesized findings array, not the per-agent pre-synthesis indices.

If the synthesized `reviewer-findings.json` contains a non-empty `escalate_review`:
1. Apply the **OPUS GUARD** (Step 4a.3): since the arch agent is opus, log `"Opus reviewer emitted ESCALATE_REVIEW — ignoring (opus is terminal tier)"` and skip escalation.

This means: for deep tier reviews, the OPUS GUARD always fires and no escalation dispatch occurs. The arch agent's synthesis is the terminal reviewer output.

**Slot-path reference**: the three pre-synthesis findings files are `reviewer-findings-a.json`, `reviewer-findings-b.json`, `reviewer-findings-c.json`. These are consumed by the opus arch agent during synthesis. The `escalate_review` entries in these slot files contain pre-synthesis indices and are NOT parsed by Step 4a — the opus arch agent translates them to synthesized indices during the synthesis pass, and the OPUS GUARD suppresses further escalation.

## Step 4b: Overlay Dispatch (Conditional)

After Step 4 returns, check whether security, performance, or test quality overlays are warranted. Overlay agents produce findings in standard `reviewer-findings.json` format, which are merged with the tier reviewer's findings before recording.

### 1. Read Overlay Flags

Read `security_overlay`, `performance_overlay`, and `test_quality_overlay` from the classifier output captured in Step 3:

```bash
# $CLASSIFIER_OUTPUT is the shell variable captured in Step 3 (classifier stdout)
SECURITY_OVERLAY=$(echo "$CLASSIFIER_OUTPUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('security_overlay', False))" 2>/dev/null || echo "false")
PERFORMANCE_OVERLAY=$(echo "$CLASSIFIER_OUTPUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('performance_overlay', False))" 2>/dev/null || echo "false")
TEST_QUALITY_OVERLAY=$(echo "$CLASSIFIER_OUTPUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('test_quality_overlay', False))" 2>/dev/null || echo "false")
```

If all are `False` and no tier reviewer signal is present (see Serial Path below), skip to Step 5.

### 2. Parallel Path (deterministic classifier signal)

If any of `SECURITY_OVERLAY`, `PERFORMANCE_OVERLAY`, or `TEST_QUALITY_OVERLAY` is `True`, the classifier flagged the overlay at classification time. Source `scripts/overlay-dispatch.sh` and call `overlay_dispatch_mode` to determine whether the overlay agents were already launched in parallel alongside the tier reviewer: # shim-exempt: internal library source, not a user-invocable command

```bash
PLUGIN_SCRIPTS="${CLAUDE_PLUGIN_ROOT}/scripts" # shim-exempt: internal source path for overlay-dispatch.sh library
source "$PLUGIN_SCRIPTS/overlay-dispatch.sh" # shim-exempt: internal library source
# Write classifier output to temp file for overlay-dispatch.sh consumption
echo "$CLASSIFIER_OUTPUT" > "$ARTIFACTS_DIR/classifier-overlay-input.json"
# reviewer-summary.txt is written by the tier reviewer sub-agent in Step 4
MODE=$(overlay_dispatch_mode "$ARTIFACTS_DIR/classifier-overlay-input.json" "$ARTIFACTS_DIR/reviewer-summary.txt")
```

If `MODE` is `"parallel"`, the overlay agents were dispatched alongside the tier reviewer in Step 4. Parse their outputs:

- **Security overlay**: The security red team agent produces output conforming to the schema in `docs/contracts/security-red-team-output.md`. The red team output is passed through a blue team triage agent; only surviving findings (not dismissed by blue team) are included.
- **Performance overlay**: Produces direct findings in standard format — no triage step.
- **Test quality overlay**: The `dso:code-reviewer-test-quality` agent evaluates test files against the behavioral testing standard (`skills/shared/prompts/behavioral-testing-standard.md`). Produces direct findings in standard format — no triage step.

### 3. Serial Path (tier reviewer signal)

If all classifier overlay flags are `False`, check the tier reviewer's summary output for late-binding signals:

- `security_overlay_warranted: yes`
- `performance_overlay_warranted: yes`
- `test_quality_overlay_warranted: yes`

If any signal is present, dispatch the corresponding overlay agent(s) serially (after the tier review has completed). Parse outputs using the same logic as the Parallel Path above.

### 4. Merge Findings

Call `hooks/resolve-overlay-findings.sh` with `--findings-json` for each overlay's output:

```bash
"${CLAUDE_PLUGIN_ROOT}/hooks/resolve-overlay-findings.sh" \
    --findings-json "$ARTIFACTS_DIR/overlay-security-findings.json" \
    --findings-json "$ARTIFACTS_DIR/overlay-performance-findings.json" \
    --findings-json "$ARTIFACTS_DIR/overlay-test-quality-findings.json"
```

Pass only the `--findings-json` arguments for overlays that actually ran.

- If the script exits with `OVERLAY_BLOCKED`: the overlay found blocking issues. Enter the Autonomous Resolution Loop (Step R below) with the merged findings, the same way tier reviewer blocking findings are handled.
- If not blocked: proceed to Step 5 (Record Review). The merged findings are incorporated into the final `reviewer-findings.json`.

### 5. Graceful Degradation

Use `overlay_dispatch_with_fallback` (from `scripts/overlay-dispatch.sh`) to ensure overlay agent failures do not block commits. # shim-exempt: internal library reference — If an overlay agent times out or returns malformed output, the fallback logs a warning and continues with tier-only findings. The commit proceeds without overlay coverage, and a warning is emitted so the gap is visible.

---

## Step 5: Record Review

**Prerequisite**: You MUST have a sub-agent result from Step 4. If you do not have a Task tool result to reference, STOP — you skipped Step 4.

**Deep tier note**: For deep tier reviews, `REVIEWER_HASH` comes from the opus arch agent (`dso:code-reviewer-deep-arch`) output — not from any of the 3 sonnet agents. The arch agent is the sole writer of the final `reviewer-findings.json`, so its `REVIEWER_HASH` is the one that `record-review.sh` must validate.

### Extract sub-agent output

1. Extract `REVIEWER_HASH=<hash>` from the sub-agent's fixed-format Task tool return value.
2. Extract `REVIEW_RESULT` (passed/failed), `FINDING_COUNT`, and `FILES` for constructing `feedback` and `files_targeted`.
3. If the review failed and you need finding details, read `reviewer-findings.json` from disk:
   ```bash
   REPO_ROOT=$(git rev-parse --show-toplevel)
   source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/deps.sh"  # or: ${CLAUDE_PLUGIN_ROOT}/hooks/lib/deps.sh
   ARTIFACTS_DIR=$(get_artifacts_dir)
   FINDINGS_FILE="$ARTIFACTS_DIR/reviewer-findings.json"
   cat "$FINDINGS_FILE" | python3 -c "import json,sys; d=json.load(sys.stdin); [print(f'[{f[\"severity\"]}] {f[\"category\"]}: {f[\"description\"]}') for f in d['findings'] if f['severity'] in ('critical','important')]"
   ```

### Integrity Rules

Scores come exclusively from `reviewer-findings.json` (written by the code-reviewer sub-agent via `write-reviewer-findings.sh`). The orchestrator does NOT determine pass/fail.

- **R1 - Sub-agent only**: `record-review.sh` reads all review data directly from `reviewer-findings.json`. No orchestrator-constructed JSON is accepted. The orchestrator's only role is to pass `--reviewer-hash` and `--expected-hash`.
- **R2 - No dismissal**: "Pre-existing", "not a runtime bug", "trivial/cosmetic" are not valid grounds for dismissing findings. Create tracking issues for pre-existing problems instead.
- **R3 - Critical/important resolution**: Any critical or important finding triggers the Autonomous Resolution Loop (see "After Review").
- **R4 - Verbatim severity**: The summary must reference the reviewer's severity levels exactly as stated. Do not downgrade or rephrase severity.
- **R5 - Defense mechanism**: To dispute a finding without user involvement, the orchestrator MUST add a **code-visible defense** — an inline comment with the `# REVIEW-DEFENSE:` prefix, a docstring addition, or a type annotation that explains the design rationale to the reviewer. The orchestrator MUST NOT silently dismiss findings, override scores, or add comments that merely suppress warnings without explanation. Defense comments must reference verifiable artifacts (existing code, tests, ADRs, or documented patterns) — not unverifiable claims like "for performance reasons." The defense must be substantive enough that a human reading the code would understand the tradeoff. **Structural findings** (type annotations, test coverage gaps, missing error handling) should prefer Fix over Defend — the reviewer scores these based on code patterns, and a comment is unlikely to change the score.

### Record the review

Call `record-review.sh` with `--expected-hash` from Step 2 and `--reviewer-hash` from the sub-agent output. No stdin JSON is needed — the script reads directly from `reviewer-findings.json`:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
"${CLAUDE_PLUGIN_ROOT}/hooks/record-review.sh" \
  --expected-hash "<DIFF_HASH from Step 2>" \
  --reviewer-hash "<REVIEWER_HASH from sub-agent>"
```

`record-review.sh` reads scores, summary, and findings from `reviewer-findings.json`, verifies `--reviewer-hash` integrity, validates findings against scores, checks file overlap with the actual diff, verifies `--expected-hash` against the current diff hash, and writes the review state file that the commit gate checks. If it rejects, fix and retry.

**File-overlap rejection recovery**: If `record-review.sh` exits with `ERROR: reviewer findings files do not overlap with any changed files in the diff`, the reviewer's `file` fields in its findings reference files not in the diff (e.g., test files from verification recommendations instead of the source files being reviewed). Do NOT escalate to the user immediately. Instead: (1) re-dispatch the review with a higher-tier reviewer (e.g., light → standard) which is more reliable at correctly reporting diff files in the `file` field; (2) if the re-dispatched reviewer also produces non-overlapping files, THEN escalate to the user.

**IMPORTANT — always use `compute-diff-hash.sh`**: Never compute the diff hash via raw `git diff | shasum` — the canonical script applies pathspec exclusions (`.tickets-tracker/`, snapshots, images) and checkpoint-aware diff base detection. Untracked files are excluded (new files must be staged before review). A raw pipeline produces a completely different hash and will cause `--expected-hash` mismatch errors.

## After Review

### If ALL scores are 4, 5, or "N/A" AND no critical findings:
Review passed. **Immediately resume the calling workflow** — do NOT wait for user input. If this workflow was invoked from COMMIT-WORKFLOW.md Step 5, proceed directly to Step 6 (Commit). If invoked from another orchestrator, resume at the step after the review invocation. Note: this branch requires ALL scores >= 4. A score of 3 with important findings is NOT a pass — it enters the resolution loop below.

**Post-pass findings inspection** (required — runs before resuming the calling workflow):

Even on a passing review, `reviewer-findings.json` may contain actionable `minor` or `suggestion` severity findings. These must not be silently dropped. After confirming the review passed:

1. Read `reviewer-findings.json` from `$ARTIFACTS_DIR`
2. Filter findings where `severity` is `minor` or `suggestion` AND the finding describes a concrete, actionable improvement (not a stylistic preference or subjective opinion)
3. For each actionable finding, create a bug ticket so it is tracked for a future session:
   ```bash
   .claude/scripts/dso ticket create bug "[Component]: [finding summary]" -d "## Incident Overview
   Source: code review (passed) — minor finding not addressed in this session.
   Finding: <finding description from reviewer-findings.json>
   File: <file path from finding>
   Category: <finding category>"
   ```
4. If zero actionable findings exist, skip ticket creation — proceed immediately

This step is non-blocking: ticket creation failures do not prevent the calling workflow from resuming. Log a warning on failure and continue.

**Emit review result event** (best-effort — does not block the workflow):

```bash
".claude/scripts/dso" emit-review-result.sh \
  --pass-fail=passed \
  --revision-cycles=0 \
  --resolution-code-changes=0 \
  --resolution-defenses=0 \
  --tier-original="$REVIEW_TIER" \
  --tier-final="$REVIEW_TIER" \
  --overlay-security="${OVERLAY_SECURITY:-false}" \
  --overlay-performance="${OVERLAY_PERFORMANCE:-false}" \
  --overlay-test-quality="${TEST_QUALITY_OVERLAY:-false}"
```

### If ANY score is below 4, OR any critical finding exists:
Review failed. Enter the Autonomous Resolution Loop. Critical findings always fail regardless of score.

#### Autonomous Resolution Loop

**Deep tier note**: For deep tier reviews, the resolution sub-agent receives findings via the authoritative `$ARTIFACTS_DIR/reviewer-findings.json` — written by `dso:code-reviewer-deep-arch` (opus). The resolution sub-agent MUST NOT access `reviewer-findings-{a,b,c}.json`; those are sonnet-only artifacts consumed only during the opus synthesis pass.

**INLINE FIX PROHIBITION**: The orchestrator MUST NOT use Edit, Write, or Bash to fix review findings directly. All fixes MUST go through a resolution sub-agent dispatch. There are no exceptions.

**Architecture**: The resolution loop is split across two levels to avoid nested sub-agent nesting
that causes `[Tool result missing due to internal error]`:

1. **Resolution sub-agent** (fix only): reads findings, applies fixes/defenses/defers, validates.
   Returns `FIXES_APPLIED` when local validation passes. Does NOT dispatch a re-review sub-agent.
2. **Orchestrator** (re-review): after the resolution sub-agent returns `FIXES_APPLIED`, dispatches
   a re-review sub-agent, interprets results, and calls `record-review.sh`.

This design keeps nesting at one level (orchestrator → sub-agent) for both the fix and re-review steps.

**Before dispatching**, record the current time for freshness verification and initialize the ratchet variable:

```bash
DISPATCH_TIME=$(date +%s)
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/deps.sh"
ARTIFACTS_DIR="$(get_artifacts_dir)"
# RATCHETED_TIER tracks escalation from ESCALATE_REVIEW (Step 4a).
# Once set, it ensures re-review passes use at least the escalated tier.
# Initialized to empty (no ratchet in effect) before the first dispatch.
RATCHETED_TIER=''
```

Read `${CLAUDE_PLUGIN_ROOT}/docs/workflows/prompts/review-fix-dispatch.md` and use its contents as the sub-agent prompt, filling in:
- `{findings_file}`: `$(get_artifacts_dir)/reviewer-findings.json`
- `{diff_file}`: the `DIFF_FILE` path from Step 2
- `{repo_root}`: `REPO_ROOT` value
- `{worktree}`: `WORKTREE` value
- `{issue_ids}`: issue IDs associated with the current work (for `.claude/scripts/dso ticket create` defers), or empty string
- `{cached_model}`: model name derived from `REVIEW_TIER` in Step 3 (`light`→`haiku`, `standard`→`sonnet`, `deep`→`opus`)
- `{findings_file}`: for deep tier, this is the authoritative `$ARTIFACTS_DIR/reviewer-findings.json` — the file written by `dso:code-reviewer-deep-arch` (opus). The resolution sub-agent MUST NOT read or write `reviewer-findings-{a,b,c}.json`; those are sonnet-only artifacts consumed only during the opus synthesis pass.

```
Task tool:
  subagent_type: "general-purpose"
  model: "sonnet"
  description: "Resolve review findings"
  prompt: <filled template from review-fix-dispatch.md>
```

**NEVER set `isolation: "worktree"` on this sub-agent.** It must edit the same working tree files that the orchestrator and re-review agent will see. This ISOLATION PROHIBITION applies to all tiers including deep tier.

**After resolution sub-agent returns**, interpret the compact output:

| `RESOLUTION_RESULT` | Action |
|---------------------|--------|
| `FIXES_APPLIED` | Fixes passed local validation. Orchestrator dispatches re-review sub-agent (see below). |
| `FAIL` | **Before escalating to user**: check whether a tier upgrade is available (e6ba-5afa). If current tier is light, upgrade to standard. If standard, upgrade to deep (3 sonnet + opus arch). Only escalate to user after the highest available tier has been exhausted. Use `REMAINING_CRITICAL` and `ESCALATION_REASON` for escalation context. |
| `ESCALATE` | **Before presenting to user**: same tier-upgrade check as FAIL. Only present `ESCALATION_REASON` to user after all reviewer tiers have been attempted. |

**When `RESOLUTION_RESULT: FIXES_APPLIED`** — orchestrator dispatches re-review sub-agent:

1. Capture a fresh diff hash and diff file (the resolution sub-agent changed the code):
   ```bash
   NEW_DIFF_HASH=$("$REPO_ROOT/.claude/scripts/dso" compute-diff-hash.sh)
   NEW_DIFF_HASH_SHORT="${NEW_DIFF_HASH:0:8}"
   NEW_DIFF_FILE="$ARTIFACTS_DIR/review-diff-${NEW_DIFF_HASH_SHORT}.txt"
   NEW_STAT_FILE="$ARTIFACTS_DIR/review-stat-${NEW_DIFF_HASH_SHORT}.txt"
   "$REPO_ROOT/.claude/scripts/dso" capture-review-diff.sh "$NEW_DIFF_FILE" "$NEW_STAT_FILE"
   ```

2. **Re-review model escalation**: Increment `REVIEW_PASS_NUM` by 1 before each re-review dispatch, then select the re-review agent based on the updated value. On repeated failures, upgrade the reviewer model to prevent infinite loops with a reviewer that cannot process the context (e.g., light-tier reviewers producing recurring false positives on REVIEW-DEFENSE comments). `RATCHETED_TIER` (set in Step 4a when `ESCALATE_REVIEW` triggered escalation) is respected as a one-way floor — once set, the re-review tier never drops below it:

   | `REVIEW_PASS_NUM` (after increment) | Re-review Agent | Rationale |
   |---|---|---|
   | 2 | `REVIEW_AGENT` from Step 3 (unchanged for standard); deep → full deep-multi-reviewer pipeline; light → upgrade to `dso:code-reviewer-standard` | Deep tier always requires 3 sonnet + opus sequence; light-tier haiku lacks context for REVIEW-DEFENSE |
   | Any pass with `RATCHETED_TIER` set | Use `max(RATCHETED_TIER, current escalation result)` — ratchet only goes up, never down | Preserves escalation from Step 4a `ESCALATE_REVIEW` across all re-review passes; ordinal: light=1, standard=2, deep=3 |

   ```bash
   # Re-review model escalation logic
   # RATCHETED_TIER is initialized before the first dispatch and updated by Step 4a.
   # It defaults to empty here if not previously set (no ESCALATE_REVIEW escalation occurred).
   RATCHETED_TIER="${RATCHETED_TIER:-}"
   ((REVIEW_PASS_NUM++))
   RE_REVIEW_AGENT="$REVIEW_AGENT"
   RE_REVIEW_DEEP_FULL=false
   if [[ "$REVIEW_PASS_NUM" -ge 2 ]] && [[ "$REVIEW_TIER" == "deep" ]]; then
       # Deep tier always requires full pipeline — opus arch without fresh
       # sonnet findings produces incomplete reviews (bug d7e6-216a)
       RE_REVIEW_DEEP_FULL=true
   elif [[ "$REVIEW_PASS_NUM" -ge 2 ]] && [[ "$REVIEW_TIER" == "light" ]]; then
       RE_REVIEW_AGENT="dso:code-reviewer-standard"
   fi
   # Apply RATCHETED_TIER: one-way floor from any prior ESCALATE_REVIEW dispatch (Step 4a).
   # Ordinal mapping: light=1, standard=2, deep=3. Ratchet only goes up.
   if [[ -n "$RATCHETED_TIER" ]]; then
       _tier_ordinal() { case "$1" in light) echo 1;; standard) echo 2;; deep) echo 3;; *) echo 0;; esac; }
       _current_tier="$REVIEW_TIER"
       [[ "$RE_REVIEW_AGENT" == "dso:code-reviewer-standard" ]] && _current_tier="standard"
       [[ "$RE_REVIEW_DEEP_FULL" == "true" ]] && _current_tier="deep"
       if [[ $(_tier_ordinal "$RATCHETED_TIER") -gt $(_tier_ordinal "$_current_tier") ]]; then
           case "$RATCHETED_TIER" in
               standard)
                   RE_REVIEW_AGENT="dso:code-reviewer-standard"
                   RE_REVIEW_DEEP_FULL=false
                   ;;
               deep)
                   RE_REVIEW_DEEP_FULL=true
                   ;;
           esac
       fi
   fi
   # When RE_REVIEW_DEEP_FULL=true, dispatch the full Step 4 Deep Tier
   # sequence (3 parallel sonnet + opus synthesis) instead of a single agent.
   ```

   **Do NOT re-run the classifier** for re-review passes — the diff shrank after fixes, which would produce a lower score and potentially route back to `light`. `REVIEW_TIER` is locked to its Step 3 value for the lifetime of this review session. The `RE_REVIEW_AGENT` escalation table above is the only permitted source of tier changes in re-review passes.

   **Mid-resolution approach_viability_concern check (DD3)**: After the ratchet state update above and before dispatching the next re-review attempt, re-read `approach_viability_concern` from the most recent `reviewer-findings.json`. This catches cases where the signal was emitted by a re-review (not present in the initial review).

   ```bash
   # Re-read approach_viability_concern from the current reviewer-findings.json
   # (may have been written by a re-review agent in this resolution iteration)
   MID_RESOLUTION_AVC=$(python3 -c "
   import json, sys, re
   try:
       d = json.load(open('$FINDINGS_FILE'))
       summary = d.get('summary', '')
       if re.search(r'approach_viability_concern:\s*true', summary, re.IGNORECASE):
           print('true')
       else:
           print('false')
   except Exception:
       print('false')
   " 2>/dev/null)

   if [[ "$MID_RESOLUTION_AVC" == "true" ]]; then
       echo "approach_viability_concern detected mid-resolution — completing current attempt then routing to implementation-plan"
       # Exit the resolution loop — the calling orchestrator (sprint, commit) decides how to act.
       # Do NOT dispatch another resolution sub-agent or re-review after this exit.
       break  # or: set a flag and exit after current iteration completes
   fi
   ```

   **If `approach_viability_concern` is true mid-resolution**: log the message above and exit the resolution loop immediately. The current resolution attempt has already completed (fixes were applied). The calling orchestrator receives control and is responsible for routing to `implementation-plan` re-invocation or surfacing the signal to the user. Do NOT continue attempting to resolve review findings — the approach itself may need revision.

   Dispatch the re-review:
   - **If `RE_REVIEW_DEEP_FULL=true`**: Run the full Step 4 Deep Tier sequence (3 parallel sonnet agents writing to slot files, then opus arch synthesis). Do NOT dispatch `dso:code-reviewer-deep-arch` alone.
   - **Otherwise**: Dispatch a single re-review sub-agent using `RE_REVIEW_AGENT`. **VERBATIM REQUIRED** — you MUST read the agent file and pass its content as the first element of the prompt, exactly as Step 4 initial dispatch does. Do NOT write a constructed prompt (e.g., "Review the code changes for this commit.") — that is fabrication.

   ```bash
   # Read the re-review agent file verbatim — MANDATORY before every dispatch
   RE_AGENT_NAME="${RE_REVIEW_AGENT#dso:}"
   RE_AGENT_FILE="${CLAUDE_PLUGIN_ROOT}/agents/${RE_AGENT_NAME}.md"
   RE_AGENT_CONTENT=$(cat "$RE_AGENT_FILE")
   RE_AGENT_MODEL=$(grep '^model:' "$RE_AGENT_FILE" | awk '{print $2}')
   ```

   ```
   Agent tool:
     subagent_type: "general-purpose"
     model: "{RE_AGENT_MODEL from agent file frontmatter}"
     description: "Re-review after fixes"
     prompt: |
       {RE_AGENT_CONTENT — verbatim content of ${CLAUDE_PLUGIN_ROOT}/agents/{RE_AGENT_NAME}.md}

       DIFF_FILE: {NEW_DIFF_FILE}
       REPO_ROOT: {REPO_ROOT}

       === DIFF STAT ===
       {content of NEW_STAT_FILE}

       {issue_context}
   ```

   **NEVER set `isolation: "worktree"` on this sub-agent.** It must access `reviewer-findings.json` and `write-reviewer-findings.sh` in the shared working directory.

3. Parse re-review sub-agent output: extract `REVIEW_RESULT`, `MIN_SCORE`, `REVIEWER_HASH`.

4. **If re-review passes** (MIN_SCORE ≥ 4 and no critical findings):
   Call `record-review.sh` with the NEW diff hash and re-review's REVIEWER_HASH:
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/hooks/record-review.sh" \
     --expected-hash "<NEW_DIFF_HASH>" \
     --reviewer-hash "<REVIEWER_HASH from re-review sub-agent>"
   ```

   **Emit review result event** (best-effort — does not block the workflow):

   ```bash
   ".claude/scripts/dso" emit-review-result.sh \
     --pass-fail=passed \
     --revision-cycles="$REVIEW_PASS_NUM" \
     --resolution-code-changes="$RESOLUTION_CODE_CHANGES" \
     --resolution-defenses="$RESOLUTION_DEFENSES" \
     --tier-original="$REVIEW_TIER" \
     --tier-final="$([ "$RE_REVIEW_DEEP_FULL" = true ] && echo deep || echo "$REVIEW_TIER")" \
     --overlay-security="${OVERLAY_SECURITY:-false}" \
     --overlay-performance="${OVERLAY_PERFORMANCE:-false}"
   ```

   Then proceed to commit.

5. **If re-review fails**: run the OSCILLATION GATE before dispatching another resolution sub-agent.

   **OSCILLATION GATE (mandatory on attempt 2+)**:
   - If attempt >= 2: run `/dso:oscillation-check` unconditionally. Do NOT skip based on whether findings appear new.
   - If OSCILLATION detected: escalate immediately. Do NOT dispatch another resolution sub-agent.
   - If CLEAR: dispatch the next resolution sub-agent.

   **Max attempts**: Read `review.max_resolution_attempts` from `dso-config.conf` (default: 5). When attempts exceed this value, **STOP — DO NOT PROCEED to user escalation**. First, check whether a tier upgrade is available: if the current reviewer is light or standard tier, you MUST upgrade to the deep tier (3 parallel sonnet specialists + opus architectural synthesis) before any user escalation. Only after the deep tier has been dispatched and also failed may you escalate to the user. Do NOT escalate to user while a higher-tier reviewer is still available and untried.

   ```bash
   MAX_ATTEMPTS=$("$REPO_ROOT/.claude/scripts/dso" read-config.sh review.max_resolution_attempts)
   MAX_ATTEMPTS="${MAX_ATTEMPTS:-5}"
   ```

6. **If re-review fails** (attempt count exceeds `MAX_ATTEMPTS`, or oscillation detected): **DO NOT commit with a failing review.** A failing review is never a reason to bypass the review gate — the pre-commit hook will block it regardless, and attempting it wastes context. Instead: before escalating to user, verify that the full deep-multi-reviewer path at PASS_NUM 3+ has been attempted (3 parallel sonnet specialists + opus arch synthesis — for ALL tiers, not just deep). User escalation is the **last resort**, after the full deep tier review has been exhausted. Only then: escalate to user.

**Escalation message format** (when sub-agent returns FAIL or ESCALATE, or re-review fails twice):

```
## Review Escalation

### Remaining Findings
<REMAINING_CRITICAL from sub-agent>

### Recommendation
<ESCALATION_REASON from sub-agent>

### Actions Needed
For each finding, reply: fix (I'll try a different approach), override (accept as-is), or defer (skip for now).
```

---

## Post-Deployment Calibration

After deploying the classifier-based review routing, monitor `classifier-telemetry.jsonl` to verify the classifier is producing healthy tier distributions and that routing quality is meeting expectations. Use the signals below to detect miscalibration early and respond before it compounds.

**Data source**: `$ARTIFACTS_DIR/classifier-telemetry.jsonl` (one JSON object per classification event; written by `review-complexity-classifier.sh` on every run). Aggregate over the most recent 30 commits as the baseline window.

### Tier Distribution Baseline

After 30 commits, compute the tier distribution from `classifier-telemetry.jsonl`:

```bash
python3 -c "
import json, collections, sys
entries = [json.loads(l) for l in open('classifier-telemetry.jsonl') if l.strip()]
tiers = collections.Counter(e['selected_tier'] for e in entries[-30:])
total = sum(tiers.values())
for t, n in sorted(tiers.items()):
    print(f'{t}: {n}/{total} ({100*n/total:.0f}%)')
"
```

**Expected healthy baseline**:

| Tier | Expected Range |
|------|---------------|
| Light | ~50-60% |
| Standard | ~30-40% |
| Deep | ~5-15% |

**Signal**: any single tier exceeding 80% of all classifications indicates the classifier is miscalibrated. A Light-heavy skew suggests floor rules are under-catching risky changes; a Deep-heavy skew suggests scoring weights are too aggressive.

### Light-Tier Finding Rate

Track the rate at which Light-tier reviews surface `critical` or `important` findings. If Light-tier reviews produce critical/important findings at a rate greater than 10%, the floor rules are insufficient — Light is being assigned to commits that warrant Standard or Deep review.

**Response**:
1. Identify the pattern shared by the triggering commits (file types, change categories, or scoring features).
2. Add a matching floor rule to `scripts/review-complexity-classifier.sh`. # shim-exempt: safeguard file, direct path required for developer modification instructions
3. Re-validate: re-run the classifier against the 30-commit sample and confirm the affected commits now route to Standard or Deep.

### CI Failure Rate by Tier

Track the post-merge CI failure rate per tier for the first 30 commits. A higher CI failure rate in Light tier than in Standard or Deep indicates under-classification — commits that broke CI were routed to the lightest review tier.

**Response**: Lower the Light/Standard classification threshold or add floor rules targeting the file types or change patterns present in the failing commits.

### Baseline Comparison

Compare the overall CI failure rate for the 30 commits following deployment against the 30 commits preceding deployment. A sustained increase in post-merge CI failures is a routing gap signal — the classifier is not catching changes that need heavier review.

**Response**: Audit `classifier-telemetry.jsonl` for the failing commits, identify whether tier mis-assignment is the common factor, then apply threshold or floor-rule adjustments as above.

### Breach Response Protocol

When any signal above crosses its threshold, follow this protocol:

1. **Create a P1 bug ticket**: `.claude/scripts/dso ticket create bug "Classifier miscalibration: <signal description>" --priority 1` — record the specific signal, threshold crossed, and the affected commit range.
2. **Adjust the classifier**: modify floor rules or scoring weights in `scripts/review-complexity-classifier.sh` to correct the miscalibration. # shim-exempt: safeguard file, direct path required for developer modification instructions
3. **Re-validate**: re-run the classifier against the same 30-commit sample that triggered the breach and confirm the signal is no longer breaching its threshold before closing the ticket.
