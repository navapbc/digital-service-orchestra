## Post-Batch Validation

Run validation and report a compact summary.

```bash
PLUGIN_SCRIPTS="${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel)/lockpick-workflow}/scripts"
$PLUGIN_SCRIPTS/validate-phase.sh post-batch
```

The script outputs a structured report. Relay it verbatim, then add:
```
LIKELY_CAUSE: <files from batch that likely caused failures, or "n/a" if all PASS>
```

Do NOT fix anything. Do NOT git commit. Report only.
