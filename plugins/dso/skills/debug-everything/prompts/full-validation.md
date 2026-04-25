## Full Validation

Run the complete validation suite and report a compact summary.

```bash
PLUGIN_SCRIPTS="${CLAUDE_PLUGIN_ROOT}/scripts"
# --skip-ci: CI runs on main, not the worktree branch. CI status is
# checked in Phase L after merging to main — checking it here would
# always show the pre-fix state and produce a false failure.
$PLUGIN_SCRIPTS/validate-phase.sh full --skip-ci  # shim-exempt: internal orchestration script
```

The script outputs a structured report. Relay it verbatim.

### Rules
See `${CLAUDE_PLUGIN_ROOT}/docs/SUB-AGENT-BOUNDARIES.md` for full sub-agent rules.
- Report ALL failures, even if they seem trivial

**READ-ONLY ENFORCEMENT**: Read and follow `prompts/shared/read-only-enforcement.md`.
