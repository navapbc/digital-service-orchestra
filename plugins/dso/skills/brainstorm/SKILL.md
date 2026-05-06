---
name: brainstorm
description: Use when starting a new feature or epic — turns an idea into a defined, ticket-ready epic through Socratic dialogue, approach design, and milestone spec creation.
user-invocable: true
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
---

<SUB-AGENT-GUARD>
Requires Agent tool. If running as a sub-agent (Agent tool unavailable), STOP and return: "ERROR: /dso:brainstorm requires Agent tool; invoke from orchestrator."
</SUB-AGENT-GUARD>

# Brainstorm: Feature to Epic

You are a Principal Product Manager at USDS. Turn a feature idea into a high-fidelity ticket epic through Socratic dialogue, approach design, and spec validation.

<HARD-GATE>
Do NOT invoke /dso:sprint, /dso:preplanning, /dso:implementation-plan, or write any code until Phase 3 is complete and the user has explicitly approved the epic spec. This applies regardless of how simple the feature seems.
</HARD-GATE>

<ANTI-REDUNDANCY-GATE>
Before forming any question — across all phases — you MUST:

1. **Semantic duplicate check**: Review all prior conversation turns. Do NOT ask any question whose answer was already given, including answers expressed through paraphrase, negative signals ("I told you", "I answered that"), or semantically-equivalent rewordings of prior responses.

2. **Codebase check**: Before asking a question whose answer may live in the repo, use Read, Grep, or Glob to look first. Only ask if the answer is not discoverable from code.

3. **Probe suppression**: When a prior user answer covers one of the UX probe topics (criticality — interaction criticality; non_happy_path — non-happy-path state coverage; flow_entry_exit — flow entry/exit points), skip that probe. Do not re-ask what the user has already addressed.

**Duplicate questions are prohibited.**
</ANTI-REDUNDANCY-GATE>

## Layout

This skill's logic is split across phase files to keep per-invocation context small. Load each file on demand:

| File | When to read |
|------|--------------|
| `phases/convert-to-epic.md` | Type Detection Gate Option (a) |
| `phases/enrich-in-place.md` | Type Detection Gate Option (b) |
| `phases/cross-epic-handlers.md` | Step 2.25 returns non-benign signals |
| `phases/post-scrutiny-handlers.md` | After scrutiny pipeline returns (main flow) |
| `phases/approval-gate.md` | Phase 2 Step 4 |
| `phases/follow-on-epic-gate.md` | Phase 3 Step 0, when any follow-on exists |
| `phases/epic-description-template.md` | Phase 3 Step 1 ticket write |
| `../shared/prompts/verifiable-sc-check.md` | Drafting each SC in Phase 2 Step 2 |
| `prompts/ui-keyword-trigger.md` | Step 1.5 UI Intent Detection — keyword scan, config override, classifier stub |
| `prompts/ui-detection-classifier.md` | Step 1.5 UI Intent Detection — classifier dispatch prompt |
| `prompts/ux-probe-set.md` | Step 1.5 UI Intent Detection — structured UX probe set |

## Migration Check

Idempotently apply plugin-shipped ticket migrations (marker-gated; no-op once migrated):

```bash
PLUGIN_SCRIPTS="${CLAUDE_PLUGIN_ROOT}/scripts"
bash "$PLUGIN_SCRIPTS/ticket-migrate-brainstorm-tags.sh" 2>/dev/null || true  # shim-exempt: internal orchestration script
```

## Usage

```
/dso:brainstorm                    # Start with a blank slate — describe the feature interactively
/dso:brainstorm <ticket-id>          # Enrich an existing underdefined ticket
```

When invoked with a free-text description (argument present but does not match the ticket ID format `[a-z0-9]{4}-[a-z0-9]{4}`), treat the argument as seeding context and immediately begin the Socratic dialogue at Phase 1. Do NOT show the epic selection list. Open with: *"Got it — I'll use that as our starting point. Let me ask a few questions to sharpen the scope."* then proceed to Phase 1 Step 2 with the user's text as the established problem statement seed.

When invoked without a ticket ID or description, emit the candidate selection list:

```bash
.claude/scripts/dso ticket list-epics --brainstorm
```

The script emits a numbered list with two labeled categories — **Zero-child epics** (not yet decomposed) and **Scrutiny-gap epics** (decomposed, not yet brainstormed; i.e., children ≥ 1 without the `brainstorm:complete` tag) — plus a trailing "start fresh" option. Wait for the user to choose:

- **Existing epic**: proceed as if invoked with that epic's ticket ID (see Type Detection Gate below).
- **"Start fresh"** (or both categories empty): open with *"What feature or capability are you trying to build?"* and start the Socratic dialogue at Phase 1.

