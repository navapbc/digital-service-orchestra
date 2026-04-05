## Post-Batch Validation

Run validation and report a compact summary.

```bash
PLUGIN_SCRIPTS="${CLAUDE_PLUGIN_ROOT}/scripts"
$PLUGIN_SCRIPTS/validate-phase.sh post-batch  # shim-exempt: internal orchestration script
```

The script outputs a structured report. Relay it verbatim, then add:
```
LIKELY_CAUSE: <files from batch that likely caused failures, or "n/a" if all PASS>
```

**READ-ONLY ENFORCEMENT**: Read and follow `prompts/shared/read-only-enforcement.md`.
