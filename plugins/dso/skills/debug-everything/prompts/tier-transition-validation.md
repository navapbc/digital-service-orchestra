## Tier Transition Validation

Run full diagnostics and report compact summary.

```bash
PLUGIN_SCRIPTS="${CLAUDE_PLUGIN_ROOT}/scripts"
$PLUGIN_SCRIPTS/validate-phase.sh tier-transition  # shim-exempt: internal orchestration script
```

The script outputs a structured report. Relay it verbatim.

**READ-ONLY ENFORCEMENT**: Read and follow `prompts/shared/read-only-enforcement.md`.