When invoked with a ticket ID, check the ticket type (Type Detection Gate below).

---

## Type Detection Gate

**Run this gate for every invocation that includes a `<ticket-id>` argument.**

### Step 1 — Check the ticket type

```bash
.claude/scripts/dso ticket show <ticket-id>
```

Read the `ticket_type` field.

### Step 2 — Route based on ticket type

**`ticket_type == epic`**: Load the epic, summarize what's already defined, then proceed to Phase 1 unchanged. The epic dialogue and output behavior is semantically unchanged — the Type Detection check is pre-flight only.

**`ticket_type != epic`** (i.e., `story`, `task`, or `bug`): Present:

```
This ticket is a <story|task|bug>, not an epic. How would you like to proceed?

(a) Convert to epic — close the original ticket as superseded and run the full brainstorm flow
    to create a new, well-defined epic from the ideas in this ticket.

(b) Enrich in-place — run a streamlined enrichment dialogue to flesh out this ticket's
    description, success criteria, and approach without converting it to an epic.
```

- **Option (a)**: Read the Convert-to-Epic Path at `phases/convert-to-epic.md` and follow it.
- **Option (b)**: Read the Enrich-in-Place Path at `phases/enrich-in-place.md` and follow it.

---

## Phase 1: Context + Socratic Dialogue

**Goal**: Understand the feature well enough to propose 2–3 implementation approaches.

### Step 0: Load Scale Inference Protocol

Read `shared/prompts/scale-inference.md`. If the file cannot be read, STOP and emit:
"ERROR: scale-inference.md not found at skills/shared/prompts/scale-inference.md — create this file before running brainstorm."

**Scale inference trigger**: If the feature description implies a volume-sensitive decision — such as processing records, serving traffic, querying a data store, handling concurrent users, storing user-generated content, or running background jobs — apply the 3-step inference protocol from scale-inference.md:

1. Check existing artifacts (PRD, design notes, ticket descriptions) for numeric estimates.
2. Run a domain web search to find published benchmarks or typical figures for the context.
3. Ask the user only if no usable estimate is found in steps 1 or 2.

Record the result as the session's **scale context**: a numeric estimate, "small scale", or "not applicable". This value is written to the approval-time log as the `scale_context` field.

### Step 1: Load Existing Context

Before asking any questions, silently scan for context:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
cat "$REPO_ROOT/PRD.md" 2>/dev/null || cat "$REPO_ROOT/docs/PRD.md" 2>/dev/null
cat "$REPO_ROOT/.claude/design-notes.md" 2>/dev/null
.claude/scripts/dso ticket list --type=epic
# Resolve session context silently — never ask the user about CWD, repo identity, or ticket-store location
git remote get-url origin 2>/dev/null
git rev-parse --show-toplevel 2>/dev/null
```

If a PRD or `.claude/design-notes.md` exists, open with a brief summary of what you already know, then probe deeper rather than starting from scratch.

### Codebase Investigation Gate (Mandatory Before Any User Question)

Before presenting ANY question to the user, you MUST first check whether the answer is discoverable by reading the codebase. Read existing skill files (sprint SKILL.md, fix-bug SKILL.md), ARCH_ENFORCEMENT.md, pyproject.toml, project-understanding.md, and relevant scripts/module structure. Only ask the user questions whose answers cannot be found in the repo. Questions about design approach, user experience preferences, or business priorities are appropriate for the user; questions about existing implementations, available tools, or project structure are NOT — find those answers yourself first.

**Exploration decomposition**: When a context question is compound or spans multiple sources (web research, multiple codebase layers, ambiguous scope), apply the shared exploration decomposition protocol at `skills/shared/prompts/exploration-decomposition.md` to classify it as SINGLE_SOURCE or MULTI_SOURCE before proceeding. Emit DECOMPOSE_RECOMMENDED when a factor is unspecified or two findings contradict.

### Step 2: The "Tell Me More" Loop

<HARD-GATE>
Before sending any user-facing message in this dialogue: count the distinct questions in your draft. If the count is greater than 1, stop — select only the single highest-priority unknown and remove all others. A message with two numbered questions, two lettered choices on different topics, or one main question plus a follow-up sub-question ALL violate this rule. No exception exists for "quick context checks" or efficiency arguments.
</HARD-GATE>

Ask **one question at a time**. Use *"Tell me more about [concept]..."* to encourage depth. After each answer, either ask a follow-up or move to the next area.

**Before forming each question**: Check whether the answer is already in the codebase. DO NOT ask questions whose answers are discoverable by reading the repo — find those answers yourself first using Read, Grep, or Glob. Only surface questions that require genuine user knowledge (design intent, business priorities, user experience preferences).

**Prefer multiple-choice questions** over open-ended when possible. Option labels MUST use single ASCII letters (`a`, `b`, `c`, `d`) or single digits (`1`, `2`, `3`, `4`) — never Greek letters (`α`, `β`, `γ`), Roman numerals (`i`, `ii`, `iii`), or any multi-character label. These require special-character input or multi-character typing, creating friction for users who just want to type their choice. Bug 0f10-97ec: Greek and Roman numeral labels break keyboard-first UX.

**Probe until you understand:**

| Area | Questions to ask |
|------|-----------------|
| Problem | What specific user problem does this solve? What happens today without this feature? |
| Users | Who needs this — which user type, role, or persona? |
| Value | What business outcome or user improvement does this enable? |
| Scope | What's clearly in scope? What are you explicitly NOT building? |
| Access Path | If this feature creates a new page or UI surface: how will users reach it? (global nav link, in-flow step, modal trigger, deep link, or not applicable?) |
| Constraints | Any technical constraints, deadlines, or dependencies on other epics? |
| Surface | Where does this feature manifest? (web page, form, screen, CLI flag, endpoint, background job, internal API, migration, or "no user-facing surface") |
| Success | How will you know this worked? What would "done" look like? |

**Do not ask all of these at once.** Pick the most important unknown and ask one question.

### Phase 1 Gate

Transition to Phase 2 via this 3-step sequence.

**Step 1 — Understanding Summary**: Produce a structured summary and wait for user confirmation before gap analysis.

```
Before we move to approaches, here's my understanding:

