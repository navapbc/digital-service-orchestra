# Contract: CI vs Local Parity Scope

- Signal Name: ci-vs-local-parity-scope
- Status: accepted
- Scope: CI litellm dispatch ↔ local /dso:review dispatch architecture delta
- Date: 2026-05-07

## Purpose

Documents the dispatch-architecture delta between CI (litellm-based) and local `/dso:review`
(Skill tool, Claude Code sub-agents). This is the parity scope contract — what CI replicates
from local, and what diverges by design. Consumers of this contract understand which behaviors
can be tested identically across environments and which require environment-aware test stubs.

## CI vs Local Dispatch Architecture

| Review tier | Local `/dso:review` | CI litellm |
|---|---|---|
| Light | `dso:code-reviewer-light` (haiku) via Skill tool | litellm completion with `code-reviewer-light.md` system prompt |
| Standard | `dso:code-reviewer-standard` (sonnet) via Skill tool | litellm completion with `code-reviewer-standard.md` system prompt |
| Deep (specialists) | 3 parallel sonnet specialists via Task agents | 3 parallel async litellm calls with specialist `.md` prompts |
| Deep (arch synthesis) | `dso:code-reviewer-deep-arch` (opus) via Skill tool | Sequential opus litellm call via `dispatch_arch_synthesis()` |
| Overlay: security | `dso:code-reviewer-security-red-team` then `blue-team` via Skill | async litellm with `security-red-team.md` then `blue-team.md` (sequential when `overlay_warranted`) |
| Overlay: performance | `dso:code-reviewer-performance` via Skill | async litellm with `performance.md` |
| Overlay: test-quality | `dso:code-reviewer-test-quality` via Skill | async litellm with `test-quality.md` |

## Design-Intent Divergences

These differences are intentional and should not be treated as bugs:

1. **Runtime SDK**: CI uses litellm for cost efficiency and API portability across providers.
   Local uses the Claude Code SDK (Skill tool invocations, Task tool for sub-agents).

2. **Tier selection**: CI uses `classifier.sh` (bash shim) for tier selection; local uses
   the `classify_tier` Python path. Both resolve through the same bash shim as of the
   context-augmentation epic.

3. **Arch synthesis fidelity**: CI arch synthesis is a single sequential opus litellm call
   (approximation of the sub-agent). Local runs a full `dso:code-reviewer-deep-arch`
   sub-agent with tool use (file reads, grep) for multi-turn analysis.

4. **Multi-turn tool use**: CI cannot perform multi-turn tool-use review cycles — each
   litellm call is a single completion. Local reviewers can read files, grep, and
   request additional context via the context-augmentation loop
   (see `ci-review-context-request.md`).

5. **Defense record storage**: CI writes defense records via `GitHubPRDefenseStore`
   (PR comments on the pull request). Local writes via `TrackerDefenseStore`
   (ticket comments on the ticket system). # tickets-boundary-ok

## What CI Replicates Exactly

These behaviors are identical between CI and local and should have equivalent test coverage:

- **Agent prompt files**: same `agents/*.md` files loaded from `$CLAUDE_PLUGIN_ROOT`
- **Relation taxonomy**: same schema from `review-findings-schema.md`
- **Defense record format**: same prefix (`DEFENSE_RECORD:`) and structure from `review-defenses.md`
- **Severity blocking thresholds**: same `_BLOCKING_SEVERITIES` set (`critical`, `important`)
- **Overlay flag names**: same keys (`test_quality_overlay`, `security_overlay`, `performance_overlay`)
  as defined in `ci-overlay-flags.md`
- **Tier classifier output format**: same `classifier-tier-output.md` schema consumed by both paths

## Scope Notes

This contract covers dispatch architecture only. For the context-augmentation multi-turn
protocol (file/grep requests, soft-cap exhaustion handling), see
`ci-review-context-request.md`. For overlay flag format details, see `ci-overlay-flags.md`.
For tier classifier output schema, see `classifier-tier-output.md`.
