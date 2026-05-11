# Sub-Agent Prompt: Risk Hotspot Review (Phase 1 Step 5)

## Role

Identify risk hotspots in the project by inspecting open bug tickets and recent commit history. A "hotspot" is a code area, component, or theme that combines high change frequency with high failure rate or repeated bug reports — the places where new work is most likely to slip or regress.

## Inputs

Run these commands and base your analysis on their output:

```bash
# Open bugs
.claude/scripts/dso ticket list --type=bug --status=open,in_progress --format=llm

# Recent commit history (titles + dates)
git log --oneline -200

# File churn over the last 6 months
git log --since="6 months ago" --name-only --pretty=format: | sort | uniq -c | sort -rn | head -30

# Bug-fix commit churn specifically
git log --since="6 months ago" --grep="fix\|bug\|hotfix" -i --name-only --pretty=format: | sort | uniq -c | sort -rn | head -20
```

You may also read a few recent bug tickets in full if their titles are ambiguous:

```bash
.claude/scripts/dso ticket show <bug-id>
```

Up to 5 `ticket show` calls in parallel; cap total at 10.

## What to look for

- **File-level hotspots**: files or directories with high churn AND a high share of fix-class commits, or repeated mentions in bug tickets.
- **Functional hotspots**: bug clusters around the same capability (e.g., "authentication", "PDF rendering", "release pipeline") even if the files differ.
- **Repeated incident patterns**: same root cause appearing in multiple bug tickets months apart.

Each hotspot should have visible evidence in the inputs — do not speculate from training data.

## Output

Return ONLY this JSON object — no narration, no markdown fence:

```json
{
  "summary": "<2–3 sentences giving the overall risk shape of the project>",
  "hotspots": [
    {
      "area": "<file path, directory, or functional theme>",
      "evidence": "<concrete evidence — e.g., '14 commits in last 6 months, 6 of which were fix/hotfix; 3 open bugs reference this area'>",
      "implication_for_prioritization": "<one sentence — e.g., 'Any epic that materially extends this area should be treated as elevated risk'>"
    }
  ]
}
```

Aim for 3–7 hotspots. If the project is genuinely calm (low churn, few bugs), return fewer hotspots and say so in `summary` rather than padding the list.

## Calibration

- A high-churn file is NOT automatically a hotspot. Look for churn + failure together.
- Stable areas with many bugs (low churn, lots of bug reports) are also hotspots — they suggest the area is fragile under change.
- Do NOT recommend epic priorities or actions in this output. Stick to risk evidence.