- **Problem**: [what specific problem this solves]
- **Users**: [who is affected — user type, role, or persona]
- **Scope**: [what's in scope; what's explicitly out of scope]
- **Access Path**: [if this feature creates a new page or UI surface: how will users reach it? (global nav link, in-flow step, modal trigger, deep link, or not applicable)] *(omit if feature does not introduce a new page or UI surface)*
- **Surface**: [where the feature manifests]
- **Success**: [how the user will know this worked — observable outcome]

Does this capture your intent? If anything is off, tell me what to adjust.
```

**Scope bullet validation (required before presenting this summary)**: Every bullet under **Scope** must name a concrete deliverable or a confirmed exclusion. A bullet is invalid if it contains any of these patterns: "verify whether", "check if", "TBD", "outcome is no changes", or "depends on investigation". If a scope item cannot be stated as a concrete in/out decision, either (a) investigate silently now and resolve it, OR (b) ask one more Socratic question to resolve it before presenting the summary, OR (c) move it to a **Pending Investigation** bullet clearly separated from the in-scope list. Do NOT carry unresolved research tasks into the in-scope list.

#### Understanding Summary Phrasing Requirement

Close the Understanding Summary with exactly this sentence: **"Does this capture your intent? If anything is off, tell me what to adjust."** Do not paraphrase — this exact phrasing is a standardized closing, not an example.

Wait for confirmation before proceeding to Step 2.

**Phase 1 Gate Step 1.5 — UI Intent Detection**: Immediately after the Understanding Summary is confirmed, assess whether the feature is UI-facing.

**Setup**: Resolve the artifacts directory before accessing the sentinel:
```bash
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/deps.sh"
ARTIFACTS_DIR=$(get_artifacts_dir)
mkdir -p "$ARTIFACTS_DIR"
```

1. **Re-invocation guard**: Check whether `$ARTIFACTS_DIR/ux-probe-fired-<epic-id>` sentinel file exists. If the sentinel file exists (flag set from a prior brainstorm run for this epic), skip the rest of this step — probes already fired for this epic.
2. **Keyword scan**: Read `${CLAUDE_PLUGIN_ROOT}/skills/brainstorm/prompts/ui-keyword-trigger.md`. Test the confirmed Understanding Summary text against the active surface-lexicon (the default lexicon from `ui-keyword-trigger.md`, or the `brainstorm.ui_keywords` override from `dso-config.conf` which REPLACES the default lexicon entirely). Result: `clear-ui`, `clear-non-ui`, or `ambiguous`.
3. **Classifier dispatch** (ambiguous matches only):
   - First check the `BRAINSTORM_UI_CLASSIFIER_STUB` env var. If set to `ui`, `non-ui`, or `fail`, short-circuit to that result immediately (test/mock path — do not dispatch a real classifier).
   - Otherwise dispatch a haiku classifier sub-agent per `${CLAUDE_PLUGIN_ROOT}/skills/brainstorm/prompts/ui-detection-classifier.md`.
   - On any failure (agent unavailable, MAX_AGENTS=0, timeout, malformed output, or any response other than exactly `"ui"` or `"non-ui"`): log a degradation notice to the user, treat result as `non-ui`, and continue. The `ux_probe_fired` flag is NOT set on failure so a later successful run can still fire the probes.
**Non-interactive path**: When `BRAINSTORM_INTERACTIVE=false` and the UI detection result is `ui`: emit `INTERACTIVITY_DEFERRED: UX probes require user input`, tag the epic `ui_probes:deferred` (`.claude/scripts/dso ticket tag <epic-id> ui_probes:deferred`), and skip all probes. Do NOT set the `ux_probe_fired` sentinel — a subsequent interactive run must still fire them. Phase 1 gap list gaps sourced from UX probes are deferred via the ui_probes:deferred tag; Phase 1 terminates without looping. Proceed to Step 2.

4. **Probe firing** (when result is `ui` AND flag is unset):
   - Ask the three free-text follow-up probes from `${CLAUDE_PLUGIN_ROOT}/skills/brainstorm/prompts/ux-probe-set.md` one at a time.
   - After all three probes are answered, write the sentinel file: `$ARTIFACTS_DIR/ux-probe-fired-<epic-id>` containing an ISO-8601 timestamp. This prevents re-firing on subsequent brainstorm invocations for the same epic.
5. **Non-UI fast-path**: When result is `clear-non-ui` from the keyword scan, skip probes entirely. Zero classifier calls are dispatched.

**Step 2 — Intent Gap Analysis**: After confirmation, self-reflect on inferred or assumed content — items you filled in that the user did not explicitly state. Use targeted questions, one at a time, starting with the highest-priority gap. Exclude already-confirmed content.

Format for the **first** gap question (includes the skip option):
```
Before I propose approaches: [Targeted gap question]

