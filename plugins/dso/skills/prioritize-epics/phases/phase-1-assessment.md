# Phase 1: Project Assessment

**Goal**: Build enough shared understanding of the backlog, the overall vision, the current state, and the risk landscape to run a high-fidelity prioritization in Phase 3 and 4.

This phase does NOT assign priorities (with one explicit exception: user-declared out-of-scope epics in Step 2). It gathers the inputs the rubric (Phase 2) and sorter (Phase 3, 4) need.

## Step 1 — Clarity review (sub-agent)

Dispatch ONE sub-agent (sonnet) using the prompt in `prompts/epic-clarity-review.md`. Pass it the list of all open epics:

```bash
.claude/scripts/dso ticket list --type=epic --status=open,in_progress --format=llm
```

The sub-agent returns a JSON object:

```json
{
  "unclear_epics": [
    {"id": "abcd-1234", "title": "...", "reason": "<1-sentence reason it cannot be prioritized as-is>"}
  ]
}
```

**Important**: An epic that has not completed brainstorming and lacks verbose description text may still be clear enough to prioritize. The bar is "can we tell, at a high level, what value this delivers and whether it aligns with the project's direction?" — NOT "is this ready to be worked on?". The sub-agent prompt enforces this distinction.

Display the returned list to the user briefly:

> *"I found N epics that need a quick clarification before I can prioritize them confidently. I'll ask about each one. If any are currently out of scope, just say so and we'll mark them P4."*

If `unclear_epics` is empty, skip to Step 3.

## Step 2 — Per-epic Socratic clarification loop

For each epic in `unclear_epics`, run this loop:

1. Read the epic in full: `.claude/scripts/dso ticket show <id>`.
2. Open with a brief framing: *"Epic `<id>`: '<title>'. <reason from clarity review>."*
3. Enter a Socratic loop, asking **exactly one question per turn**:
   - The goal is high confidence that you understand what value this epic delivers, who it serves, and roughly how it fits into the overall project — enough to compare it against a future North Star and decide North Star / optional / out-of-scope.
   - The goal is **NOT** full readiness to work on it. Resist drift toward acceptance criteria, implementation detail, or estimation.
   - Stop the loop when EITHER: (a) you have high confidence in the prioritization-level understanding, OR (b) the user says the epic is currently out of scope.

3a. **Out of scope branch**: If the user declares the epic out of scope, set priority to P4 only if it is not already P4 (skip the write otherwise to avoid spurious ticket events). Parse the JSON with `python3` rather than `jq` — this project enforces a jq-free convention:

```bash
CURRENT=$(.claude/scripts/dso ticket show --format=llm <id> \
  | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('pr',''))")
if [ "$CURRENT" != "4" ]; then
  .claude/scripts/dso ticket edit <id> --priority=4
fi
```

Add `<id>` to `OUT_OF_SCOPE_IDS`. Move to the next epic. Do NOT write a clarification comment in this branch — `OUT_OF_SCOPE_IDS` is the durable record.

3b. **High confidence branch**: When you believe you understand enough to prioritize:

- Compose a 2–4 sentence summary of the understanding (problem, users, value, rough scope).
- Present it to the user verbatim and ask: *"Does this capture it? Approve and I'll add it as a comment on the epic."*
- On user approval, write the comment:

```bash
.claude/scripts/dso ticket comment <id> "Prioritization clarification (Phase 1, /dso:prioritize-epics):

<2-4 sentence summary>"
```

- Add `<id>` to `CLARIFIED_IDS`. Move to the next epic.
- If the user pushes back, refine the summary and re-ask. Do not write the comment until approved.

## Step 3 — Vision summary (sub-agent)

Dispatch ONE sub-agent (sonnet) using the prompt in `prompts/vision-summary.md`. Pass it the full open-epic list (including any newly written Phase 1 Step 2 comments). The sub-agent returns:

```json
{
  "vision_summary": "<3-6 sentence narrative of the overall vision the open epics collectively describe>",
  "themes": ["<theme 1>", "<theme 2>", "..."]
}
```

Store as `VISION_SUMMARY`. Show it to the user as context — do NOT ask for approval yet (the rubric in Phase 2 is what gets approved; this is input to that conversation).

## Step 4 — State vs. vision gap analysis (sub-agent)

Dispatch ONE sub-agent (sonnet) using the prompt in `prompts/vision-gap.md`. Pass:

- The `VISION_SUMMARY` from Step 3.
- A quick snapshot of current project state: top-level repo layout (`ls`), the most recently modified directories, and any README/PRD/design-notes files the sub-agent can find.

The sub-agent returns:

```json
{
  "gap_summary": "<3-6 sentence description of how far the current codebase is from the vision>",
  "notable_gaps": ["<gap 1>", "<gap 2>", "..."],
  "notable_progress": ["<progress 1>", "..."]
}
```

Store as `STATE_VS_VISION_GAP`.

## Step 5 — Risk hotspot review (sub-agent)

Dispatch ONE sub-agent (sonnet) using the prompt in `prompts/risk-hotspots.md`. The sub-agent inspects:

- Open bug tickets: `.claude/scripts/dso ticket list --type=bug --status=open,in_progress --format=llm`
- Recent commit history (last ~200 commits): `git log --oneline -200`
- File churn: `git log --since="6 months ago" --name-only --pretty=format: | sort | uniq -c | sort -rn | head -30`

It returns:

```json
{
  "hotspots": [
    {"area": "<path or component>", "evidence": "<why this is hot>", "implication_for_prioritization": "<1 sentence>"}
  ],
  "summary": "<2-3 sentence overall risk summary>"
}
```

Store as `RISK_HOTSPOTS`.

## Phase 1 Output

After all five steps complete, present a compact summary to the user:

```
=== Phase 1 Complete ===

Backlog assessed:
- N open epics reviewed
- M needed clarification (now commented): <ids>
- K marked out of scope (set to P4): <ids>

Vision summary:
<VISION_SUMMARY.vision_summary>

State vs. vision gap:
<STATE_VS_VISION_GAP.gap_summary>

Risk hotspots:
<RISK_HOTSPOTS.summary>

PHASE GATE QUESTION:
Ready to move into the stakeholder interview to set the prioritization rubric?

Do NOT proceed until user responds.
```
