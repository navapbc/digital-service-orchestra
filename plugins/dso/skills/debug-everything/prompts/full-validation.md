## Full Validation

Run the complete validation suite and report a compact summary.

```bash
PLUGIN_SCRIPTS="${CLAUDE_PLUGIN_ROOT}/scripts"
# --skip-ci: CI runs on main, not the worktree branch. CI status is
# checked in Phase 10 after merging to main — checking it here would
# always show the pre-fix state and produce a false failure.
$PLUGIN_SCRIPTS/validate-phase.sh full --skip-ci
```

The script outputs a structured report. Relay it verbatim.

### Rules
See `${CLAUDE_PLUGIN_ROOT}/docs/SUB-AGENT-BOUNDARIES.md` for full sub-agent rules.
- Do NOT fix anything — validation only
- Do NOT `git commit`, `git push`, `tk close`, `tk status`
- Report ALL failures, even if they seem trivial