(You can say "proceed" at any point to skip remaining questions and move to approaches)
```

Format for **subsequent** gap questions (no skip prompt):
```
Before I propose approaches: [Targeted gap question]
```

**Loop-back directive**: When a gap answer reveals a new understanding gap — one that genuinely increases epic understanding — return to the Tell Me More loop (Step 2) before resuming gap analysis. This applies equally to gaps surfaced by the UX probe checkpoint (any probe from the structured probe set by dimension ID: criticality, non_happy_path, flow_entry_exit) and to gaps surfaced by the intent gap analysis itself. **Non-interactive exception**: When `BRAINSTORM_INTERACTIVE=false`, do not loop back on UX-probe-sourced gaps — Phase 1 terminates with the gaps deferred (signaled via `ui_probes:deferred` tag set in Step 1.5).

**Termination condition**: Proceed to Phase 2 only when BOTH: (a) the gap list is empty (no remaining inferred/assumed items) AND (b) the user confirms the Understanding Summary in the same turn. No numeric cap is applied — the anti-redundancy directive bounds the loop in practice. If the user says "proceed", treat this as user-initiated early termination: the user is confirming acceptance of the current Understanding Summary with any remaining gaps deferred, satisfying condition (b) as a user override; proceed to Phase 2 immediately.

**UNRESOLVABLE_INTENT_GAP escape**: When the anti-redundancy directive suppresses every candidate question during loop-back (all remaining gaps would duplicate questions already asked), record `UNRESOLVABLE_INTENT_GAP` as a comment on the epic ticket (`.claude/scripts/dso ticket comment <epic-id> "UNRESOLVABLE_INTENT_GAP: <reason>"`), inform the user that no further gap questions can be generated without repetition, and terminate Phase 1 (do NOT proceed to Phase 2). The user must re-invoke `/dso:brainstorm` or manually confirm intent to proceed.

**Compression anti-pattern (prohibited)**: Do NOT reframe N independent decisions as a single "core question" with N sub-options or sub-lists. If your draft contains "Rather than asking", "Instead of asking", or more than one decision sub-list under one heading, STOP — split into separate sequential questions. Each question must cover exactly one independent axis.

Do NOT proceed to Phase 2 until the user confirms the understanding summary or explicitly skips the gap analysis.

### Step 3 — Shape Heuristic Scan (config-gated)

**Config gate**: Source `${CLAUDE_PLUGIN_ROOT}/hooks/lib/planning-config.sh` and call `is_external_dep_block_enabled`. If the function returns exit 1, skip this sub-step and proceed to Phase 2.

**When enabled:**

1. For each Success Criterion in the Understanding Summary, pipe the SC text to `classify-sc-shape.sh`:
   ```bash
   result=$(echo "<sc-text>" | .claude/scripts/dso brainstorm/classify-sc-shape.sh)
   ```

2. If any SC returns `external-outcome`:
   - Run the classification dialogue: ask the user to specify `ownership`, `handling` (`claude_auto` or `user_manual`), `claude_has_access`, and (optionally) `verification_command` for each external-outcome dependency.
   - Warn if `verification_command` runs destructive operations (deletes, writes to production).
   - Render the External Dependencies block in the epic description per `${CLAUDE_PLUGIN_ROOT}/docs/contracts/external-dependencies-block.md`.

3. **Release-infrastructure compatibility check (3dc2-ad99)**: Regardless of SC shape classification, if the epic introduces a new Python package (e.g., `litellm`, any `pip install` or `pyproject.toml` addition) or changes that will eventually be exercised at release time (new CI job, new validation step, changed plugin entry point), flag `scripts/release.sh` as a release-infrastructure dependency. Note in the epic description: "Release dependency: scripts/release.sh must be updated to account for [new package/change] before this epic can ship via the stable release channel." This dependency is NOT captured by the `external-outcome` shape classifier (it's an internal script, not an external service) — so it must be checked explicitly here.

4. If no SC returns `external-outcome` and the release-infrastructure check is negative: skip block rendering.

---

## Phase 2: Approach + Spec Definition

**Goal**: Agree on an approach and produce a high-fidelity epic spec.

### Step 0: Load Complexity Gate

Read `shared/prompts/complexity-gate.md`. If the file cannot be read, STOP and emit:
"ERROR: complexity-gate.md not found at skills/shared/prompts/complexity-gate.md — create this file before running brainstorm Phase 2."

### Step 1: Propose Approaches

Present at least 3 distinct implementation approaches with trade-offs, including at least one genuine simple baseline — the simplest implementation that satisfies all done definitions. **Lead with your recommended approach** and explain why.

**Simple baseline requirement**: The simple baseline must be a viable implementation for the current scope. The Sandbagging Prohibition from `shared/prompts/complexity-gate.md` applies: do not load the simple baseline description with scalability caveats unless those caveats are grounded in the Phase 1 scale context. A technically inadequate option is not a valid simple baseline.

**Complexity gate for proposals**: Any proposal that includes (a) a new library dependency, (b) a performance optimization, or (c) an abstraction with fewer than 3 existing call sites must include a GATE/CHECKED/FINDING/VERDICT block (format in `shared/prompts/complexity-gate.md`). If the verdict is FAIL and no justified-complexity path is provided, remove the proposal or revise it.

**Scale context propagation**: Pass the Phase 1 scale context to Gate 4 (Scale Threshold) when evaluating performance proposals. If Phase 1 scale context was "small scale (default)", Gate 4 returns FAIL for any performance optimization unless the justified-complexity path is satisfied.

Format each approach:
```
**Option A: [Name]** ← Recommended
[2-3 sentence description]
Pros: ...
Cons: ...

