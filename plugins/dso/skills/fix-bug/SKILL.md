---
name: fix-bug
description: Classify bugs by type and severity, then route through the appropriate investigation and fix path.
user-invocable: true
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
---

# Fix Bug: Investigation-First Bug Resolution

You are a Principal Software Engineer at Google who specializes in troubleshooting. Enforce a hard separation between investigation and implementation. Bugs are classified, scored, investigated to root cause, and only then fixed — with TDD discipline ensuring the fix is verified.

This skill handles bug fixes with investigation-first TDD discipline.

**Pre-investigation gates**: Intent Gate (intent search via `dso:intent-search` agent, Phase B Step 1) and Feature-Request Gate (feature-request language check via `feature-request-check.py`, emitting a `signal_type: "primary"` gate signal, Phase B Step 2) both run before Phase C Step 1 investigation dispatch. Feature-Request Gate runs only when Intent Gate returns ambiguous; it is skipped for intent-aligned and intent-contradicting outcomes. On script failure, the gate defaults to non-blocking to prevent investigation blockage.

<HARD-GATE>
Do NOT modify any code, write any fix, or make any file changes until Steps 1–5 are complete (classify, investigate, hypothesis test, approve, RED test). This applies regardless of how simple or obvious the bug appears. Steps 1–5 must complete before any code modification.

Do NOT modify skill files, agent files, or prompt templates for llm-behavioral bugs until investigation is complete. LLM-behavioral bugs follow the same investigation discipline as code bugs — the HARD-GATE applies equally to skill file changes, agent file changes, and prompt template edits. Do not edit any .md file in skills/, agents/, or prompts/ directories before completing Steps 1–5.

Do NOT investigate inline as a substitute for sub-agent dispatch. Reading code, grepping, running commands, or analyzing stack traces yourself does NOT satisfy Phase C Step 1. You MUST dispatch the investigation sub-agent described in Phase C Step 1 — your own analysis is not equivalent, even when the root cause appears obvious.
</HARD-GATE>

## Config Resolution (reads project workflow-config.yaml)

At activation, load project commands via read-config.sh before executing any steps:

```bash
PLUGIN_SCRIPTS="${CLAUDE_PLUGIN_ROOT}/scripts"
TEST_CMD=$(bash "$PLUGIN_SCRIPTS/read-config.sh" commands.test)  # shim-exempt: internal orchestration script
LINT_CMD=$(bash "$PLUGIN_SCRIPTS/read-config.sh" commands.lint)  # shim-exempt: internal orchestration script
FORMAT_CHECK_CMD=$(bash "$PLUGIN_SCRIPTS/read-config.sh" commands.format_check)  # shim-exempt: internal orchestration script
```

Resolution order: See `${CLAUDE_PLUGIN_ROOT}/docs/CONFIG-RESOLUTION.md`.

Resolved commands used in this skill:
- `TEST_CMD` — used in RED test (Phase E Step 1), fix verification (Phase E Step 4), and mechanical fix validation
- `LINT_CMD` — used in fix verification (Phase E Step 4)
- `FORMAT_CHECK_CMD` — used in fix verification (Phase E Step 4)

## Migration Check

Idempotently apply plugin-shipped ticket migrations (marker-gated; no-op once migrated, never blocks the skill):

```bash
bash "$PLUGIN_SCRIPTS/ticket-migrate-brainstorm-tags.sh" 2>/dev/null || true  # shim-exempt: internal orchestration script
```

## Empirical Validation Directive

Apply `skills/shared/prompts/empirical-validation.md` at every investigation tier. The directive is enforced by the Empirical Validation step in each investigator agent's base scaffold (`investigator-base.md`) — never assume unobserved tool, API, or system behavior; label evidence as documented vs. observed; test fix approaches in isolation before proposing them.

## Error Type Classification

Before scoring, classify the error:

### Mechanical Errors

Mechanical errors have an obvious, deterministic fix that requires no investigation. These skip the scoring rubric and route directly to the **Mechanical Fix Path** (read the error, apply the fix, validate).

**Exclusion — files matching `fix_bug.llm_behavioral_dirs` config patterns (default: `skills/`, `agents/`, `prompts/`) must not be classified as mechanical.** The default patterns cover the standard DSO plugin structure. Host projects with LLM-behavioral files in different directories should configure `fix_bug.llm_behavioral_dirs` in `.claude/dso-config.conf` (comma-separated list of directory prefixes). Changes to skill files, agent definitions, or prompt templates affect LLM behavior and guidance — even when the fix appears to be "obvious text replacement." These files must be routed through the LLM-behavioral or behavioral classification path, never mechanical. An agent that can see "what text is wrong" in a skill file is not performing a mechanical fix — it is making a judgment about how to change agent behavior, which requires investigation.

Types of mechanical errors:
- **import error** — missing or incorrect import statement
- **type annotation** — incorrect or missing type hint
- **lint violation** — ruff, mypy, or similar linter failure with a clear fix
- **config syntax** — malformed YAML, TOML, JSON, or conf file (not `.md` files in `skills/`, `agents/`, or `prompts/`)

Mechanical Fix Path:
1. Complete Phase A Step 2 (Ticket Lifecycle Setup) — ensure a bug ticket exists and is in-progress
2. Read the error message and identify the exact file and line
3. Apply the deterministic fix (add import, fix type, fix lint, fix syntax)
4. Run `$TEST_CMD` and `$LINT_CMD` to validate
5. If validation passes, run Reversal Gate (Reversal Check) then proceed to Phase H Step 1 (Commit and Close)
6. If validation fails with a NEW error, reclassify — it may be behavioral

### Behavioral Errors

All errors that are NOT mechanical or LLM-behavioral are behavioral. These require investigation and proceed to Phase A Step 3 (Score and Classify).

### LLM-Behavioral Errors

LLM-Behavioral Errors are a distinct classification for bugs where the defect is in how an LLM agent behaves — not in executable code. These bugs are identified using **dual-signal detection**: both signals must be present together to classify a bug as llm-behavioral (preventing over-classification of unrelated markdown changes).

**Dual-signal detection**:
1. **Ticket content signal** — the bug description references LLM output quality, prompt regression, agent guidance gaps, model behavior drift, skill misinterpretation, or agent skips/misinterprets/drifts from expected behavior
2. **File type signal** — the affected file is a skill file (`.md` in `skills/`), an agent file (`.md` in `agents/`), or a prompt template (`.md` in `prompts/`)

Both signals must be present. A markdown file change with no behavioral ticket signal is NOT llm-behavioral. A behavioral complaint with no skill/agent/prompt file involvement is NOT llm-behavioral (route as behavioral instead).

**LLM-Behavioral Fix Path**:

LLM-behavioral bugs follow a combined investigation+fix path (SC5 — HARD-GATE amendment applies). The investigation produces a diagnosis of what behavioral gap or prompt regression is causing the issue, and the fix is a targeted change to the skill, agent, or prompt template.

<SUB-AGENT-GUARD>
Dispatch `dso:bot-psychologist` per `skills/shared/prompts/named-agent-dispatch.md`. Input: bug description, affected skill/agent/prompt file path, ticket content, behavioral symptoms.

**Inline fallback** (Agent tool unavailable / sub-agent context): bot-psychologist's own SUB-AGENT-GUARD blocks nested diagnosis. Read `agents/bot-psychologist.md` as a *reference* for the llm-behavioral taxonomy and probes only — then run the investigation directly using fix-bug's Phase C framework: identify the gap type (prompt regression, guidance gap, behavioral drift, etc.) via the taxonomy, perform static analysis on the affected skill/agent/prompt file. Steps requiring user-provided experimental results get recorded as `INTERACTIVITY_DEFERRED` in RESULT for the orchestrator to escalate.
</SUB-AGENT-GUARD>

**Phase E Step 1 / Phase E Step 2 exemption**: LLM-behavioral bugs are exempt from the standard RED unit test requirement (see Phase E Step 2 for details). The behavioral nature of these bugs means a traditional executable RED test cannot always be written before the fix. Instead, use eval-based verification or behavioral assertion verification as the confirmation mechanism.

## Scoring Rubric (Behavioral Bugs Only)

Score the bug across these dimensions to determine investigation depth:

**Note on intermittent/flaky dimension scope**: This rubric applies to behavioral bugs only (mechanical and llm-behavioral bugs skip to Phase H Step 1). However, the **intermittent/flaky** dimension is relevant to mechanical bugs as well — a mechanical test can fail intermittently due to race conditions or timing issues. If you are on the mechanical path and observe non-deterministic failure behavior, factor that into your investigation depth judgment even though the formal scoring rubric is not applied.

| Dimension | Score 0 | Score 1 | Score 2 |
|-----------|---------|---------|---------|
| **severity** | Low — cosmetic, minor UX | Medium/moderate — functional degradation | High/critical — data loss, security, outage |
| **complexity** | Simple/trivial — single file, obvious cause | Moderate/medium — multiple files, non-obvious | Complex — cross-system, race conditions, emergent |
| **environment** | Local — reproducible in dev | CI failure — reproducible in CI only | Production/staging — observed in deployed env |
| **intermittent/flaky** | Deterministic — passes consistently across 3 consecutive runs | Suspected non-determinism — CI intermittent, env-specific, or <100% reproduction | Directly observed failure-then-pass on identical runs |

The **intermittent/flaky** dimension is additive to the total score — it contributes directly to the sum alongside the other three dimensions. Tier thresholds are unchanged (< 3 = BASIC, 3-5 = INTERMEDIATE, >= 6 = ADVANCED).

### Bonus Modifiers

| Condition | Modifier |
|-----------|----------|
| **Cascading failure** — fixing this bug caused new failures in previous attempts | +2 |
| **Prior fix attempts** — previous commits attempted to fix this bug and failed | +2 |

### Total Score and Routing

Sum all dimension scores and modifiers:

- Score **< 3** : Route to **BASIC** investigation
- Score **3-5** : Route to **INTERMEDIATE** investigation
- Score **>= 6** : Route to **ADVANCED** investigation

## Workflow

## Phase A: Triage

### Step 1: Check Known Issues (/dso:fix-bug)

Before any investigation, check whether this bug (or a similar pattern) is already documented:

```bash
grep -i "<keyword>" "$(git rev-parse --show-toplevel)/.claude/docs/KNOWN-ISSUES.md" 2>/dev/null || true
```

If a known issue matches, note the match for later — after Phase A Step 2 establishes `BUG_TICKET_ID`, record it via `ticket comment <BUG_TICKET_ID> "Known issue match: ..."`. The known issue context informs investigation but does not skip it.

