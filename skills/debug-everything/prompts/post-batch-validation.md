## Post-Batch Validation

Run validation and report a compact summary.

```bash
$(git rev-parse --show-toplevel)/scripts/validate-phase.sh post-batch
```

The script outputs a structured report. Relay it verbatim, then add:
```
LIKELY_CAUSE: <files from batch that likely caused failures, or "n/a" if all PASS>
```

Do NOT fix anything. Do NOT git commit. Report only.