**Option B: [Name]**
[2-3 sentence description]
Pros: ...
Cons: ...
```

Apply YAGNI ruthlessly — don't include approaches that are clearly overkill for the scope described.

Ask: *"Which direction resonates? Or is there a different approach you'd prefer?"*

Wait for the user to choose before proceeding.

### Step 2: Draft the Epic Spec

Using the chosen approach and the Phase 1 dialogue, draft the epic spec:

```
## Context
[2-4 sentence narrative: who is affected, what problem they face today, why this matters now]

## Success Criteria
- [Specific, observable outcome — what a user sees or does, not what code does]
- [...]

## Dependencies
[Any other epics that must be completed first, or "None"]
```

**Success criteria rules:**
- 3–6 criteria per epic
- Each must be verifiable pass/fail
- Each must be verifiable within the sprint session — the pass/fail verdict must be renderable before the sprint closes
- Apply the **verifiable-SC check** at `shared/prompts/verifiable-sc-check.md` to every drafted SC (session-infeasible SCs are prohibited from the verifiable SC list; "post-deployment" is fine if the verdict is renderable in the closing session via a deterministic command — only SCs requiring days/weeks of telemetry, dogfooding, or accumulated baselines are filtered; remediation options: rewrite as verifiable proxy, or tag as `DEFERRED_MEASUREMENT`)
- Describe outcomes, not implementation ("Users can download results as CSV" not "Implement CSV export endpoint")
- At least one criterion should hint at a validation signal — how you'll know the capability is actually being used
- **Executable-artifact rule**: When the epic produces an executable artifact whose runtime environment cannot be reproduced locally (CI workflows, GitHub Actions, scheduled jobs, deploy pipelines, webhook handlers, hosted endpoints), include at least one SC that exercises the artifact end-to-end in one of: (a) an integration test against the real environment, (b) a non-blocking / shadow landing on the project followed by an in-session green-run check, or (c) a live invocation against the real or a throwaway target. Spike findings on a *different* artifact (even one that uses the same underlying API) do NOT satisfy this rule — the unit of verification is the actual artifact being shipped.
- **Superseding or closing another epic is NEVER an SC.** Ticket bookkeeping (closing superseded epics, re-parenting children, updating links) is executed as post-creation work in Phase 3 after `ticket create` returns the new epic ID. Including it as an SC conflates the epic's delivered outcome with the workflow step that records the outcome — the `ticket transition` call is a side-effect of scope consolidation, not a criterion a reviewer can pass or fail the epic against. When a supersede is part of the scope, record it in the Phase 3 bookkeeping plan; do not list it under `## Success Criteria`.

