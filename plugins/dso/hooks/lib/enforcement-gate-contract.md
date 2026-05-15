# Enforcement Gate Contract

This document is the single source of truth for the `_dso_enforcement_gate_check` function
shipped in `enforcement-gate.sh`. All gating hooks source this library. Do not duplicate
gate logic inline in individual hook scripts.

---

## Log Line Schema

When `dso.workflow=ci-pr`, the gate function emits exactly:

```
HOOK_GATE: skipped reason=dso.workflow=<value>
```

- Written to **stderr** (not stdout)
- Exactly one log line per gate check invocation
- No trailing whitespace, no ANSI escape codes

---

## Exit Codes

| Exit code | Meaning | Caller action |
|-----------|---------|---------------|
| `0` | Workflow is `ci-pr`; hook should skip | `_dso_enforcement_gate_check && exit 0` |
| `1` | Workflow is `local` (or absent — defaults to `local`); hook should proceed | Continue hook body |

---

## Default Behavior

When `dso.workflow` is **absent** from `.claude/dso-config.conf`, the function
defaults to `local` (the strictest setting). This means all local gates are active by
default on new projects that have not explicitly configured a workflow.

---

## Gating Hooks

These hooks source `enforcement-gate.sh` and call `_dso_enforcement_gate_check` at their
entry point. When `dso.workflow=ci-pr`, they short-circuit and exit 0 (no-op).

| Hook | Pre-commit config entry |
|------|------------------------|
| `pre-commit-review-gate.sh` | `dso-review-gate` |
| `pre-commit-test-gate.sh` | `dso-test-gate` |
| `pre-commit-test-quality-gate.sh` | `dso-test-quality-gate` |

---

## Always-On Structural Hooks

These hooks enforce repository structural integrity and are **never gated** by
the workflow setting. They must NOT source `enforcement-gate.sh`.

| Hook / Script | Purpose |
|---------------|---------|
| `check-plugin-self-ref.sh` | Blocks literal plugin self-references in plugin scripts |
| `check-portability.sh` | Blocks hardcoded absolute paths |
| `check-shim-refs.sh` | Blocks direct plugin script references |
| `check-contract-schemas.sh` | Validates contract markdown structure |
| `check-referential-integrity.sh` | Detects dead path references |
| `pre-commit-enforcement-boundary-check.sh` | Blocks enforcement hooks from sourcing hook-error-handler.sh |

---

## Usage Pattern for Hook Scripts

```bash
# At the top of a gating hook, after set -uo pipefail:
_GATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_GATE_DIR}/lib/enforcement-gate.sh"
_dso_enforcement_gate_check && exit 0

# ... remainder of hook logic runs only when dso.workflow != ci-pr
```
