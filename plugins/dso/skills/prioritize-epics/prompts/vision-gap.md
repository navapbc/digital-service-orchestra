# Sub-Agent Prompt: Vision Gap Analysis (Phase 1 Step 4)

## Role

Compare the **current state** of the project (codebase, docs, configuration) against the **vision summary** distilled from open epics. Identify what's already in place, what's missing, and where the biggest gaps are.

## Inputs

You will be given:

- `VISION_SUMMARY` — the narrative from Phase 1 Step 3
- `THEMES` — the list of themes

You may run the following commands to inspect current state. Treat their output as evidence:

```bash
ls -la                                # top-level layout
ls docs/ 2>/dev/null || true          # docs directory
git log --oneline -50                 # recent commits
git diff --stat HEAD~50..HEAD 2>/dev/null || true   # files churned recently
```

You may also read any of these files if present (one Read per call, up to 5 in parallel):

- `README.md`, `PRD.md`, `docs/PRD.md`
- `.claude/design-notes.md`
- `CLAUDE.md`
- Any file matching `docs/designs/*.md` (read at most 3, prefer the most recently modified)

Do NOT exhaustively scan the codebase. The goal is a "first 10 minutes of orientation" gap read, not a full audit.

## What to look for

- **Notable progress**: parts of the vision that are visibly present (a feature area with substantial code, a documented design, an active CI workflow). Cite specific evidence (path, recent commit, doc filename).
- **Notable gaps**: vision themes with little or no visible footprint in the code or docs (no matching directory, no recent commits in the area, no design doc).
- **Misalignment signals**: places where the code is investing heavily in something the open epics don't reflect (or vice versa).

## Output

Return ONLY this JSON object — no narration, no markdown fence:

```json
{
  "gap_summary": "<3–6 sentence narrative summarizing how far the current codebase is from the vision>",
  "notable_gaps": [
    "<1-sentence gap, with evidence — e.g., 'No code or design doc for the reporting theme; only a stub directory under src/reports/'>"
  ],
  "notable_progress": [
    "<1-sentence progress item, with evidence — e.g., 'CI hardening already substantial — see .github/workflows/ and 40+ recent commits to scripts/'>"
  ]
}
```

Aim for 3–6 entries in each list. Be specific with evidence (paths, filenames, rough commit counts).

## Calibration

- This analysis informs the Phase 2 stakeholder conversation. It is NOT a prioritization judgment.
- Do NOT recommend priorities or epic actions in this output. Stick to descriptive observations.
- If you cannot find evidence either way for a theme, say so plainly ("No evidence found for or against").