### Step 2: Ticket Lifecycle Setup (/dso:fix-bug)

Ensure a bug ticket exists and is set to in-progress before investigation begins.

1. **If a ticket ID was provided** (via argument or orchestrator context): use it.
2. **If no ticket ID was provided**: search for an existing open bug ticket matching the error description to avoid duplicates:
   ```bash
   ticket list --type=bug --status=open | python3 -c "import json,sys; [print(t['ticket_id'],t['title']) for t in json.load(sys.stdin)]"
   ```
   - If a matching bug is found (same error, same file, or same root symptom): use that ticket ID.
   - If no match: create a new bug ticket. Read `skills/create-bug/SKILL.md` for the required title and description format. At minimum supply `-d` with Section 2 (Incident Overview):
     ```bash
     # Title format: [Component]: [Condition] -> [Observed Result]
     # Capture both stdout and stderr to enable post-creation title validation
     BUG_CREATE_OUT=$(.claude/scripts/dso ticket create bug "[Component]: [Condition] -> [Observed Result]" -d "## Incident Overview ..." 2>/tmp/ticket_create_stderr.tmp)
     BUG_CREATE_ERR=$(cat /tmp/ticket_create_stderr.tmp); rm -f /tmp/ticket_create_stderr.tmp
     BUG_TICKET_ID=$(echo "$BUG_CREATE_OUT" | grep -oE '[0-9a-f]{4}-[0-9a-f]{4}' | head -1)
     ```

     **Post-creation title validation:** After creating a bug ticket, check stderr for the title format warning:

     ```bash
     if echo "$BUG_CREATE_ERR" | grep -q "does not match required pattern"; then
         # Re-title immediately using [Component]: [Condition] -> [Observed Result] format
         .claude/scripts/dso ticket edit "$BUG_TICKET_ID" --title="[Component]: [Condition] -> [Observed Result]"
     fi
     ```

     The title format MUST follow `[Component]: [Condition] -> [Observed Result]`. Do not proceed with a non-conforming title.

3. **Set the ticket to in-progress** (check current status first to avoid optimistic concurrency errors):
   ```bash
   CURRENT_STATUS=$(ticket show <id> | python3 -c "import json,sys; print(json.load(sys.stdin).get('status','open'))")
   if [ "$CURRENT_STATUS" != "in_progress" ] && [ "$CURRENT_STATUS" != "closed" ]; then
       ticket transition <id> "$CURRENT_STATUS" in_progress
   fi
   ```

Store the ticket ID as `BUG_TICKET_ID` for use throughout the workflow.

Post WORKTREE_TRACKING:start on the bug ticket (fail silently if .tickets-tracker/ unavailable): # tickets-boundary-ok
```bash
_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "unknown")
.claude/scripts/dso ticket comment "$BUG_TICKET_ID" "WORKTREE_TRACKING:start branch=${_BRANCH} session_branch=${_BRANCH} timestamp=${_TS}" 2>/dev/null || true
```

#### Auto-Resume Detection

After transitioning the bug ticket to in_progress, scan for abandoned worktrees from prior sessions:

1. Read comments on the bug ticket (`.claude/scripts/dso ticket show "$BUG_TICKET_ID"`) and find `WORKTREE_TRACKING:start` entries with no corresponding `:complete`
2. For each unmatched start, extract the branch:
   - If branch no longer exists: skip without error
   - If branch is ancestor of HEAD: write retroactive `:complete` with `outcome=already_merged`
   - If mid-merge state (MERGE_HEAD exists): run `git merge --abort` first
   - If branch has unique commits: attempt `git merge --no-edit <branch>`
     - Success: log `'Merged abandoned branch <b>'`
     - Conflict: run `git merge --abort`, log `'Conflict in <b> — discarded'`
3. If multiple competing branches found (N>1 unmatched starts from distinct branch names), apply tiebreak cascade:
   - Stage 1: task-list criterion count (verbatim `- [ ]`/`- [x]` matches in branch diff)
   - Stage 2: test-gate-status artifact (`passed` > `failed` > absent)
   - Stage 3: conflict count via dry-run merge
   - Stage 4: most recent `WORKTREE_TRACKING:start` timestamp
   - Merge the winner; discard (log, skip) the rest
4. Proceed with normal fix-bug flow

### Step 3: Score and Classify (/dso:fix-bug)

1. Read the bug description, error messages, and stack traces
2. Classify: **mechanical**, **behavioral**, or **llm-behavioral** (see Error Type Classification above)
3. If mechanical: follow the Mechanical Fix Path, then skip to Phase H Step 1
4. If llm-behavioral (dual-signal detected — ticket references LLM behavior AND affected file is in `skills/`, `agents/`, or `prompts/`): record the classification: `ticket comment <BUG_TICKET_ID> "Classification: llm-behavioral"`, then dispatch `dso:bot-psychologist` via the LLM-Behavioral Fix Path (see above), then skip to Phase H Step 1
5. If behavioral: proceed to Compound Bug Detection (compound bug detection) before applying the Scoring Rubric
6. Record the classification and score in a ticket note: `ticket comment <BUG_TICKET_ID> "Classification: behavioral, Score: <N> (<tier>)"`

#### Compound Bug Detection

Before applying the scoring rubric, check whether this ticket describes multiple independent sub-issues.

**Compound bug signals** — the ticket is compound if it lists 2+ of the following that have no shared root cause:
- Distinct error types in different subsystems (e.g., "eval tests fail" AND "hook tests fail")
- Distinct failure modes in unrelated files
- Numbered or bulleted list of 3+ independent failure items

**If compound detected:**
1. Record: `.claude/scripts/dso ticket comment <BUG_TICKET_ID> "Classification: compound bug — <N> independent sub-issues detected: <list>. Routing to cluster investigation."`
2. Route directly to **Cluster Investigation Mode** (see bottom of SKILL.md) — treat sub-issues as separate ticket IDs
3. Skip the standard per-tier single-agent dispatch in Phase C Step 1

**If not compound (single coherent issue):** Continue to scoring rubric below.

## Phase B: Pre-Investigation Gates

### Step 1: Intent Gate (/dso:fix-bug)

Before dispatching the investigation sub-agent, run the intent-search gate to determine whether the bug aligns with system intent.

**CLI_user tag check (pre-check — runs first):**

Check whether this bug was explicitly reported by a user via the `CLI_user` tag. If present, the intent is known and the intent-search agent can be skipped entirely.

```bash
BUG_TAGS=$(.claude/scripts/dso ticket show "$BUG_TICKET_ID" | python3 -c "import json,sys; d=json.load(sys.stdin); print(' '.join(d.get('tags', [])))" 2>/dev/null || echo "")
if echo "$BUG_TAGS" | grep -q "CLI_user"; then
    INTENT_GATE_RESULT="intent-aligned"
    .claude/scripts/dso ticket comment "$BUG_TICKET_ID" "Intent Gate: skipped — CLI_user tag present; intent-aligned assumed"
    # Proceed to Phase B Step 2 / Phase C Step 1 — skip intent-search dispatch below
else
    # CLI_user tag not present — proceed with normal intent-search dispatch
fi
```

If `CLI_user` is present:
- `INTENT_GATE_RESULT` is set to `"intent-aligned"` directly — do NOT dispatch `dso:intent-search`
- A ticket comment records the skip reason
- Proceed to Phase B Step 2 (Feature-Request Gate is skipped since `INTENT_GATE_RESULT` is decisive) and then Phase C Step 1

If `CLI_user` is NOT in the tags (or the tags field is absent — legacy tickets default to empty list, which falls through normally):
- Continue with the normal intent-search dispatch below

**Read budget config:**

```bash
INTENT_SEARCH_BUDGET=$(bash "$PLUGIN_SCRIPTS/read-config.sh" debug.intent_search_budget)  # shim-exempt: internal orchestration script
# Default: 20
```

**Dispatch intent-search agent** per `skills/shared/prompts/named-agent-dispatch.md`. Inputs: `ticket_id: <BUG_TICKET_ID>`, `intent_search_budget: <INTENT_SEARCH_BUDGET>`. The agent returns a gate signal conforming to `docs/contracts/gate-signal-schema.md`.

**Route based on gate signal outcome:**

After the agent returns its signal, record the outcome string for use by Reversal Gate:

```bash
# Set INTENT_GATE_RESULT to "intent-aligned", "intent-contradicting", "ambiguous", or "intent-conflict"
# based on the gate signal outcome field returned by the intent-search agent.
INTENT_GATE_RESULT="<outcome>"   # e.g., "intent-aligned"
```

Intent Gate has four possible outcomes. The **ambiguous** outcome falls through to Feature-Request Gate (feature-request language check via `feature-request-check.py`); the other three outcomes are decisive and skip Feature-Request Gate entirely (see Phase B Step 2 below).

- **intent-aligned** (`triggered: false`, `confidence: high` or `medium`) — The bug is consistent with system intent. Set `INTENT_GATE_RESULT="intent-aligned"`. Proceed directly to Phase C Step 1 (Investigation Sub-Agent Dispatch) without additional dialog.

- **intent-contradicting** (`triggered: true`) — The bug report describes behavior that contradicts system intent. Set `INTENT_GATE_RESULT="intent-contradicting"`. Before closing, inspect the `evidence` field to distinguish two sub-cases:

  **Sub-case A: Working as designed** — Evidence cites an explicit design document, ADR, commit message, or code comment that *justifies* the current behavior (i.e., the feature exists and was deliberately built this way). Auto-close:
  1. Add evidence comment:
     ```bash
     ticket comment <BUG_TICKET_ID> "Intent-contradicting (working as designed): <evidence summary from gate signal>"
     ```
  2. Close ticket with reason:
     ```bash
     ticket transition <BUG_TICKET_ID> in_progress closed --reason="Fixed: Intent-contradicting — <evidence source>"
     ```
  3. **Stop** — do not proceed to investigation.

  **Sub-case B: Feature never implemented** — Evidence indicates the capability was never built (no implementation found, no design doc, no commit). Do NOT auto-close. Escalate to user:
  1. Add evidence comment:
     ```bash
     ticket comment <BUG_TICKET_ID> "Intent Gate: intent-contradicting (feature not implemented) — <evidence summary from gate signal>"
     ```
  2. Present the evidence to the user with three options:
     1. **Close as feature request** — close the bug ticket with `--reason="Fixed: Intent-contradicting — feature not implemented, not a bug"`. Only close if the user explicitly authorizes closure.
     2. **Convert to epic** — invoke `/dso:brainstorm` on the ticket to create a proper feature epic.
     3. **Proceed with investigation** — treat as a genuine bug and continue to Phase C Step 1.
  3. Do NOT close the ticket autonomously. Do NOT implement the feature as a bug fix (per constraint 8204-97b0).
  4. **Stop** — do not proceed to investigation until the user responds.

  **Disambiguation rule**: If the evidence is ambiguous about which sub-case applies, treat as Sub-case B and escalate. Fail toward user dialog when intent cannot be confirmed from explicit artifacts.

