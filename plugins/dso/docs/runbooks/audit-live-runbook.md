# Runbook: audit-live — Bootstrap-Throttle Live Evidence Capture

## Purpose

`make -f Makefile.audit audit-live` runs the full 5-script audit pipeline
(dd4 → dd1 → dd2 → dd3 → dd5) against live reconciler state for the
`bootstrap-throttle` phase.  It produces `dd2.json` (orphan-count diff with
`sc8_pass`) and the final `dd5.json` bundle (`overall_result` + per-DD pass /
fail) that serve as story-closure evidence.

## Path conventions used in this runbook

All shell commands below are written to be run **from the repo root** (the
output of `git rev-parse --show-toplevel`).  Where a command references the
audit scripts directory, it uses the variable form:

```bash
AUDIT_DIR="${CLAUDE_PLUGIN_ROOT}/scripts/dso_reconciler/audits"
```

`CLAUDE_PLUGIN_ROOT` is set by the harness when the plugin is loaded; outside
that context, point it at the install directory of the DSO plugin.

## Preconditions

- You are running from the repo root.
- The reconciler has completed bootstrap-throttle pass 8 (`after_count = 0`
  confirmed in reconciler logs).
- `.reconciler-state/.reconciler-phase-gate` exists, contains
  `bootstrap-throttle` on a single line, and is writable.
- All audit scripts are executable: `ls -la "$AUDIT_DIR"/audit_*.sh`.
- The reconciler has written a per-pass log to
  `"$AUDIT_DIR"/pass-log.jsonl` (one JSON object per line; fields:
  `phase`, `pass_index`, `mutation_count`, `timestamp`).  The Makefile's
  `_check-pass-log` precondition target fails fast with a clear message if this
  file is absent.

---

## Operator 5-Step Sequence

### Step 1 — Confirm bootstrap-throttle phase complete (pass 8 finished)

Check the reconciler run log or the phase-gate ops log:

```bash
cat .reconciler-state/.reconciler-phase-gate
# Expected: bootstrap-throttle
tail -5 .reconciler-state/.reconciler-phase-gate.ops
# Confirm: latest record shows phase=bootstrap-throttle, pass=8
```

Abort if `after_count` in the latest reconciler output is non-zero.

### Step 2 — Confirm the phase gate already holds bootstrap-throttle

The audit pipeline reads the same gate that the reconciler advanced when it
entered bootstrap-throttle, so no extra gate-advance is required.  Verify:

```bash
test "$(tr -d '[:space:]' < .reconciler-state/.reconciler-phase-gate)" \
    = bootstrap-throttle \
    || { echo 'gate not at bootstrap-throttle'; exit 1; }
```

If you need to manually re-assert the gate (e.g. it was clobbered), commit the
update on the `tickets` branch with an operator comment:

```bash
echo bootstrap-throttle > .reconciler-state/.reconciler-phase-gate
printf '{"operator":"<your-id>","timestamp":"%s","phase":"bootstrap-throttle","comment":"manual gate re-assertion"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    >> .reconciler-state/.reconciler-phase-gate.ops
git add .reconciler-state/.reconciler-phase-gate .reconciler-state/.reconciler-phase-gate.ops
git commit -m "ops: re-assert phase gate at bootstrap-throttle"
```

### Step 3 — Run the audit pipeline

```bash
make -f "$AUDIT_DIR/Makefile.audit" audit-live
```

Expected output: each of the 5 scripts prints its own success summary; the
final line from dd5 reports `overall_result=true`.

If any script exits non-zero, the pipeline short-circuits and the target
returns a non-zero exit code.  Inspect the failing script's stderr for
diagnostics; see the Troubleshooting table below.

### Step 4 — Verify `dd2.json` `sc8_pass=true`

```bash
python3 -c "
import json, sys
with open('.reconciler-audit-artifacts/bootstrap-throttle/dd2.json') as f:
    d = json.load(f)
sc8 = d.get('sc8_pass', False)
print('sc8_pass =', sc8)
sys.exit(0 if sc8 else 1)
"
```

Exit 0 = pass.  Exit 1 = before/after counts did not converge; check the
reconciler run again.

### Step 5 — Attach `dd2.json` artifact to epic 4047 (story-closure assertion)

```bash
python3 -c "
import json
with open('.reconciler-audit-artifacts/bootstrap-throttle/dd2.json') as f:
    d = json.load(f)
print('after_count =', d.get('after_count'))
print('before_count =', d.get('before_count'))
"

.claude/scripts/dso ticket comment 4047-3cb1-6cb4-46a1 \
  "STORY_CLOSURE_EVIDENCE: dd2.json attached. after_count=0, sc8_pass=true. \
Artifact: .reconciler-audit-artifacts/bootstrap-throttle/dd2.json"
```

Story 83ac-745e-79b0-4148 may then be transitioned to closed with:

```bash
.claude/scripts/dso ticket transition 83ac-745e-79b0-4148 in_progress closed \
  --reason="Fixed: bootstrap-throttle pass 8 complete; sc8_pass=true confirmed"
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `dd4-phase-gate` exits non-zero | `.reconciler-state/.reconciler-phase-gate` not at `bootstrap-throttle` | Re-assert per Step 2 |
| `dd2.json` missing | dd2 script failed mid-run | Check stderr; re-run `make audit-live` |
| `sc8_pass=false` | `after_count` still non-zero | Run another reconciler pass, then repeat from Step 1 |
| `overall_result=false` in `dd5.json` | One or more sub-DDs failed | Inspect per-DD fields (`dd1_pass`, `dd2_pass`, `dd3_pass`, `dd4_pass`) in `dd5.json` |
| `ERROR: pass-log.jsonl not found` from `_check-pass-log` | Reconciler did not emit a per-pass log into the audit dir | Stage the reconciler's pass log at `"$AUDIT_DIR"/pass-log.jsonl` before invoking `audit-live` |
| Reconciler exits **code 3** (pass-lock present) | A stale `.reconciler-pass-lock` from a previous interrupted pass blocks new runs | On the `tickets` branch: `git rm .reconciler-pass-lock && git commit -m 'ops: clear stale pass-lock'` |
| Reconciler exits **code 4** (phase-gate blocks mode) | Operator requested a mode the current phase does not authorise | Confirm the intended phase, advance / re-assert the gate as in Step 2, then rerun |

## Related files

- `Makefile.audit` (under the audits directory) — defines the `audit-live` target
- `audit_dd4_phase_gate.sh` — gate reader (dd4)
- `audit_dd1_baseline.sh` — baseline capture (dd1)
- `audit_dd2_orphan_count.sh` — orphan diff (dd2)
- `audit_dd3_mutation_caps.py` — per-pass mutation cap verifier (dd3)
- `audit_dd5_bundle.sh` — final bundler (dd5)
- `tests/unit/scripts/test_audit_live.sh` — unit tests for this pipeline
