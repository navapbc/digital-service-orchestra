## Tier Transition Validation

Run full diagnostics and report compact summary.

```bash
PLUGIN_SCRIPTS="${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel)/lockpick-workflow}/scripts"
$PLUGIN_SCRIPTS/validate-phase.sh tier-transition
```

The script outputs a structured report. Relay it verbatim.

Do NOT fix anything. Do NOT git commit. Report only.
