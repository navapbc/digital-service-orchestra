# Contract: Dispatch-Split Architecture for Code-Reviewer Agents (Bug 4a30)

## Purpose

This contract defines the dual-variant build mechanism for the 10 code-reviewer agents introduced by bug 4a30. The single canonical source (`reviewer-base.md`) is composed twice — once for Claude Code Agent-tool dispatch (orchestrator path, has Bash/Read/Grep/Glob), once for the toolless CI dispatch (`dso_ci_review/dispatch.py` → `litellm.completion`) — using HTML-comment-guarded dispatch markers and the `DISPATCH_VARIANT` env var. The two variants ship to `agents/` and `agents/ci/` respectively; `dispatch.py` resolves CI-dispatched agents through the `ci/` tree with fallback to `agents/` for agents that have no CI variant.

## Background

The 10 code-reviewer agents are composed in two variants from a single canonical source so that the same review contract can be deployed to two execution environments with different tool surfaces:

- **Orchestrator dispatch** (Claude Code Agent tool) — has Bash, Read, Grep, Glob; uses `write-reviewer-findings.sh` and returns a `REVIEWER_HASH` envelope.
- **CI dispatch** (`scripts/dso_ci_review/dispatch.py` → `litellm.completion`) — has no tools (`tools=[...]` is not passed); must return findings as a single JSON object directly in the message body.

Before this split, both dispatch paths received the same agent prompt, which instructed tool use. The CI model — told it had tools but given no API channel to invoke them — reproduced Claude's native tool-use serialization (`<function_calls><invoke>...</invoke></function_calls>`) as literal text in its message body. The parser at `dispatch.py:_parse_response` then rejected the response as non-JSON, blocking every large-diff CI review.

## Source of truth

Single canonical source: `docs/workflows/prompts/reviewer-base.md`. Composed with per-tier deltas (`reviewer-delta-<tier>.md`) by `build-review-agents.sh` → `build-composed-agents.sh`.

## Dispatch markers

`reviewer-base.md` uses HTML-comment-guarded blocks to mark dispatch-asymmetric content:

```markdown
<!-- DISPATCH:orchestrator -->
Step 3 — Write Findings to Disk (REQUIRED before returning)

Pipe your complete JSON into `write-reviewer-findings.sh` via the `.claude/scripts/dso` shim ...
<!-- /DISPATCH:orchestrator -->

<!-- DISPATCH:ci -->
Step 3 — Return findings as JSON in your message body

The CI dispatcher parses your response body directly as JSON. There is no
`write-reviewer-findings.sh` to call — the dispatcher persists findings on your behalf
after parsing your response.

**Your entire response MUST be a single JSON object** matching the canonical findings
schema ...
<!-- /DISPATCH:ci -->
```

Shared content (severity rubric, category enumeration, anti-pattern guidance, false-positive defense rules) lives outside any DISPATCH block and is included verbatim in both variants.

## Build mechanism

`build-review-agents.sh` invokes `build-composed-agents.sh` twice:

```bash
DISPATCH_VARIANT=orchestrator bash build-composed-agents.sh \
    --namespace reviewer --output agents/

DISPATCH_VARIANT=ci bash build-composed-agents.sh \
    --namespace reviewer --output agents/ci/
```

`reviewer-meta.sh::_meta_substitute_base` reads `DISPATCH_VARIANT` and strips the opposing marker block before tier-specific `{{CANONICAL_TIER}}` substitution. The light-tier strip of the Context-Request Protocol section (bug 57b9-1f14) is layered on top.

`set -euo pipefail` is in effect in the wrapper — if the orchestrator build exits non-zero, the script aborts before the CI build runs, so the `agents/` tree is never left in a half-orchestrator / half-CI state.

## Output paths

| Variant | Path | Consumed by |
|---|---|---|
| Orchestrator | `agents/code-reviewer-<tier>.md` | Claude Code Agent tool dispatch (skills, `/dso:review`) |
| CI | `agents/ci/code-reviewer-<tier>.md` | `dso_ci_review/dispatch.py::_load_agent_prompt` |

`dispatch.py::_load_agent_prompt` tries `agents/ci/<agent_id>.md` first, falls back to `agents/<agent_id>.md` for agents without a CI variant.

## Scope

**In scope** (10 agents, both variants generated):
- `code-reviewer-light` (haiku)
- `code-reviewer-standard` (sonnet)
- `code-reviewer-deep-correctness` (sonnet)
- `code-reviewer-deep-verification` (sonnet)
- `code-reviewer-deep-hygiene` (sonnet)
- `code-reviewer-deep-arch` (opus)
- `code-reviewer-security-red-team` (opus)
- `code-reviewer-security-blue-team` (opus)
- `code-reviewer-performance` (opus)
- `code-reviewer-test-quality` (opus)

**Not in scope** (orchestrator-only, no CI variant generated):
- `huge-diff-reviewer-light`, `huge-diff-reviewer-standard` — CI uses Strategy E region-split via `region_split.py:391-423`, which reuses the standard tier agents; the huge-diff agents are never CI-dispatched. See `AGENTS.md` line 70.

**No CI variant needed** (agents that don't compose `reviewer-base.md`):
- `code-reviewer-arbiter`, `code-reviewer-verifier` — receive structured JSON input and emit structured JSON rulings; no tool-use instructions. Confirmed safe by the bug 4a30 sweep.
- `schema-correction` — Haiku-tier validator-driven rewrite; no tool-use instructions.

These resolve through `dispatch.py`'s fallback path (`agents/<agent_id>.md`).

## Canonical finding schema

CI dispatch's `validate-review-output.sh` enforces strict field names:

| Field | Type | Notes |
|---|---|---|
| `severity` | string | `critical`, `important`, `minor`, `fragile`, or auto-downgraded `suggestion` |
| `category` | string | One of `correctness`, `design`, `hygiene`, `maintainability`, `verification` |
| `description` | string | Full reasoning, including `verification_evidence` for absence claims |
| `file` | string | Repository-relative path |
| `cited_lines` | array | List of `<path>:<line>` strings |

Synonym fields (`dim`, `title`, `line`) are rejected by the validator and cause re-dispatch. The schema-correction agent rewrites a small whitelist of synonyms (`dimension` → `category`, etc.) before validation in some pipeline configurations, but reviewer prompts should emit canonical names directly.

## Defense-in-depth

`dispatch.py::_parse_response` strips `<function_calls>...</function_calls>` and `<invoke ...>...</invoke>` markup via regex before `json.loads`. This rescues the failure mode if the CI variant prompt ever regresses or a future model emits the markup despite explicit prohibitions. A WARNING is logged on each strip so the underlying prompt regression is observable.

## Verification

Build invariants tested by `tests/skills/dso_ci_review/test_dispatch_agent_loader.py` and `tests/skills/dso_ci_review/test_tier_wiring.py` (both updated in PR #493 to read from `agents/ci/`). Forbidden-content assertions per variant should be added as follow-up:

- `agents/ci/code-reviewer-*.md` must not contain: `Read tool`, `\bBash\b`, `Grep tool`, `<function_calls>`, `<invoke`, `write-reviewer-findings.sh`, `REVIEWER_HASH`, `.claude/scripts/dso`
- `agents/code-reviewer-*.md` (orchestrator) must not contain: `"action": "read_files"`, `"action": "grep"` (CI-only context-request protocol artifacts)
