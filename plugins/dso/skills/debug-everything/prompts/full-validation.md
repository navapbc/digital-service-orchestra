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
- Report ALL failures, even if they seem trivial

## READ-ONLY ENFORCEMENT

You are a read-only reporting agent. You MUST NOT modify any files or system state.

**STOP immediately** if you find yourself about to use any of these tools or commands:
- **Edit** — forbidden. Do not edit any file.
- **Write** — forbidden. Do not write any file.
- **Bash with modifying commands** — forbidden:
  - `git commit`, `git push`, `git add`, `git checkout`, `git reset`
  - `tk close`, `tk status`, `tk update`, `tk create`
  - `make`, `pip install`, `npm install`, `poetry install`
  - Any command that changes system state

If you detect a problem, you must ONLY report it. You must not fix it.
Fixing is the orchestrator's job, not yours. TERMINATE your response with findings only.