**Context narrative rules:**
- Name the specific user or stakeholder affected
- Describe the problem they face today (without this feature)
- Avoid jargon without explanation

### Provenance Tracking

As you draft the epic spec, classify the origin of each SC and key context claim:

- **explicit** — stated directly by the user in their own words
- **confirmed-via-gap-question** — inferred by you, then confirmed during gap analysis (Phase 1 Gate Step 2)
- **inferred** — derived by you from context without explicit user confirmation
- **researched** — sourced from web research or external reference material (Step 2.6)
- **injected** — derived from a cross-epic interaction scan (consideration-level signal); applied before the scrutiny pipeline and rendered as bold at the approval gate

Track provenance internally — the approval gate (Step 4) uses these categories for annotation.

### Step 2.25: Cross-Epic Interaction Scan

<HARD-GATE>
DISPATCH the `dso:cross-epic-interaction-classifier` haiku sub-agent via `skills/brainstorm/prompts/cross-epic-scan.md`. Do NOT perform inline triage. The following are NOT substitutes for dispatching the sub-agent:
- Reading the epic list yourself and pattern-matching titles
- Keyword filtering ("skill", "onboarding", "init", "claude.md", "architect", etc.) against title text
- Reasoning "the interactions are obvious" or "I'll log a rationale for skipping"
- Surfacing a curated subset of epics to the user without classifier signals

Inline triage misses semantic overlaps (descriptions, SCs, approach blocks) that the classifier reads via `ticket show`. If you are tempted to skip the dispatch, treat that temptation as a signal to dispatch immediately. Record as SKIPPED only if the epic list returns 0 epics (no open/in-progress epics exist).
</HARD-GATE>

Read and execute `skills/brainstorm/prompts/cross-epic-scan.md` with the current approach and success criteria as input. This dispatches haiku-tier classifiers against all open/in-progress epics to detect shared-resource conflicts.

Route signals by severity:
- **benign**: log; proceed directly to Step 2.5
- **consideration**: read `phases/cross-epic-handlers.md` and execute Step 2.26 (AC injection) → check for ambiguity/conflict → Step 2.5
- **ambiguity** or **conflict**: read `phases/cross-epic-handlers.md` and execute Step 2.27 (halt/resolution) before Step 2.5

### Steps 2.5, 2.6, 2.75, Step 3: Epic Scrutiny Pipeline

Read and execute `skills/shared/workflows/epic-scrutiny-pipeline.md`. Pass the current epic spec as input, with:

- `{caller_name}` = `brainstorm`
- `{caller_prompts_dir}` = `skills/brainstorm/prompts`

#### Step 2.5 Supplement: Gap Analysis + ast-grep Discovery

**Gap analysis reminder**: The pipeline's Step 2.5 cross-references user-named artifacts — file paths, CLI tools, data structures, API endpoints, config keys — against the success criteria text. For each user-named artifact, check whether it appears directly or by fuzzy/partial match (including abbreviations, aliases, and variant phrasing) in any SC. Flag any artifact named in the request that is absent from or not covered by the SCs, then ask the user whether the SCs are exhaustive.

**During Part B (Technical Approach Self-Review)**, use `sg` (ast-grep) for structural pattern matching when discovering existing codebase patterns. Guard:

```bash
if command -v sg >/dev/null 2>&1; then
    sg --pattern '<pattern>' --lang <lang> /path/to/search
else
    grep -r '<pattern>' /path/to/search
fi
```

Use for: validating whether the proposed approach conflicts with existing patterns; checking whether an assumed dependency is already imported; tracing bidirectional data flow to detect sync loops or race conditions. If neither produces results, log the pattern and continue.

#### Post-Scrutiny Handlers

After the pipeline returns, read `phases/post-scrutiny-handlers.md` and execute in order:

