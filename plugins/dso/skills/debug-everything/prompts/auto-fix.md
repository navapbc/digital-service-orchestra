## Auto-Fix: Format and Lint (Tiers 0-1)

Run auto-fixers, validate, and report what changed.

### Instructions

1. Run `pwd` to confirm working directory
2. Run the auto-fix validation phase:
   ```bash
   PLUGIN_SCRIPTS="${CLAUDE_PLUGIN_ROOT}/scripts"
   $PLUGIN_SCRIPTS/validate-phase.sh auto-fix
   ```
3. The script outputs a structured report. Relay it verbatim.

### Rules
See `${CLAUDE_PLUGIN_ROOT}/docs/SUB-AGENT-BOUNDARIES.md` for full sub-agent rules.
- Do NOT: `git commit`, `git push`, `.claude/scripts/dso ticket transition`
- Do NOT manually fix lint or type errors — only use auto-fixers
- Report remaining manual-fix-required violations for the orchestrator