- **ambiguous** (`triggered: false`, `confidence: low`) — The intent signal is inconclusive. Set `INTENT_GATE_RESULT="ambiguous"`. Fall through to Feature-Request Gate for further disambiguation before investigation.

- **intent-conflict** (`triggered: true` with `behavioral_claim` and `conflicting_callers` fields present) — The intent-search agent has detected that the ticket's stated behavior conflicts with callers that depend on the current behavior. Set `INTENT_GATE_RESULT="intent-conflict"`. Investigation **PAUSES**. This is a terminal outcome — like `intent-contradicting`, it skips Feature-Request Gate entirely (see Phase B Step 2 below).

  Present the user with the following information from the gate signal:
  - The `behavioral_claim` — what the ticket says should happen (the expected behavior)
  - The `conflicting_callers` list — callers that depend on the current behavior
  - The `dependency_classification` — whether each caller exhibits `behavioral_dependency` or `incidental_usage`

  Offer three resolution options:
  1. **confirm ticket correct** — the ticket's stated behavior is correct; proceed to Phase C Step 1 investigation with the ticket as-is
  2. **confirm current behavior correct** — the current behavior is intentional and callers depend on it; close the ticket (behavior is not a bug)
     ```bash
     ticket comment <BUG_TICKET_ID> "Intent Gate: intent-conflict — current behavior confirmed intentional; <conflicting_callers> depend on it"
     ticket transition <BUG_TICKET_ID> in_progress closed --reason="Fixed: Intent-conflict — current behavior confirmed intentional"
     ```
  3. **revise ticket description** — the ticket description needs updating to reflect the actual desired behavior; user updates ticket text, then re-run Intent Gate

  Do NOT close the ticket autonomously. Do NOT proceed to investigation until the user selects a resolution option.

  **Non-interactive mode** (`FIX_BUG_INTERACTIVE=false`): Do NOT pause for user input. Instead, defer the conflict as an `INTERACTIVITY_DEFERRED` ticket comment and proceed to Phase C Step 1 with the ticket's stated behavior as the safe default:
  ```bash
  ticket comment <BUG_TICKET_ID> "Intent Gate: INTERACTIVITY_DEFERRED — intent-conflict detected (behavioral_claim: <behavioral_claim>; conflicting_callers: <conflicting_callers>; dependency_classification: <dependency_classification>). Proceeding with ticket's stated behavior as default. User must resolve conflict before closing."
  ```
  Then proceed to Phase C Step 1 as if `INTENT_GATE_RESULT="intent-aligned"`.

**Graceful degradation:** If the intent-search agent dispatch fails (timeout, nonzero exit, empty output, or unparseable JSON / malformed signal), treat the result as **ambiguous** (`INTENT_GATE_RESULT="ambiguous"`) and fall through to Feature-Request Gate. Agent failure must never block a legitimate bug investigation. Log the failure via `ticket comment <BUG_TICKET_ID> "Intent Gate: agent failure — treating as ambiguous. Error: <error detail>"`.

**Mechanical fix path**: Bugs routed through the Mechanical Fix Path bypass Phase B Step 1 entirely, so `INTENT_GATE_RESULT` will be unset when Reversal Gate runs. Reversal Gate handles this via the default guard shown in its bash snippet (`INTENT_GATE_RESULT=${INTENT_GATE_RESULT:-}`).

### Step 2: Feature-Request Gate (/dso:fix-bug)

Feature-Request Gate is a **primary** gate that runs ONLY when Intent Gate returns **ambiguous**. It is skipped entirely for `intent-aligned`, `intent-contradicting`, and `intent-conflict` Intent Gate outcomes — those results are decisive and require no further disambiguation.

**When to run**: Only when `INTENT_GATE_RESULT="ambiguous"`. Skip to Phase C Step 1 immediately if `INTENT_GATE_RESULT` is `intent-aligned`, `intent-contradicting`, OR `intent-conflict`.