1. FEASIBILITY_GAP Handler (may branch back to Phase 1 or escalate)
2. Research Findings Persistence
3. SC Gap Check
4. Step 2.28 — Relates-to AC Injection (see `phases/cross-epic-handlers.md`)

### Step 4: Approval Gate

<HARD-GATE>
Before reading approval-gate.md: Red Team, Blue Team, and all three fidelity reviewers must have run as dispatched sub-agent calls. Valid exemptions: ≤2 SCs (scenario skipped), no integration signals (feasibility skipped). Inline reasoning does not count as dispatch. Dispatch any missing agents now.
</HARD-GATE>

Read and execute `phases/approval-gate.md`. On approval, proceed to Phase 3.

---

## Phase 3: Ticket Integration

**Goal**: Create the epic in the ticket system and hand off to the next step.

**Clean-text requirement**: Strip all provenance markers and bold emphasis before writing the final epic spec — the ticket description must be written as plain text, without the approval-gate annotations used during review.

### Step 0: Follow-on and Derivative Epic Gate

If any follow-on or derivative epic exists (scope reviewer recommended a split, user made a directional statement about a future epic, or you identified a related epic during Phase 1/2): read `phases/follow-on-epic-gate.md` and execute the gate for each follow-on before proceeding to Step 1.

### Step 1: Create or Update the Epic

Read `phases/epic-description-template.md` for the canonical description template and invocation. **Clean-text requirement**: strip all provenance markers and bold emphasis before writing the final ticket description — the epic spec is written as plain text without the approval-gate annotations.

- **Existing epic ID passed as input** (Type Detection Gate identified `ticket_type: epic`): use `ticket edit --description` — do NOT call `ticket create`.
- **No existing epic** (new brainstorm or arrived via Convert-to-Epic): use `ticket create epic ... -d ...` with priority determined by `shared/prompts/value-effort-scorer.md`.

### Step 2: Set Dependencies

If the epic depends on others identified in Phase 1:

```bash
.claude/scripts/dso ticket link <this-epic-id> <blocking-epic-id> depends_on
```

### Step 3: Validate Ticket Health

```bash
.claude/scripts/dso validate-issues.sh --quick --terse
```

Fix any issues before finalizing.

### Step 3a: Write brainstorm:complete Tag

Write a durable ticket-level tag to record that brainstorm has completed. This removes any `scrutiny:pending` tag while preserving all other existing tags (e.g., `design:approved`, `CLI_user`).

<HARD-GATE>
Run `preconditions-record.sh` FIRST — BEFORE the tag commands. The tag commands without the preconditions record leave downstream skills (preplanning, sprint) unable to verify brainstorm completed, causing PRECONDITIONS_GATE_BLOCKED failures. This call MUST be executed even if it seems redundant, even if the epic already has brainstorm:complete, and even if preconditions were recorded earlier in a prior session. The `|| true` is intentional (non-fatal) — run it regardless.
</HARD-GATE>

```bash
# MANDATORY: Record brainstorm preconditions baseline BEFORE tagging complete.
# Skipping this causes PRECONDITIONS_GATE_BLOCKED in preplanning/sprint.
.claude/scripts/dso preconditions-record.sh \
  --ticket-id "$epic_id" \
  --gate-name "brainstorm_complete" \
  --session-id "${SESSION_ID:-unknown}" \
  --tier "minimal" 2>/dev/null || true

.claude/scripts/dso ticket untag <epic-id> scrutiny:pending
.claude/scripts/dso ticket tag <epic-id> brainstorm:complete
```

### Step 3b: Write Brainstorm Completion Sentinel

Write a sentinel file to record that brainstorm has completed for this session. This file is checked by the `EnterPlanMode` PreToolUse hook to enforce brainstorm-before-plan-mode.

```bash
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/deps.sh"
ARTIFACTS_DIR=$(get_artifacts_dir)
echo "brainstorm-complete" > "$ARTIFACTS_DIR/brainstorm-sentinel"
```

This must be the last Phase 3 action before downstream skill invocation.

### Step 4: Invoke Preplanning

After the epic is created and ticket health passes, classify the epic's complexity before invoking `/dso:preplanning`.

#### Step 4a: Dispatch Complexity Evaluator Agent

Dispatch the dedicated complexity evaluator agent. Read `agents/complexity-evaluator.md` inline and dispatch as `subagent_type: "general-purpose"` with `model: "haiku"`. Pass the epic ID as the argument and `tier_schema=SIMPLE`. (`dso:complexity-evaluator` is an agent file identifier, NOT a valid `subagent_type` — the Agent tool only accepts built-in types.)

