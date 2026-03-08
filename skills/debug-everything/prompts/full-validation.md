## Full Validation

Run the complete validation suite and report a compact summary.

```bash
PLUGIN_SCRIPTS="${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel)/lockpick-workflow}/scripts"
$PLUGIN_SCRIPTS/validate-phase.sh full
```

The script outputs a structured report. Relay it verbatim.

### Rules
See `$(git rev-parse --show-toplevel)/lockpick-workflow/docs/SUB-AGENT-BOUNDARIES.md` for full sub-agent rules.
- Do NOT fix anything — validation only
- Do NOT `git commit`, `git push`, `tk close`, `tk status`
- Report ALL failures, even if they seem trivial
