# Runbook: audit-live — Bootstrap-Throttle Live Evidence Capture

## Purpose

`make -f Makefile.audit audit-live` runs the full 5-script audit pipeline
(dd4→dd1→dd2→dd3→dd5) against live reconciler state for the
`bootstrap-throttle` phase.  It produces `dd2.json` (orphan-count diff with
`sc8_pass`) and the final `dd5.json` bundle (overall_result + per-DD pass/fail)
that serve as story-closure evidence.

## Preconditions

- You are running from the repo root (or any directory; the Makefile resolves
  paths relative to its own location).
- The reconciler has completed bootstrap-throttle pass 8 (after_count = 0
  confirmed in reconciler logs).
- `.reconciler-phase-gate` exists and is writable.
- All audit scripts are executable: `ls -la scripts/dso_reconciler/audits/audit_*.sh`.

---

## Operator 5-Step Sequence

### Step 1 — Confirm bootstrap-throttle phase complete (pass 8 finished)

Check the reconciler run log or the phase-gate ops log:

```bash
cat .reconciler-phase-gate
# Expected: bootstrap-throttle
tail -5 .reconciler-phase-gate.ops
# Confirm: latest record shows phase=bootstrap-throttle, pass=8
```

Abort if `after_count` in the latest reconciler output is non-zero.

### Step 2 — Advance `.reconciler-phase-gate` to 'audit'

Run the phase-advance helper to atomically flip the gate and record the
operator action:

```bash
bash scripts/dso_reconciler/audits/audit_phase_advance.sh \
  --phase audit \
  --comment "bootstrap-throttle pass 8 complete; advancing to audit"
```

Verify:

```bash
cat .reconciler-phase-gate        # → audit
tail -1 .reconciler-phase-gate.ops | python3 -m json.tool
# Confirm: phase="audit", operator field populated, timestamp present
```

### Step 3 — Run the audit pipeline

```bash
make -f scripts/dso_reconciler/audits/Makefile.audit audit-live
```

Expected output: each of the 5 scripts prints its own success summary; the
final line from dd5 reports `overall_result=true`.

If any script exits non-zero, the pipeline short-circuits and the target
returns a non-zero exit code.  Inspect the failing script's output for
diagnostics.

### Step 4 — Verify dd2.json sc8_pass=true

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

### Step 5 — Attach dd2.json artifact to epic 4047 (story-closure assertion)

```bash
# Confirm after_count = 0 in the artifact
python3 -c "
import json
with open('.reconciler-audit-artifacts/bootstrap-throttle/dd2.json') as f:
    d = json.load(f)
print('after_count =', d.get('after_count'))
print('before_count =', d.get('before_count'))
"

# Attach via ticket comment (replace <path> with absolute path if needed)
.claude/scripts/dso ticket comment 4047-3cb1-6cb4-46a1 \
  "STORY_CLOSURE_EVIDENCE: dd2.json attached. after_count=0, sc8_pass=true. \
Artifact: .reconciler-audit-artifacts/bootstrap-throttle/dd2.json"
```

Story 83ac-745e-79b0-4148 may now be transitioned to closed with:

```bash
.claude/scripts/dso ticket transition 83ac-745e-79b0-4148 in_progress closed \
  --reason="Fixed: bootstrap-throttle pass 8 complete; sc8_pass=true confirmed"
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `dd4-phase-gate` exits non-zero | `.reconciler-phase-gate` not at `audit` | Re-run Step 2 |
| `dd2.json` missing | dd2 script failed mid-run | Check stderr; re-run `make audit-live` |
| `sc8_pass=false` | after_count still non-zero | Run another reconciler pass, then repeat from Step 1 |
| `overall_result=false` in dd5.json | One or more sub-DDs failed | Inspect per-DD fields in dd5.json |

## Related files

- `scripts/dso_reconciler/audits/Makefile.audit` — defines `audit-live` target
- `scripts/dso_reconciler/audits/audit_phase_advance.sh` — phase-gate writer
- `scripts/dso_reconciler/audits/audit_dd4_phase_gate.sh` — gate reader (DD4)
- `scripts/dso_reconciler/audits/audit_dd2_orphan_count.sh` — orphan diff (DD2)
- `scripts/dso_reconciler/audits/audit_dd5_bundle.sh` — final bundler (DD5)
- `tests/unit/scripts/test_audit_live.sh` — unit tests for this pipeline
