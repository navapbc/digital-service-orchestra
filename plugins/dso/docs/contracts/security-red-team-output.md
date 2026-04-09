# Contract: Security Red Team Output Interface

- Signal Name: SECURITY_RED_TEAM_OUTPUT
- Status: accepted
- Scope: security overlay review (epic dso-5ooy)
- Date: 2026-03-28

## Purpose

This document defines the interface between the `dso:code-reviewer-security-red-team` agent (emitter) and its consumers: the security blue team agent and the overlay dispatch orchestrator. The red team performs adversarial security review of code diffs, emitting structured findings; the blue team and dispatch orchestrator consume those findings to decide whether to block or annotate a commit.

This contract must be agreed upon before either side is implemented to prevent implicit coupling and ensure emitter and parser stay in sync.

---

## Signal Name

`SECURITY_RED_TEAM_OUTPUT`

---

## Emitter

`dso:code-reviewer-security-red-team` (sonnet)

Located at `plugins/dso/agents/code-reviewer-security-red-team.md`.

The emitter receives a code diff and performs adversarial security review against a defined set of security criteria (e.g., TOCTOU, injection, path traversal, secret exposure, privilege escalation). It outputs a `reviewer-findings.json`-conformant payload and exits. The emitter is invoked by the overlay dispatch orchestrator as part of the security overlay review pipeline.

---

## Parser

- Security blue team agent (story w22-7r1n)
- Overlay dispatch orchestrator (story w22-25ui)

The blue team reads the red team output to produce a filtered, confidence-weighted finding set. The dispatch orchestrator reads the output to determine whether to surface findings to the commit workflow or suppress them under graceful degradation.

---

## Schema

The red team output conforms to the standard `reviewer-findings.json` schema with three top-level keys:

```json
{
  "scores": { ... },
  "findings": [ ... ],
  "summary": "..."
}
```

### `scores`

An object mapping review dimensions to integer scores (0–10). The security red team always emits only the `correctness` dimension, as security vulnerabilities are correctness failures:

```json
"scores": {
  "correctness": 3
}
```

### `findings`

An array of finding objects. Each finding uses the following standard fields:

| Field | Type | Required | Description |
|---|---|---|---|
| `severity` | string (enum) | required | One of `critical`, `important`, or `minor`. Maps to standard reviewer severity semantics. |
| `description` | string | required | Human-readable finding text, prefixed with the security criterion name in brackets. Example: `"[TOCTOU] File existence check and open are not atomic; an attacker can replace the file between check and use."` |
| `file` | string | required | Primary affected file path (repo-relative). |
| `category` | string | required | Always `"correctness"` — security criterion identity is encoded in the `description` prefix. |

#### Security Criterion Prefixes

The `description` field must begin with a bracketed criterion name. Defined prefixes:

| Prefix | Criterion |
|---|---|
| `[TOCTOU]` | Time-of-check / time-of-use race condition |
| `[INJECTION]` | Command, SQL, or shell injection |
| `[PATH_TRAVERSAL]` | Directory traversal or symlink escape |
| `[SECRET_EXPOSURE]` | Hardcoded or logged secrets/credentials |
| `[PRIV_ESC]` | Privilege escalation or improper permission |
| `[UNVALIDATED_INPUT]` | Missing or insufficient input validation |
| `[CRYPTO]` | Weak or misused cryptographic primitive |
| `[OTHER]` | Security concern not covered by the above |

### `summary`

A string containing the overall security posture assessment and confidence level. Must include:

1. A one-sentence posture statement (e.g., "No high-severity security issues found in the reviewed diff.")
2. A confidence qualifier (e.g., "Confidence: high — diff is self-contained with no external dependency changes.")

---

## Example JSON Payload

```json
{
  "scores": {
    "correctness": 4
  },
  "findings": [
    {
      "severity": "critical",
      "description": "[TOCTOU] File existence check (`test -f`) and subsequent open are not atomic in `scripts/deploy.sh` line 42; an attacker with write access to the directory can substitute a symlink between check and open.",
      "file": "scripts/deploy.sh",
      "category": "correctness"
    },
    {
      "severity": "important",
      "description": "[UNVALIDATED_INPUT] The `branch` parameter passed to `git checkout` in `scripts/merge-to-main.sh` line 87 is interpolated without sanitization; a branch name containing shell metacharacters could cause unexpected behavior.",
      "file": "scripts/merge-to-main.sh",
      "category": "correctness"
    }
  ],
  "summary": "Two security issues found: one critical TOCTOU race and one important input validation gap. Confidence: high — the diff is isolated to shell scripts with no external service interactions."
}
```

### Canonical parsing prefix

The parser MUST match against:

- `SECURITY_RED_TEAM_OUTPUT` — this contract defines a `reviewer-findings.json` file interface. The parser reads the JSON object from that file and inspects the `scores`, `findings`, and `summary` keys. Within `findings`, each entry's `description` field MUST begin with a bracketed criterion prefix (e.g., `[TOCTOU]`, `[INJECTION]`). No line-prefix matching applies at the file level; the parser must deserialize the JSON object.

---

## Exit Code Semantics

| Exit code | Meaning |
|---|---|
| `0` | Success — `reviewer-findings.json` was written and conforms to this schema |
| non-zero | Failure — output may be absent, partial, or malformed |

---

## Failure Contract

If the emitter exits non-zero, times out (exit code 144 from SIGURG), or writes a malformed `reviewer-findings.json` (missing required keys, invalid severity values, missing criterion prefix in `description`), the overlay dispatch orchestrator **must not** block the commit. Graceful degradation applies: the security overlay is skipped for this commit, a warning annotation is added to the commit log, and a tracking ticket is created for manual follow-up. The blue team parser must treat a missing or unparseable output as equivalent to an empty findings array with a `summary` of `"Security review unavailable — emitter failure."`.

---

## Versioning

This contract is unversioned. Breaking changes (field removal, type changes, removal or renaming of criterion prefixes, schema restructuring) require updating the emitter agent definition (`plugins/dso/agents/code-reviewer-security-red-team.md`) and this document atomically in the same commit. Additive changes (new optional fields, new criterion prefixes) are backward-compatible and do not require a version bump.
