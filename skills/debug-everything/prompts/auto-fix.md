## Auto-Fix: Format and Lint (Tiers 0-1)

Run auto-fixers, validate, and report what changed.

### Instructions

1. Run `pwd` to confirm working directory
2. Run the auto-fix validation phase:
   ```bash
   $(git rev-parse --show-toplevel)/scripts/validate-phase.sh auto-fix
   ```
3. The script outputs a structured report. Relay it verbatim.

### Rules
See `$(git rev-parse --show-toplevel)/lockpick-workflow/docs/SUB-AGENT-BOUNDARIES.md` for full sub-agent rules.
- Do NOT: `git commit`, `git push`, `tk close`, `tk status`
- Do NOT manually fix lint or type errors — only use auto-fixers
- Report remaining manual-fix-required violations for the orchestrator