**How to run**: Pass the bug ticket title and description as a JSON payload via stdin to `feature-request-check.py`:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
FEATURE_REQUEST_GATE_PAYLOAD=$(python3 -c "
import json, sys
payload = {'title': sys.argv[1], 'description': sys.argv[2]}
print(json.dumps(payload))
" "<ticket title>" "<ticket description>")

FEATURE_REQUEST_GATE_OUTPUT=$(echo "$FEATURE_REQUEST_GATE_PAYLOAD" | python3 "$PLUGIN_SCRIPTS/fix-bug/feature-request-check.py")  # shim-exempt: internal orchestration script
```

The script exits 0 always and emits a single JSON gate signal to stdout conforming to `docs/contracts/gate-signal-schema.md`:

```json
{
  "gate_id": "feature_request",
  "signal_type": "primary",
  "triggered": <bool>,
  "evidence": "<string>",
  "confidence": "high" | "medium" | "low"
}
```

**Parsing the gate signal**: Parse the JSON output and route based on `triggered`:

- **`triggered: true`** — Feature-request language detected. Feature-Request Gate is a primary signal — record the evidence and escalate to the user for confirmation before continuing:
  ```bash
  ticket comment <BUG_TICKET_ID> "Feature-Request Gate: feature-request language detected — <evidence from signal>"
  ```
  Present the evidence to the user with three options:
  1. **Close as feature request** — close the bug ticket with `--reason="Fixed: Intent-contradicting — feature request, not bug"`. Only close if the user explicitly authorizes closure.
  2. **Convert to epic** — invoke `/dso:brainstorm` on the ticket to create a proper feature epic. The brainstorm skill handles convert-to-epic flow.
  3. **Proceed with investigation** — treat as a genuine bug and continue to Phase C Step 1.
  
  Do NOT close the ticket autonomously — feature request closure requires explicit user authorization. Do NOT implement the feature as a bug fix (8204-97b0).

- **`triggered: false`** — No feature-request language detected. Proceed directly to Phase C Step 1 (Investigation Sub-Agent Dispatch).

**Graceful degradation:** If `feature-request-check.py` exits nonzero, produces empty stdout, or yields unparseable JSON, treat the result as `triggered: false` and proceed to Phase C Step 1 without blocking. Construct the fallback signal explicitly:

```bash
# On failure, construct a non-blocking fallback signal
FEATURE_REQUEST_GATE_FALLBACK='{"gate_id":"feature_request","signal_type":"primary","triggered":false,"evidence":"Feature-Request Gate script failure — defaulting to non-blocking","confidence":"low"}'
```

Feature-Request Gate failure must never block a legitimate bug investigation.

## Phase C: Investigation

### Step 1: Investigation Sub-Agent Dispatch (/dso:fix-bug)

**You MUST dispatch the investigation sub-agent described below.** Do NOT investigate inline — reading source code, grepping for patterns, running hypothesis commands, or analyzing the bug yourself does not satisfy this step. The sub-agent follows a rigorous investigation template (five whys, hypothesis generation, empirical validation) that prevents confirmation bias. Dispatch the sub-agent, await its RESULT report, then proceed to Phase C Step 2. Do not skip this step even if you have already conducted your own investigation.

**Worktree isolation** (applies to all sub-agent dispatches in this skill): Read and apply `skills/shared/prompts/worktree-dispatch.md`. When `worktree.isolation_enabled=true`, add `isolation: "worktree"` to each Agent dispatch and pass `ORCHESTRATOR_ROOT=$(git rev-parse --show-toplevel)` in the prompt so the sub-agent can verify its isolation. When the config is `false`/absent/empty, omit the isolation parameter (shared-directory fallback). After the sub-agent returns, verify `WORKTREE_PATH != ORCHESTRATOR_ROOT` and follow `skills/shared/prompts/single-agent-integrate.md` to harvest, run post-dispatch gates (review, test-gate, commit), and merge back to the session branch.

Dispatch investigation sub-agents based on the tier determined in Phase A Step 3. All sub-agents receive pre-loaded context before dispatch:
- Existing failing tests and their output
- Stack traces and error messages
- Relevant commit history (`git log --oneline -20 -- <affected-files>`)
- Prior fix attempts from the ticket (if any)

Sub-agents must run existing tests immediately to establish a concrete failure baseline before analyzing code.

#### Structural Dependency Discovery (pre-loading — before sub-agent dispatch)

Before dispatching the investigation sub-agent, use structural search to pre-load callers, importers, and source-chain dependencies of the affected file(s). This discovers the bug's blast radius and gives the investigation sub-agent concrete scope rather than requiring it to re-discover callsites from scratch.

Use `sg` (ast-grep) for syntax-aware structural matching when available — it distinguishes real code references from comments and string literals. Fall back to Grep when `sg` is not installed:

```bash
# Discover callers and importers of the affected module
if command -v sg >/dev/null 2>&1; then
    # Structural search: find files that import or call the affected module
    sg --pattern 'import $MODULE' --lang python <repo_root>
    sg --pattern 'from $MODULE import $_' --lang python <repo_root>
    # For bash/shell scripts, find files that source the affected script
    sg --pattern 'source $PATH' --lang bash <repo_root>
else
    # Fall back to Grep tool or grep command
    grep -r 'import <module_name>' <repo_root>
    grep -r 'from <module_name>' <repo_root>
fi
```

Include the discovered callers, importers, and source-chain dependencies as additional context in the investigation sub-agent prompt. This structural pre-loading step complements the `blast-radius.sh` blast-radius analysis — both use the same `command -v` guard pattern. Note: `blast-radius.sh` checks `command -v ast-grep` (the package name) while new integrations use `command -v sg` (the CLI binary name); see CLAUDE.md "Structural Code Search (ast-grep)" for the canonical naming convention. Blast-Radius Gate (modifier gate: appends blast-radius annotation to escalation context; skips annotation silently on error) runs post-investigation; this step runs pre-dispatch.

#### Dispatch Context (all tiers)

Every investigator agent receives the same base context slots; the orchestrator populates them once and passes them with each dispatch. Tier-specific instructions (techniques, depth, RESULT extensions) are owned by the agent's delta — do not restate them here.

| Slot | Source |
|------|--------|
| `{ticket_id}` | The bug ticket ID (e.g., `w21-xxxx`) |
| `{failing_tests}` | Output of `$TEST_CMD` — failing test names and their output |
| `{stack_trace}` | Stack trace extracted from test output or error logs |
| `{commit_history}` | Output of `git log --oneline -20 -- <affected-files>` |
| `{prior_fix_attempts}` | Ticket notes containing previous fix attempt records (empty string if none) |
| `{escalation_history}` *(ESCALATED only)* | Previous ADVANCED RESULT, discovery file contents, and — for the Empirical Agent — the RESULT reports from the three theoretical lenses |

All agents return RESULT conforming to the Investigation RESULT Report Schema defined below.

#### BASIC Investigation (score < 3)

Dispatch `dso:investigator-basic` (sonnet).

#### INTERMEDIATE Investigation (score 3–5)

Dispatch one opus sub-agent based on availability:

- **Primary** (when `error-debugging:error-detective` is available via `discover-agents.sh`): `dso:investigator-intermediate`
- **Fallback** (general-purpose dispatch path): `dso:investigator-intermediate-fallback`

Investigation depth is identical between the two; only the persona framing differs.

#### ADVANCED Investigation (score ≥ 6)

Dispatch two opus sub-agents concurrently with differentiated lenses (launch both Task calls in one message with `run_in_background: true`, then await both):

- `dso:investigator-advanced-code-tracer` — execution-path / code-evidence lens
- `dso:investigator-advanced-historical` — timeline / change-history lens

##### Convergence Scoring (orchestrator step — after both agents return)

Compare the two `ROOT_CAUSE` fields:

- **Full agreement** (same or semantically equivalent): `convergence_score = 2` — proceed to fix selection with high confidence.
- **Partial agreement** (same subsystem, different specific defect): `convergence_score = 1` — present both in fix approval.
- **Divergence** (no category overlap): `convergence_score = 0` — proceed to fishbone synthesis.

##### Fishbone Synthesis (when convergence_score = 0)

Synthesize findings using the six fishbone categories — Code Logic, State, Configuration, Dependencies, Environment, Data. For each: merge Agent A and Agent B findings, note agreements/disagreements, weight by evidence strength. The synthesized fishbone becomes the unified root cause report for fix approval.

#### ESCALATED Investigation

Triggered when ADVANCED fails to produce a high-confidence root cause. Dispatch four opus sub-agents — three theoretical lenses concurrently first, then the empirical lens with their findings:

- `dso:investigator-escalated-web` — Web Researcher (WebSearch/WebFetch authorized)
- `dso:investigator-escalated-history` — History Analyst
- `dso:investigator-escalated-code-tracer` — deep Code Tracer
- `dso:investigator-escalated-empirical` — Empirical Agent (dispatched after the above three)

**Dispatch sequencing**: Launch the first three concurrently in one message with `run_in_background: true`. Once all three return, dispatch the Empirical Agent with the three theoretical RESULT reports populating `{escalation_history}`.

##### Veto Logic (after all four agents return)



After all four agents return their RESULT reports, evaluate Agent 4's `veto_issued` field:

- **No veto** (`veto_issued: false`): proceed to fix selection with confidence weighted by Agent 4's empirical validation of the agents 1-3 consensus.
- **Veto issued** (`veto_issued: true`): Agent 4's empirical evidence directly contradicts the root cause proposed by the consensus of agents 1-3. The veto supersedes the theoretical analysis. When a veto is issued, dispatch a **resolution agent**.

**Resolution agent dispatch (on veto)**: The resolution agent receives all four RESULT reports, weighs the theoretical evidence from agents 1-3 against the empirical evidence from Agent 4, conducts additional targeted tests to break any remaining tie, and surfaces the highest-confidence conclusion. The resolution agent's conclusion governs fix selection.

##### Terminal Escalation

If ESCALATED investigation (with or without resolution agent) cannot produce a high-confidence root cause, this is the **ESCALATED terminal condition**. Log `ESCALATED terminal — user escalation required` and do NOT attempt any further autonomous fix. Surface all findings to the user:

- All root causes considered with confidence levels
- All fixes attempted with results
- All hypothesis test results
- All RESULT reports from agents 1-4 (and the resolution agent if dispatched)
- Recommendation for manual investigation

### Step 2: Hypothesis Testing (/dso:fix-bug)

For each root cause proposed by Phase C Step 1:
1. Propose a concrete test (bash command, unit test, or assertion) that would **prove or disprove** the suspected root cause
2. Run the test
3. Record the result in the discovery file (see Discovery File Protocol below)

Example:
```bash
# Hypothesis: the config parser silently drops keys with dots
echo '{"a.b": 1}' | python3 -c "import json,sys; d=json.load(sys.stdin); print('a.b' in d)"
# Expected: True (if hypothesis wrong) or False (if hypothesis correct)
```

Tests that confirm a root cause increase confidence. Tests that disprove a root cause eliminate it from consideration.

**Scaffolding test support**: Hypothesis validation tests written during Phase C Step 2 may be kept temporarily as scaffolding to support the fix implementation. If retained:
- Mark the test with a `## Scaffolding Test — remove after fix validation` comment at the top of the test function/block so it is clearly identified as temporary.
- Do NOT register scaffolding tests in `.test-index` with RED markers — they are temporary investigation artifacts, not part of the permanent TDD contract.
- Scaffolding tests must be removed during Phase E Step 4 (fix verification). See Phase E Step 4 for the explicit removal instruction.

### Step 3: Hypothesis Validation Gate (/dso:fix-bug)

Before proceeding to fix approval or fix implementation, validate the `hypothesis_tests` section of the investigation RESULT report.

**Gate logic** (applied after Phase C Step 2 completes):

1. **Check for hypothesis_tests entries**: If the investigation RESULT has no `hypothesis_tests` section, or the section is missing or empty (zero entries), escalate to the next investigation tier. A missing or empty `hypothesis_tests` section means the investigation produced no testable root cause — fix implementation must not proceed without confirmed evidence.

2. **Check for at least one confirmed verdict**: If all `hypothesis_tests` entries have `verdict: disproved` or `verdict: inconclusive` (no `verdict: confirmed` entry exists), escalate to the next investigation tier. All hypotheses being disproved means the true root cause has not been identified — proceeding to fix implementation would be speculative.

3. **Proceed only with confirmed evidence**: If at least one `hypothesis_tests` entry has `verdict: confirmed`, check the `observed` field for evidentiary quality. The `observed` field MUST contain empirical evidence — command output, test results, or concrete observations from running code. It must NOT contain only reasoning, inference, or "based on code reading" explanations. If the `observed` field contains only reasoning without empirical evidence, treat the verdict as `inconclusive` and escalate. Proceed to check 4 below only when the `observed` field contains genuine empirical evidence.

4. **Check hypothesis-root-cause consistency**: The confirmed hypothesis must explain the ROOT_CAUSE identified in the investigation RESULT. If the confirmed hypothesis tests a different aspect than the ROOT_CAUSE (e.g., hypothesis confirms a config value exists but ROOT_CAUSE claims a code logic error), the gate fails — the investigation has confirmed a tangential fact, not the root cause. Escalate to the next investigation tier.

Only when check 4 passes — the confirmed hypothesis directly explains the ROOT_CAUSE — proceed to Phase D Step 1 (Fix Approval).

**Escalation on gate failure**: When the gate rejects the investigation result (missing/empty `hypothesis_tests`, or all disproved), escalate following the standard escalation path (BASIC → INTERMEDIATE → ADVANCED → ESCALATED → User). Include the gate failure reason and all investigation findings in the escalation context so the next tier can build on prior work.

```
GATE_FAILURE_REASON: no_confirmed_hypothesis
current_tier: <BASIC|INTERMEDIATE|ADVANCED|ESCALATED>
hypothesis_tests_count: <number of entries, 0 if missing>
confirmed_count: 0
finding_summary: <brief summary of what the investigation found before gate rejection>
```

Record the gate failure in the discovery file and as a ticket comment before escalating.

## Phase D: Approval & Planning

### Step 1: Fix Approval (/dso:fix-bug)

Determine whether the fix can be auto-approved or requires user input:

- **Auto-approve** if: there is exactly one proposed fix, AND the fix is high confidence + low risk + does not degrade functionality, AND the fix does not modify safeguard files **in any direction** (expansion, reduction, or refactoring of enforcement scope all require user approval), AND the fix does not introduce capabilities, configuration options, or environment variables that were absent from the system before the bug was reported
- **User approval required** if: the fix modifies safeguard files **in any way** — ANY modification including expansions that add new enforcement, reductions that remove enforcement, and refactors that change when enforcement fires are all disqualified from auto-approve. Note: adding new enforcement rules, guard functions, blocked-command patterns, or early-exit conditions to safeguard files counts as a safeguard file modification requiring user approval even when the intent is to strengthen security. OR the fix introduces new capabilities not described in the original bug report — i.e., adds code paths, CLI flags, environment variables, or configuration keys that did not exist before (feature creep — escalate to user; do NOT invoke `/dso:brainstorm` from sub-agent context), OR multiple competing fixes with comparable confidence/risk, OR all fixes degrade functionality, OR confidence is medium or below

When presenting fixes for user approval, display:
- Each proposed fix with description, risk level, and whether it degrades functionality
- Confidence level in each root cause
- Confidence level in each fix
- Results from hypothesis testing (Phase C Step 2) alongside corresponding root causes
- Convergence notes (when multiple agents independently identified the same root cause or fix)

### Step 2: Fix Complexity Evaluation (/dso:fix-bug)

Before writing a RED test or implementing the fix, evaluate the complexity of the proposed fix scope using the complexity-evaluator agent definition:

```
Read: ${CLAUDE_PLUGIN_ROOT}/agents/complexity-evaluator.md
Input: approved fix description, files affected, estimated change scope
```

**Note**: fix-bug reads the complexity-evaluator agent definition inline (rather than dispatching a sub-agent) to avoid nested dispatch — fix-bug often runs as a sub-agent of debug-everything, and dispatching a sub-agent from within a sub-agent risks Critical Rule 23 failures. The agent definition file contains the same five-dimension rubric and classification rules.

**TRIVIAL or MODERATE fix**: proceed to Phase E Step 1 (RED Test).

**COMPLEX classification triggers** (any one is sufficient):
- Fix requires changes to 5+ files across 3+ distinct subsystems (directories)
- Fix requires modifying both a skill/agent definition AND its corresponding script/hook
- Investigation identified 3+ interacting root causes that cannot be addressed independently
- Prior fix attempt failed and the failure analysis indicates the fix scope was too narrow

When ANY trigger fires, classify as COMPLEX — do not rationalize ("these are small changes", "they're all related") to avoid escalation. The triggers exist because past sessions showed agents resolving complex bugs with incomplete fixes that caused regressions.

**COMPLEX fix**: the fix scope is too large for a single bug fix track. The behavior depends on execution context:

**When running as orchestrator (not a sub-agent)**:
1. Record the finding: `ticket comment <BUG_TICKET_ID> "Fix complexity: COMPLEX — escalating to epic"`
2. Invoke `/dso:brainstorm` to create an epic for the refactor or larger change
3. Stop — do NOT proceed to Phase E Step 1 or Phase E Step 3 in this session

**When running as a sub-agent** (detected per Sub-Agent Context Detection below):
1. Record the finding: `ticket comment <BUG_TICKET_ID> "Fix complexity: COMPLEX — returning escalation to orchestrator"`
2. Return a COMPLEX_ESCALATION report to the calling orchestrator instead of invoking `/dso:brainstorm` directly (sub-agents cannot reliably invoke skills):

```
COMPLEX_ESCALATION: true
escalation_type: COMPLEX
bug_id: <ticket-id>
investigation_tier_needed: orchestrator-level re-dispatch
investigation_findings: <summary of root cause candidates, confidence, and evidence from investigation>
escalation_reason: <why the fix is COMPLEX — e.g., cross-system refactor, multiple subsystems affected>
```

Note for the re-dispatched agent (not actionable in the current dispatch): when the fix track resumes, the implementation agent must consult `skills/shared/prompts/prior-art-search.md` before writing any fix code — see the prior-art instruction in Fix Implementation.

3. Stop — do NOT proceed to Phase E Step 1 or Phase E Step 3. The orchestrator receives this report and decides how to proceed (e.g., re-dispatch `/dso:fix-bug` at orchestrator level with full authority, or invoke `/dso:brainstorm` to create an epic).

### Step 3: Testing Mode Classification (/dso:fix-bug)

Before dispatching a RED test or modifying existing tests, classify the fix into one of three testing modes. This determines which Phase E Step 1 path to follow.

**Examine the investigation RESULT root cause and the approved fix description from Phase D Step 1.**

**Classification rules:**

| testing_mode | Condition |
|--------------|-----------|
| `GREEN` | The fix changes implementation without changing observable behavior (e.g., performance optimization, internal restructuring, refactor). Existing tests remain valid and do not need modification. |
| `UPDATE` | The fix changes observable behavior AND existing tests already cover the affected paths — but those tests currently assert the old (buggy) behavior. The existing tests need to be updated to assert the new correct behavior. |
| `RED` | The fix changes observable behavior AND no existing tests cover the affected paths. A new failing test must be written before the fix is applied. |

**Default**: `GREEN` — most bug fixes change implementation rather than observable behavior. Apply this default when the fix is an internal correction that does not alter public-facing outputs, return values, exit codes, or emitted events.

**Emit the classification signal on its own line:**
```
testing_mode=<GREEN|UPDATE|RED>
```

Proceed to the corresponding Phase E Step 1 branch below.

## Phase E: TDD Fix Loop

### Step 1: RED Test (/dso:fix-bug)

**Standard reference**: Load `skills/shared/prompts/behavioral-testing-standard.md` before writing or modifying any test. Apply all five rules (coverage check, observable behavior, execute-don't-inspect, refactoring litmus test, instruction-file structural boundary) to every test written or modified in this step.

If the bug already causes an existing test to fail, skip this step — the existing test serves as the RED test.

**Branch based on `testing_mode` from Phase D Step 3:**

#### testing_mode=GREEN — Skip RED test
The fix changes implementation without changing observable behavior. Existing tests validate fix correctness.

Log: `Testing mode: GREEN — existing tests validate fix correctness. Proceeding to implementation.`

Proceed directly to Phase E Step 3 (Fix Implementation). No RED test is written and the pre-fix gate (Phase E Step 2) is skipped — existing tests validate correctness after the fix is applied.

#### testing_mode=UPDATE — Modify existing tests
The fix changes observable behavior and existing tests cover the affected paths, but they assert old behavior.

1. Identify the existing test(s) that cover the affected behavior.
2. Update those tests to assert the new expected (correct) behavior BEFORE implementing the fix. The updated tests should now fail (they assert the new behavior, but the code still has the bug).
3. Run the updated tests to confirm they fail (RED state).
4. Proceed to Phase E Step 2 using the updated test(s) as the confirmation of the RED state — the gate will verify they are failing before fix dispatch.

#### testing_mode=RED — Dispatch red-test-writer
The fix changes observable behavior and no existing tests cover the affected paths. Write a new failing test before implementing the fix.

### RED Test Dispatch via dso:red-test-writer

Dispatch a task to `dso:red-test-writer` (sonnet) with the bug context (bug description, root cause from investigation, files affected, and the approved fix description from Phase D Step 1).

Parse the leading `TEST_RESULT:` line from the output:

| Result | Action |
|--------|--------|
| `TEST_RESULT:written` | Success. Proceed to Phase E Step 2 using `TEST_FILE` and `RED_ASSERTION` fields. |
| `TEST_RESULT:rejected` | This inline dispatch was the sonnet attempt. On rejection, proceed to **Tier 2** of the escalation protocol in `skills/sprint/prompts/red-task-escalation.md` (skip Tier 1 — already attempted here). `TEST_RESULT:rejected` is **not** an infrastructure failure. See fix-bug verdict mapping below. |
| Timeout / malformed / non-zero exit | Treat as `TEST_RESULT:rejected`. Proceed to Tier 2 of the escalation protocol. |

**Fix-bug verdict mapping** (how escalation verdicts map to fix-bug workflow):
- `VERDICT:CONFIRM` (TDD infeasible) → return to Phase C Step 1 and escalate to the next investigation tier. The bug may require a different fix approach that is testable.
- `VERDICT:REVISE` (task spec insufficient) → re-run investigation (Phase C Step 1) with the evaluator's revision guidance appended to the investigation context.
- `VERDICT:REJECT` (retry at opus) → proceed to Tier 3 per the escalation template.

When `TEST_RESULT:written`, run the new test to confirm it fails (RED):

```bash
# Run the new test to confirm it fails (RED)
$TEST_CMD  # Should see the new test FAIL
```

The test failure should confirm the root cause identified during investigation when possible.

If a previous investigation loop created a RED test for this bug, the existing test may be edited rather than creating a new one — dispatch `dso:red-test-writer` with the existing test file path so it can update rather than create.

**If no RED test can be written** (all three tiers in `red-task-escalation.md` are exhausted): return to Phase C Step 1 and escalate to the next investigation tier. Include the rejection payloads and reasoning with the investigation prompt.

### Step 2: RED-before-fix Gate (/dso:fix-bug)

**Mechanical bug exemption**: This gate does NOT apply to mechanical bugs (import errors, lint violations, config syntax errors, type annotations) routed through the Mechanical Fix Path. Those bugs bypass Steps 2–5 entirely and proceed directly from Phase A Step 3 to a direct fix. The Mechanical Fix Path has no RED test requirement because the fix is deterministic and verified by running `$TEST_CMD` and `$LINT_CMD` after applying it.

Before dispatching any fix implementation (Phase E Step 3), verify that a RED test exists and has been confirmed failing. This gate blocks any code modification — Edit, Write, or fix sub-agent dispatch — until it is satisfied.

**Gate logic** (applied after Phase E Step 1 completes):

1. **Check that a RED test exists**: If Phase E Step 1 was skipped because an existing test was already failing, that test counts as the RED test. If Phase E Step 1 was executed, the new test written there is the RED test.

2. **Check that the RED test has been confirmed failing**: The RED test must have been run and confirmed to fail before fix implementation proceeds. If the test was not run or the run result is not available, run it now:
   ```bash
   $TEST_CMD  # Must show the RED test FAILING
   ```
   If the test does not fail, do NOT proceed to Phase E Step 3. Return to Phase E Step 1 to diagnose why the test passes unexpectedly — this indicates either the test is wrong or the bug is already fixed.

3. **Do not proceed to Phase E Step 3 if the RED test has not been confirmed failing.** Any code modification (Edit, Write, sub-agent fix dispatch) is blocked until the RED test is confirmed failing in a test run output you have observed in this session.

**Gate failure action**: If no RED test can be confirmed failing, do NOT skip to fix implementation. Return to Phase E Step 1 and address why the RED test cannot be confirmed.

**LLM-behavioral bug exemption**: This gate is relaxed for llm-behavioral bugs. LLM behavioral bugs (prompt regressions, agent guidance gaps, skill misinterpretation) cannot always have a traditional executable RED unit test written before the fix — the behavioral regression lives in natural language instructions, not in executable code paths. For llm-behavioral bugs, the RED unit test requirement is replaced with eval-based verification: define an eval assertion that would fail with the current skill/agent/prompt content and pass after the fix. If no eval framework is available, document the behavioral assertion in the ticket as the verification criterion before proceeding to fix implementation.

### Step 3: Fix Implementation (/dso:fix-bug)

**Exploration Decomposition**: During investigation, when a diagnostic question is compound or spans multiple sources (multiple codebase layers, web research, or ambiguous scope), apply the shared exploration decomposition protocol at `skills/shared/prompts/exploration-decomposition.md`. Classify as SINGLE_SOURCE or MULTI_SOURCE. Emit DECOMPOSE_RECOMMENDED when a factor is unspecified or two findings directly contradict.

**Prior-Art Search**: Before dispatching the fix sub-agent, consult the shared prior-art search framework at `skills/shared/prompts/prior-art-search.md`. This ensures the fix approach does not duplicate an existing pattern, introduce an inconsistent abstraction, or miss a reuse opportunity. Apply the Routine Exclusions section of that framework — single-file logic fixes that correct a clear bug without introducing new abstractions are exempt. For fixes that add new helpers, patterns, or abstractions, run at least Tier 1–2 of the tiered search protocol before dispatching the fix sub-agent.

**HARD-GATE**: Before dispatching the fix sub-agent, the orchestrator MUST have a `root_cause_report` produced by the investigation sub-agent Task tool call (Phase C Step 2 / LLM-Behavioral Fix Path). The orchestrating agent may not produce the `root_cause_report` itself — it must come from the prior investigation sub-agent's RESULT output. If no `root_cause_report` is present, do NOT proceed to fix dispatch; return to the appropriate investigation step.

**Exemptions**:
- **mechanical bugs exempt**: Mechanical fix path (syntax errors, import errors, lint violations, config syntax) bypasses the investigation sub-agent entirely. The orchestrator proceeds directly to fix dispatch without requiring a `root_cause_report` from a sub-agent Task call.
- **bot-psychologist path exempt**: When the llm-behavioral classification routes through the `dso:bot-psychologist` agent (LLM-Behavioral Fix Path), the bot-psychologist produces its own structured output. The `root_cause_report` requirement from the standard investigation path does not apply; the bot-psychologist's RESULT serves as the equivalent structured input for the fix sub-agent.

**Classification boundary** (behavioral vs. mechanical):
- *behavioral*: prompt regressions, agent guidance gaps, skill misinterpretation, incorrect model decisions, LLM output drift — requires investigation sub-agent or bot-psychologist
- *mechanical*: import errors, syntax errors, lint violations, config parse errors, missing files — deterministic root cause, no investigation sub-agent required

Launch a sub-agent to implement the approved fix per the worktree-isolation block in this skill's investigation step:
- The sub-agent receives the full investigation RESULT (root cause, confidence, approved fix) as `root_cause_report`
- Change ONLY what is necessary — no refactoring, no scope creep
- One logical change at a time

### Step 4: Verify Fix (/dso:fix-bug)

When `worktree.isolation_enabled=true`, post-dispatch gates (review, test-gate, commit, harvest) are handled by `single-agent-integrate.md` per the worktree-isolation block — proceed directly to commit. When `isolation_enabled=false`, verify that RED tests are now GREEN:

```bash
$TEST_CMD           # RED tests should now PASS
$LINT_CMD           # No lint regressions
$FORMAT_CHECK_CMD   # No format regressions
```

**Scaffolding test cleanup**: If any Phase C Step 2 hypothesis tests were retained as scaffolding (marked with `## Scaffolding Test — remove after fix validation`), remove them now — after the fix is verified GREEN. Do not commit scaffolding tests. Verify `$TEST_CMD` still passes after removal.

**If verification fails**: return to Phase C Step 1 and escalate to the next investigation tier. Include the attempted fix and test results with the investigation prompt.

**If ESCALATED investigation has already been attempted and verification still fails**: this is the terminal **ESCALATED** condition. Surface all findings to the user — do NOT attempt another blind fix. Report:
- All root causes considered with confidence levels
- All fixes attempted with results
- All hypothesis test results
- Recommendation for manual investigation

> **Gate signal parsing (Gates 2a–2d)**: All gate scripts output JSON conforming to `docs/contracts/gate-signal-schema.md`. Parse `triggered` and `signal_type` from stdout. On nonzero exit, empty stdout, or unparseable JSON, construct a fallback: `{"gate_id": "<id>", "triggered": false, "signal_type": "<type>", "evidence": "gate error: <reason>", "confidence": "low"}` and log a warning. Blast-Radius Gate is an exception — see its section for unique handling.

## Phase F: Post-Fix Gates

### Step 1: Scope-Drift Review (/dso:fix-bug)

After Phase E Step 4 (Verify Fix) passes and before running Gates 2a–2d, check whether the implemented fix has drifted outside the original bug's intended scope.

1. **Config check**: Read `scope_drift.enabled` via `read-config.sh`. If `false`, skip Phase F Step 1 and proceed to Reversal Gate.

2. **Agent file existence check (hard-fail)**: Read `agents/scope-drift-reviewer.md` using the Read tool. If the file is not found, ABORT Phase F Step 1 with a clear error message — do NOT silently skip. The scope-drift-reviewer agent must be present for this step to run.

3. **Dispatch** `dso:scope-drift-reviewer` per `skills/shared/prompts/named-agent-dispatch.md`. Inputs:
   - `ticket_text`: original bug ticket description
   - `root_cause_report`: investigation findings from fix approval
   - `git_diff`: output of `git diff` at the current working tree
   - `investigation_files`: list of files identified during investigation

   Set `SCOPE_DRIFT_OUTPUT` from the result.

4. **Three-way routing based on `SCOPE_DRIFT_OUTPUT`**:
   - **No-drift** (`triggered: false`, `drift_classification: in_scope`): proceed to Reversal Gate without friction.
   - **Minor-drift** (`triggered: true`, `drift_classification: ambiguous`): emit a warning to stdout describing the ambiguous scope signal, then proceed to Reversal Gate.
   - **Major-drift** (`triggered: true`, `drift_classification: out_of_scope`): prompt user for explicit approval before proceeding. Present the agent evidence and await a response. Non-interactive mode (`FIX_BUG_INTERACTIVE=false`): defer as an `INTERACTIVITY_DEFERRED` ticket comment and proceed as no-drift.

### Step 2: Post-Fix Gate Family (post-fix gates) (/dso:fix-bug)

After Verify Fix passes and before commit, run the four Post-Fix Gate Family checks. Each emits a JSON signal conforming to `docs/contracts/gate-signal-schema.md`. Three are primary (block on `triggered:true` pending dialog or escalation); 2b is modifier-only (annotates context, never blocks alone). All gates fail-open on error: nonzero exit, empty stdout, or JSON parse failure → construct a fallback `{triggered:false}` signal and proceed.

Populate `AFFECTED_FILES_ARR` once before the gates from the investigation RESULT's `affected_files` field, or from `mapfile -t AFFECTED_FILES_ARR < <(git diff --name-only)`. Guard `INTENT_GATE_RESULT=${INTENT_GATE_RESULT:-}` so the mechanical fix path (which bypasses the Intent Gate) doesn't error.

| gate_id | signal_type | Script | Trigger condition | Intent-Gate-suppression | Notable rules |
|---------|-------------|--------|-------------------|---------------|---------------|
| `reversal` | primary | `reversal-check.sh` | >50% of a recent commit's changed lines are inverted by the proposed fix | Yes — pass `--intent-aligned` when `INTENT_GATE_RESULT=intent-aligned` | Revert-of-revert exemption: when the reversed commit's message matches `^Revert` (case-insensitive), the inversion is an intentional re-application and does not fire |
| `blast_radius` | **modifier** | `blast-radius.sh` | File has a convention match or fan-in > 0 | n/a | Annotation prefix `"Note:"`; appended to dialog context when another primary signal fires; ast-grep preferred (`command -v ast-grep`), grep fallback when absent; never blocks alone |
| `assertion_regression` | primary | `assertion-regression-check.py` (stdin: `git diff` of test dir) | Assertion removal, specificity reduction, weakened matcher, literal→variable, or skip/xfail addition detected | Yes — pass `--intent-aligned` (Intent Gate→Assertion-Regression Gate suppression interaction) | Specific-to-specific value swap (e.g., `assertEqual(x,42)` → `assertEqual(x,57)`) does NOT fire — both literals, specificity preserved |
| `dependency` | primary | `dependency-check.sh` | Fix introduces a dependency not declared in the project manifest and not used elsewhere in the codebase | n/a | Existing-pattern exemption: imports/requires already used elsewhere are pre-existing dependency patterns and do not fire |

**Invocations** (each captures stdout into the corresponding `*_GATE_OUTPUT` env var for the Escalation Routing collector below; all bash calls are `# shim-exempt: internal orchestration script`):

```bash
PLUGIN_SCRIPTS="${CLAUDE_PLUGIN_ROOT}/scripts"
INTENT_GATE_RESULT=${INTENT_GATE_RESULT:-}
REVERSAL_GATE_FLAGS=(); [ "$INTENT_GATE_RESULT" = "intent-aligned" ] && REVERSAL_GATE_FLAGS+=(--intent-aligned)
ASSERTION_REGRESSION_GATE_FLAGS=(); [ "$INTENT_GATE_RESULT" = "intent-aligned" ] && ASSERTION_REGRESSION_GATE_FLAGS+=(--intent-aligned)
TEST_DIR=$(bash "$PLUGIN_SCRIPTS/read-config.sh" test_gate.test_dirs); TEST_DIR=${TEST_DIR:-tests/}  # shim-exempt: internal orchestration script
ASSERTION_REGRESSION_GATE_FLAGS+=(--test-dir "$TEST_DIR")

REVERSAL_GATE_OUTPUT=$(bash "$PLUGIN_SCRIPTS/fix-bug/reversal-check.sh" "${REVERSAL_GATE_FLAGS[@]}" "${AFFECTED_FILES_ARR[@]}" 2>/dev/null)  # shim-exempt: internal orchestration script
BLAST_RADIUS_GATE_OUTPUT=$(bash "$PLUGIN_SCRIPTS/fix-bug/blast-radius.sh" "${AFFECTED_FILES_ARR[@]}" --repo-root "$(git rev-parse --show-toplevel)" 2>/dev/null)  # shim-exempt: internal orchestration script
ASSERTION_REGRESSION_GATE_OUTPUT=$(git diff -- "$TEST_DIR" | python3 "$PLUGIN_SCRIPTS/fix-bug/assertion-regression-check.py" "${ASSERTION_REGRESSION_GATE_FLAGS[@]}" 2>/dev/null)  # shim-exempt: internal orchestration script
DEPENDENCY_GATE_OUTPUT=$(bash "$PLUGIN_SCRIPTS/fix-bug/dependency-check.sh" "${AFFECTED_FILES_ARR[@]}" --repo-root "$(git rev-parse --show-toplevel)" 2>/dev/null)  # shim-exempt: internal orchestration script
```

**On triggered:true (primary gates reversal/assertion_regression/dependency)**: add a primary signal to the gate accumulator; the Escalation Routing step below decides between auto-fix / dialog / escalate based on the count.

**On triggered:true (modifier gate blast_radius)**: append the `evidence` field to the escalation dialog context. Visible only when another primary gate has fired.

### Step 3: Escalation Routing (/dso:fix-bug)

After all gate checks (Gates 1b, 2a, 2b, 2c, and 2d) have run, collect the resulting gate signals and route the fix workflow proportionally based on how many primary gates fired.

**Collect signals and run the router**: `route-escalation.sh` reads each gate output from env vars (filters malformed/empty silently — fail-open) and emits the router's routing JSON. Pass `--complex` when the complexity evaluator (in the approval phase) returned `COMPLEX`.

```bash
COMPLEX_FLAG=""
[ "${FIX_COMPLEXITY:-}" = "COMPLEX" ] && COMPLEX_FLAG="--complex"
ROUTING_OUTPUT=$(FEATURE_REQUEST_GATE_OUTPUT="$FEATURE_REQUEST_GATE_OUTPUT" REVERSAL_GATE_OUTPUT="$REVERSAL_GATE_OUTPUT" \
                 BLAST_RADIUS_GATE_OUTPUT="$BLAST_RADIUS_GATE_OUTPUT" ASSERTION_REGRESSION_GATE_OUTPUT="$ASSERTION_REGRESSION_GATE_OUTPUT" \
                 DEPENDENCY_GATE_OUTPUT="$DEPENDENCY_GATE_OUTPUT" SCOPE_DRIFT_OUTPUT="${SCOPE_DRIFT_OUTPUT:-}" \
                 bash "$PLUGIN_SCRIPTS/fix-bug/route-escalation.sh" $COMPLEX_FLAG)  # shim-exempt: internal orchestration script
ROUTE=$(echo "$ROUTING_OUTPUT" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('route','auto-fix'))" 2>/dev/null || echo "auto-fix")
```

The router exits 0 always (fail-open). `dialog` is only emitted when exactly 1 primary signal fires; infrastructure errors do NOT trigger `dialog` — they default to `auto-fix`.

**Routing table**:

| Route | Condition | Action |
|-------|-----------|--------|
| `auto-fix` | 0 primary signals triggered (and not COMPLEX) | Proceed to Phase H Step 1 without any dialog |
| `dialog` | Exactly 1 primary signal triggered | Prompt 1-2 inline questions with blast radius annotation from Blast-Radius Gate if available |
| `escalate` | 2+ primary signals triggered, OR COMPLEX classification | Escalate to `/dso:brainstorm` with all gate evidence |

**Route: `auto-fix`** — no primary gates fired. Proceed directly to Phase H Step 1 without pausing for user input.

**Route: `dialog`** — one primary gate fired. Ask 1-2 focused inline questions (the exact questions are scoped to the fired gate's evidence). If Blast-Radius Gate blast radius annotation is available in `dialog_context.modifier_evidence`, include it in the question framing so the user understands the affected surface. After the dialog answers are recorded, proceed to Phase H Step 1.

**Route: `escalate`** — 2 or more primary signals fired, or COMPLEX classification was returned. Do not proceed to Phase H Step 1. Instead:

1. Record the escalation finding:
   ```bash
   ticket comment <BUG_TICKET_ID> "Escalation routing: route=escalate — $(echo $ROUTING_OUTPUT | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(str(d.get(\"signal_count\",\"?\")) + \" primary signals, reason: \" + d.get(\"reason\",\"multi-signal escalation\"))')"
   ```
2. Invoke `/dso:brainstorm` with all gate evidence — this converts the fix into a tracked epic for proper planning and scoping.
3. Stop — do NOT proceed to Phase H Step 1 in this session.

**COMPLEX always escalates**: The `--complex` flag forces `route: "escalate"` regardless of primary signal count. Even 0 primary signals + COMPLEX classification results in epic escalation. This ensures that fix scopes evaluated as COMPLEX by the complexity evaluator (Phase D Step 2) always receive epic-level treatment.

**Interactivity integration**: When fix-bug runs in non-interactive mode (set by `/dso:debug-everything`'s interactivity flag), the `dialog` path cannot block for user input. In non-interactive mode, defer the dialog as an `INTERACTIVITY_DEFERRED` ticket comment and proceed to Phase H Step 1 as if `auto-fix`:

```bash
if [ "${FIX_BUG_INTERACTIVE:-true}" = "false" ] && [ "$ROUTE" = "dialog" ]; then
    ticket comment <BUG_TICKET_ID> "INTERACTIVITY_DEFERRED: 1 primary gate signal — dialog deferred (non-interactive mode). Gate evidence: $(echo $ROUTING_OUTPUT | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); ctx=d.get(\"dialog_context\") or {}; print(ctx.get(\"signal\",{}).get(\"evidence\",\"no evidence\"))')"
    ROUTE="auto-fix"
fi
```

When `route: "escalate"` and non-interactive mode, defer the epic escalation as a comment and stop:

```bash
if [ "${FIX_BUG_INTERACTIVE:-true}" = "false" ] && [ "$ROUTE" = "escalate" ]; then
    ticket comment <BUG_TICKET_ID> "INTERACTIVITY_DEFERRED: escalation to /dso:brainstorm deferred (non-interactive mode). Signal count: $(echo $ROUTING_OUTPUT | python3 -c 'import json,sys; print(json.loads(sys.stdin.read()).get(\"signal_count\",\"?\"))'). All gate evidence attached to this ticket for follow-up."
    # Stop — do not proceed to Phase H Step 1; escalation must be handled interactively.
    exit 0
fi
```


## Phase G: Anti-Pattern Sweep & Test Index

### Step 1: Anti-Pattern Scan (/dso:fix-bug)

After the fix is verified GREEN (Phase E Step 4) and all Gate 2 checks pass, scan the codebase for other occurrences of the confirmed root cause pattern. This step prevents the same class of bug from lurking in other files.

**Pre-condition**: All RED tests must be GREEN before proceeding. Do not begin the anti-pattern scan until Phase E Step 4 verification passes — GREEN before commit is required. Phase G Step 1 also runs after Phase F Step 1 scope-drift review has passed (or was skipped via `scope_drift.enabled=false`).

**When to run**: After Gate routing resolves to `auto-fix` or `dialog` (not `escalate`). When route is `escalate`, skip this step — the scope has been handed off to `/dso:brainstorm`.

**CLI_user tag**: Never apply `--tags CLI_user` to tickets created by this step. Anti-pattern discoveries are autonomous, not user-requested. The `CLI_user` tag is reserved exclusively for bugs that a human explicitly asked the agent to file.

#### Dispatch Scan Sub-Agent

Dispatch `prompts/anti-pattern-scan.md` as a sub-agent with the confirmed root cause pattern, reference file, and pattern description from the investigation results:

```
sub-agent: prompts/anti-pattern-scan.md
inputs:
  root_cause_pattern: <confirmed root cause pattern from investigation>
  reference_file:     <the source file that was fixed>
  pattern_description: <one-sentence description of the anti-pattern>
```

Wait for the `SCAN_RESULT` output before proceeding.

#### Handle Empty Scan Result

If the scan returns `total_confirmed: 0` (zero confirmed candidates), record the empty scan result and proceed immediately to Phase H Step 1 — no candidates to fix, no sub-agents to dispatch:

```bash
ticket comment <BUG_TICKET_ID> "Anti-pattern scan: no candidates found (zero confirmed occurrences outside the fixed file). Proceeding to commit."
```

Skip the remaining sub-steps and proceed to Phase H Step 1.

#### Group Candidates by File

Parse the `SCAN_RESULT` candidates list. Group confirmed candidates by file — multiple occurrences in the same file are handled by a single fix sub-agent (same-file grouping as defined in `prompts/anti-pattern-fix-batch.md`).

Build the dispatch list:

```
dispatch_list:
  - agent: prompts/anti-pattern-fix-batch.md
    assigned_files: [file1.py, file2.py]   # same-file grouping
  - agent: prompts/anti-pattern-fix-batch.md
    assigned_files: [file3.py]
  ...
```

#### Dispatch Fix Sub-Agents Using MAX_AGENTS Protocol

Before dispatching fix sub-agents, run the shared pre-batch check to determine the dynamic batch size:

```bash
$PLUGIN_SCRIPTS/agent-batch-lifecycle.sh pre-check  # shim-exempt: internal orchestration script
```

The script outputs structured key-value pairs:
- `MAX_AGENTS: 0 | 1 | 5 | unlimited` — use as `max_agents`
- `SESSION_USAGE: normal | high`
- `GIT_CLEAN: true | false` — if false, commit previous batch first

**MAX_AGENTS handling**:
- `MAX_AGENTS: unlimited` — dispatch ALL fix agents in a single batch with no cap. Do not artificially limit to 5 or any other number.
- `MAX_AGENTS: 5` — dispatch fix agents in batches capped at the returned value.
- `MAX_AGENTS: 1` — dispatch fix agents one at a time (session usage is high).
- `MAX_AGENTS: 0` — skip sub-agent dispatch entirely. Log: `"MAX_AGENTS=0, skipping fix sub-agent dispatch."` and proceed to the Observation Tracking subsection of Phase G Step 1.

Each fix sub-agent receives:

- `pattern_summary` — from the SCAN_RESULT
- `root_cause` — from the investigation
- `reference_fix` — the fix applied to the original bug
- `assigned_files` — its assigned file(s)
- `occurrences` — the confirmed occurrences for its assigned files

**Commit between batches**: After each batch of fix sub-agents completes, commit the results following `docs/workflows/COMMIT-WORKFLOW.md` (including review) before dispatching the next batch. This prevents lost work if a subsequent batch fails.

```
for each batch of up to max_agents fix agents:
  1. Run pre-batch check: agent-batch-lifecycle.sh pre-check
  2. If MAX_AGENTS=0, skip dispatch and proceed to the Observation Tracking subsection of Phase G Step 1
  3. Dispatch up to max_agents agents concurrently (each with `run_in_background: true`)
  4. Collect BATCH_RESULT from each agent
  5. Commit between batches following COMMIT-WORKFLOW.md
  6. Proceed to next batch
```

If a batch returns `batch_status: FAILED` or `PARTIAL`, record findings as a bug ticket (`.claude/scripts/dso ticket create bug "[Component]: [Condition] -> [Observed Result]" -d "## Incident Overview ..." --parent=<EPIC_ID>` — follow `skills/create-bug/SKILL.md` format) and proceed to the next batch — do not block the entire scan on a single failing batch. Do NOT use `--tags CLI_user` for these tickets — they are autonomously-discovered defects identified by the anti-pattern scan, not bugs reported by the user during an interactive session.

#### Observation Tracking (Dogfooding)

Record the scan outcome in the bug ticket for dogfooding purposes. After at least 5 sessions of fix-bug execution, the observations accumulated across sessions provide data for refining the anti-pattern detection heuristics.

```bash
ticket comment <BUG_TICKET_ID> "Anti-pattern scan complete: <total_confirmed> confirmed candidates, <N_fixed> fixed across <N_batches> batches. Observation: <one sentence on what the scan found or why it was clean>."
```

This observation record feeds dogfooding analysis — tracking which patterns recur across sessions helps identify systemic issues in the codebase.

### Step 2: Test Index Check (/dso:fix-bug)

After the fix is verified GREEN and before committing, check whether the source file(s) modified by the fix have entries in `.test-index`. This prevents future regression detection gaps where the test gate cannot associate a source file with its test.

**When to run**: After Phase G Step 1 (Anti-Pattern Scan) completes or is skipped. Skip this step if no RED test was written in Phase E Step 1 (i.e., an existing test already covered the bug).

**Check logic**:

1. For each source file modified by the fix, check whether it has an entry in `.test-index`:
   ```bash
   REPO_ROOT=$(git rev-parse --show-toplevel)
   TEST_INDEX="$REPO_ROOT/.test-index"
   if [ -f "$TEST_INDEX" ]; then
       for src_file in <modified_source_files>; do
           if ! grep -q "^${src_file}:" "$TEST_INDEX" 2>/dev/null; then
               echo "MISSING: $src_file has no .test-index entry"
           fi
       done
   fi
   ```

2. **If an entry is missing AND a RED test was written in Phase E Step 1**: check whether the test file name is fuzzy-matchable to the source file (i.e., the normalized source basename is a substring of the normalized test basename). If fuzzy matching would find the test, no `.test-index` entry is needed — the test gate will discover it automatically.

3. **If an entry is missing AND the test name is NOT fuzzy-matchable**: add a `.test-index` entry mapping the source file to its test file:
   ```
   source/path.ext: test/path.ext
   ```
   This ensures the test gate enforces the source-test association on future commits.

4. **If `.test-index` does not exist**: skip this step. The project may not use `.test-index`-based test discovery.

## Phase H: Commit and Close

### Step 1: Commit and Close (/dso:fix-bug)

**NEVER close a bug with reason `Escalated to user:` unless the user has explicitly authorized closure in this interactive session (i.e., the user said "close this ticket").** When no code fix is possible, add investigation findings as a ticket comment and leave the ticket OPEN — closing removes it from `ticket list` visibility. Surface unfixable bugs in the session summary instead.

**When running as orchestrator (not a sub-agent)**:

> **CRITICAL — Review invocation**: COMMIT-WORKFLOW.md Step 5 handles the DSO review gate internally. NEVER invoke `Skill("review")` or the bare `/review` command — these trigger the built-in Claude Code PR-review skill, NOT the DSO code reviewer (`/dso:review`). The only valid review invocation is to read and execute `${CLAUDE_PLUGIN_ROOT}/docs/workflows/COMMIT-WORKFLOW.md` inline (which calls REVIEW-WORKFLOW.md at Step 5). Do NOT call `Skill("review")`, `/review`, or `/dso:review` directly from fix-bug.

1. Complete the commit workflow per `${CLAUDE_PLUGIN_ROOT}/docs/workflows/COMMIT-WORKFLOW.md`.
2. Close the bug ticket only after a successful code fix:
   ```bash
   ticket transition <BUG_TICKET_ID> in_progress closed --reason="Fixed: <one-line summary of the fix>"
   ```

**When running as a sub-agent** (detected per Sub-Agent Context Detection below):

1. Do NOT commit — the orchestrator owns the commit workflow.
2. Do NOT close the ticket — the orchestrator handles ticket lifecycle after the sub-agent returns.
3. Return the resolved ticket ID in the sub-agent result so the orchestrator can commit and close:

```
FIX_RESULT: resolved
BUG_TICKET_ID: <ticket-id>
fix_summary: <one-line description of what was fixed>
files_changed: <comma-separated list of modified files>
```

If the bug CANNOT be fixed (all investigation tiers exhausted, COMPLEX escalation, LLM-behavioral with no testable surface, etc.), return the unresolved signal instead — do NOT close the ticket:

```
FIX_RESULT: unresolved
BUG_TICKET_ID: <ticket-id>
reason: <why it could not be fixed — e.g., COMPLEX escalation, ESCALATED terminal condition, LLM-behavioral without testable surface>
investigation_summary: <brief findings to preserve for the user>
```

The orchestrator receiving `FIX_RESULT: unresolved` MUST:
1. Add a comment to the ticket: `.claude/scripts/dso ticket comment <id> "Investigated: <investigation_summary> — could not fix. <reason>"`
2. Leave the ticket **OPEN** — do NOT transition to closed, do NOT use `--reason="Escalated to user:"` autonomously
3. Surface the ticket in the session summary under **ESCALATED BUGS** so the user sees it

The orchestrator receives this result and is responsible for committing the changes and closing the ticket (when resolved) or leaving it open (when unresolved).

## Cluster Investigation Mode

When invoked with multiple bug IDs, `/dso:fix-bug` operates in cluster invocation mode: it investigates all bugs as a single problem before deciding whether to proceed as one track or split.

### Cluster Invocation

```
/dso:fix-bug <id1> <id2> [<id3> ...]
```

Pass two or more ticket IDs to trigger cluster mode. All listed bugs are investigated together using the prompt template at `prompts/cluster-investigation.md`.

### Cluster Scoring

The cluster is scored using the highest individual score across all bugs in the cluster (conservative rule — treats the cluster as the most complex bug it contains). This determines the investigation tier for the single unified dispatch.

### Single-Problem Investigation

All bugs in the cluster are investigated as a single problem. A single investigation sub-agent is dispatched (at the tier determined by the highest-scoring bug) with the full context for every bug in the cluster. The sub-agent determines whether one root cause explains all symptoms or whether multiple independent root causes are present.

### Root-Cause-Based Splitting

After the cluster investigation completes:

- **Single root cause**: if one root cause explains all bugs, proceed as a single fix track from Phase C Step 2 onward.
- **Multiple independent root causes**: if the investigation identifies multiple independent root causes, split into one per-root-cause track. Each track follows the standard single-bug workflow from Phase C Step 2 onward.

Split tracks are independent — they may be worked in parallel or sequentially depending on resource availability.

## Investigation RESULT Report Schema

All investigation tiers produce a RESULT report with this schema. Higher tiers include additional fields.

```
ROOT_CAUSE: <one sentence describing the identified root cause>
confidence: high | medium | low
proposed_fixes:
  - description: <what the fix does>
    risk: high | medium | low
    degrades_functionality: true | false
    rationale: <why this fix addresses the root cause>
hypothesis_tests:
  - hypothesis: <what was tested>
    test: <the test command>
    observed: <what actually happened>
    verdict: confirmed | disproved | inconclusive
prior_attempts:
  - commit: <sha>
    description: <what was tried>
    outcome: <why it failed>
```

INTERMEDIATE and above add:
```
alternative_fixes: [...]  # at least 2 total proposals
tradeoffs_considered: <analysis of approach tradeoffs>
recommendation: <which fix and why>
```

ADVANCED adds:
```
convergence_score: <how many agents agreed on this root cause>
fishbone_categories:
  code_logic: <findings>
  state: <findings>
  configuration: <findings>
  dependencies: <findings>
  environment: <findings>
  data: <findings>
```

## Discovery File Protocol

Investigation findings are persisted to a discovery file for passing context between phases (investigation to fix, or across escalation tiers).

- **Path convention**: `/tmp/fix-bug-discovery-<ticket-id>.json`
- **Required fields**:
  - `root_cause` — one-sentence root cause description
  - `confidence` — high, medium, or low
  - `proposed_fixes` — array of fix proposals (each with description, risk, degrades_functionality)
  - `hypothesis_tests` — array of hypothesis test results
  - `prior_fix_attempts` — array of previous fix attempts (empty if none)
- **Written by**: investigation sub-agents (Phase C Step 1) and hypothesis testing (Phase C Step 2)
- **Read by**: fix approval (Phase D Step 1), fix implementation (Phase E Step 3), and escalation re-entry (Phase C Step 1 on retry)
- **Lifecycle**: created at first investigation, updated on escalation, deleted after successful commit (Phase H Step 1)

When escalating to the next tier, the discovery file from the previous tier is included in the new sub-agent's context so it does not repeat work.

## Sub-Agent Context Detection

When `/dso:fix-bug` is invoked inside a larger workflow (e.g., from `/dso:sprint` or `/dso:debug-everything`), it runs as a sub-agent. Sub-agent context affects which investigation tiers are available.

### Re-entry from COMPLEX_ESCALATION

When the invocation prompt contains a `### COMPLEX_ESCALATION Context` block (emitted by `/dso:debug-everything` Phase H Step 8 during orchestrator-level re-dispatch), skip Steps 1-3 and proceed directly to Phase D Step 1 (Fix Approval):

1. Parse the `investigation_findings` from the `COMPLEX_ESCALATION Context` block
2. Write the findings to the discovery file (`/tmp/fix-bug-discovery-<bug-id>.json`) with the parsed root cause, confidence, and proposed fixes
3. Skip to Phase D Step 1 (Fix Approval) — the prior investigation is pre-loaded and does not need to be repeated

This avoids re-running classification and investigation work that was already completed by the sub-agent before escalation.

### Detection Methods

**Primary — Agent tool availability**: Before dispatching investigation sub-agents, check whether the Agent tool is available in the current context. If the Agent tool is not available, the skill is running as a sub-agent (dispatched via the Task tool) and must surface findings to the caller instead of escalating.

**Fallback — orchestrator signal**: The orchestrator may also set `You are running as a sub-agent` in the dispatch prompt. When present, this confirms sub-agent context.

### Behavior in Sub-Agent Context

Behavior is owned by the relevant phases — see ticket lifecycle (Phase A Step 2), COMPLEX_ESCALATION report on complex fixes (Phase D Step 2), commit and close / FIX_RESULT report (Phase H Step 1). Investigation tier degradation: BASIC and INTERMEDIATE work fully nested; ADVANCED and ESCALATED require Agent tool availability — if unavailable, return a `COMPLEX_ESCALATION` report (see below) so the calling orchestrator can re-dispatch with full authority.

### Escalation Report Format

When running as a sub-agent and ADVANCED or ESCALATED investigation is needed but cannot be performed due to Agent tool unavailability or other blocking conditions, return a `COMPLEX_ESCALATION` report to the calling orchestrator. This uses the same format as Phase D Step 2's COMPLEX_ESCALATION — one unified format for all escalation paths:

```
COMPLEX_ESCALATION: true
escalation_type: advanced_needed | escalated_needed | terminal
bug_id: <ticket-id>
investigation_tier_needed: ADVANCED | ESCALATED
investigation_findings: <summary of root cause candidates, confidence, evidence, and hypothesis test results from investigation>
escalation_reason: <why escalation is needed and cannot proceed autonomously>
```

The calling orchestrator detects `COMPLEX_ESCALATION: true` and parses the same fields regardless of whether the escalation originated from complexity evaluation (Phase D Step 2) or tier unavailability (this section). See `/dso:debug-everything` Phase H Step 8 for the orchestrator's handling of this signal.

---

**Reminder:** Use /dso:fix-bug when you need to fix or resolve a bug. Do not investigate or attempt to fix bugs without using /dso:fix-bug.