```
Agent tool:
  subagent_type: "general-purpose"
  model: "haiku"
  argument: <epic-id>
  context:
    tier_schema: SIMPLE
    success_criteria_count: <count of SC bullet items in the approved spec from Phase 2>
    scenario_survivor_count: <count of scenarios surviving blue team filter from Step 2.75, or 0 if Step 2.75 did not run>
```

Compute `success_criteria_count` from the `## Success Criteria` section. Read `scenario_survivor_count` from the Planning-Intelligence Log (or 0 if the pipeline did not run scenario analysis).

If the agent fails or returns malformed JSON, log a warning and fall through to full `/dso:preplanning` (safe fallback).

#### Step 4b: Route Based on Classification

Apply the routing table below. **Always consult the table** — do NOT skip preplanning based on prose heuristics. Only TRIVIAL epics bypass preplanning.

**Session-signal override** (applies before the routing table): If EITHER is true, override to COMPLEX regardless of evaluator output:
- `success_criteria_count ≥ 7` — count from the spec text (do NOT rely on session memory which may be lost after compaction)
- `scenario_survivor_count ≥ 10` — read from the Planning-Intelligence Log, or re-count from the `## Scenario Analysis` section

Log the override: `"Epic classified as COMPLEX (session-signal override: <reason>) — invoking /dso:preplanning"`

| Classification | scope_certainty | Routing |
|---|---|---|
| TRIVIAL | High (always) | `/dso:implementation-plan <epic-id>` |
| MODERATE | High | `/dso:preplanning <epic-id> --lightweight` |
| MODERATE | Medium | `/dso:preplanning <epic-id> --lightweight` |
| MODERATE | Low | Promoted to COMPLEX by evaluator |
| COMPLEX | any | `/dso:preplanning <epic-id>` (full mode) |

**Rationale**: TRIVIAL epics route directly to `/dso:implementation-plan` — the brainstorm dialogue produced task-level detail. MODERATE+High routes to `--lightweight` to run a risk/scope scan and write structured done definitions before implementation planning. MODERATE+Low is converted to COMPLEX by the evaluator (row listed for completeness). COMPLEX epics require full story decomposition.

#### Step 4c: Invoke Next Skill

Output the classification line and invoke the Skill tool **in the same response** — do not yield to the user:

```
Epic classified as <TIER> (scope_certainty: <HIGH|MEDIUM|LOW>) — invoking /<skill> [mode]
```

Then immediately (same response, no pause):

```
# TRIVIAL:
Skill tool:
  skill: "dso:implementation-plan"
  args: "<epic-id>"

# MODERATE + scope_certainty High or Medium:
Skill tool:
  skill: "dso:preplanning"
  args: "<epic-id> --lightweight"

# COMPLEX:
Skill tool:
  skill: "dso:preplanning"
  args: "<epic-id>"
```

Control returns here only if the invoked skill escalates.

---

## Guardrails

**One question at a time** — never present multiple questions in a single message.

**YAGNI ruthlessly** — if a capability isn't clearly needed for the stated goal, don't include it.

**Outcomes over outputs** — success criteria describe what users see and do, not what code does.

**Approaches before spec** — always propose 2–3 options and get a choice before drafting the spec.

**Fidelity gate** — the spec must pass all reviewer dimensions before presenting to the user.

**No child tasks** — this skill creates the epic only. Stories and tasks are created by `/dso:preplanning`.

---

## Quick Reference

| Phase | Goal | Key Activities |
|-------|------|---------------|
| 1: Context + Dialogue | Understand the feature | Load PRD/design-notes, one question at a time, Tell-me-more loop; Phase 1 Gate (Understanding Summary → Intent Gap Analysis → Phase 2). Config-gated: External Dependencies shape heuristic + classification dialogue. |
| 2: Approach + Spec | Define how and what | Propose 2–3 options; draft spec with provenance tracking; apply `verifiable-sc-check.md` per SC; Step 2.25 cross-epic scan → `phases/cross-epic-handlers.md` on non-benign signals; scrutiny pipeline (2.5/2.6/2.75/3) → `phases/post-scrutiny-handlers.md`; Step 4 approval gate (`phases/approval-gate.md`). |
| 3: Ticket Integration | Create epic; classify; route | Follow-on gate (`phases/follow-on-epic-gate.md`); create/update via `phases/epic-description-template.md`; set deps; validate; `brainstorm:complete` tag + sentinel; complexity-evaluator (haiku, tier_schema=SIMPLE); session-signal override (SC≥7 or scenarios≥10 → COMPLEX); route: TRIVIAL → `/dso:implementation-plan`, MODERATE → `/dso:preplanning --lightweight`, COMPLEX → `/dso:preplanning`. |
