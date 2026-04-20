# Contract: External Dependencies Block

- Signal Name: External Dependencies Block
- Status: accepted
- Scope: brainstorm, preplanning, implementation-plan, sprint skills → dependency verification phase
- Date: 2026-04-19

## Purpose

This document defines the schema for the `external_dependencies` block used by planning and execution skills to capture, track, and verify dependencies that exist outside the current story or epic boundary. Each entry in the block describes one dependency — a service, credential, infrastructure resource, or integration — along with who owns it, how Claude should handle it, and whether Claude currently has access.

Skills that emit or consume this block must conform to this schema to ensure consistent dependency resolution across the planning pipeline.

---

## Schema Fields

| Field | Type | Required | Description |
|---|---|---|---|
| `name` | string | yes | Human-readable dependency name (e.g., `"PostgreSQL database"`, `"Stripe API key"`, `"Auth0 tenant"`). Must be descriptive enough to uniquely identify the dependency within the epic. |
| `ownership` | enum | yes | Who is responsible for delivering this dependency. See accepted values below. |
| `handling` | enum | yes | How Claude should handle this dependency during execution. See accepted values below. |
| `claude_has_access` | enum | yes | Whether Claude can currently verify or use this dependency autonomously. See accepted values below. |
| `verification_command` | string | no | Shell command that verifies Claude has access to the dependency (e.g., `"psql $DATABASE_URL -c 'SELECT 1'"`, `"curl -sf $API_BASE_URL/health"`). If omitted, a `justification` note must be included explaining why verification is not possible. |
| `justification` | string | conditional | Free-text explanation of why `verification_command` is absent. Required when `verification_command` is omitted; omit when `verification_command` is present. |
| `confirmation_token_required` | boolean | no | Default `false`. When `true`, sprint's pause handshake requires the user to type a confirmation token before the `user_manual` step is marked complete. The token is logged to the ticket as an audit trail. Valid only on entries where `verification_command` is omitted. |

---

## Field: `ownership` — Accepted Values

| Value | Meaning |
|---|---|
| `exists` | The dependency already exists in the infrastructure. No epic needs to create it. |
| `this-epic` | This epic is responsible for creating or provisioning the dependency. |
| `linked-epic-<id>` | Another epic (identified by its 8-character ticket ID, e.g., `linked-epic-d775-4a36`) is delivering this dependency. The current epic must not proceed until that epic is complete. |

---

## Field: `handling` — Accepted Values

| Value | Meaning |
|---|---|
| `claude_auto` | Claude can verify, use, and reason about this dependency autonomously without human action. Verification commands are expected to pass without intervention. |
| `user_manual` | Human action is required before Claude can use this dependency (e.g., rotating a secret, enabling a feature flag, provisioning an account). Claude must pause and surface the dependency to the user before proceeding past the relevant phase. |

---

## Field: `claude_has_access` — Accepted Values

| Value | Meaning |
|---|---|
| `yes` | Claude has confirmed access to this dependency (via `verification_command` or direct inspection). |
| `no` | Claude does not have access. For `handling: claude_auto` entries, this is a blocking condition — the skill must surface this to the user before proceeding. |
| `unknown` | Access has not yet been verified. Skills should attempt verification when possible before marking `yes`. |

---

## Optional Fields

- **`verification_command`** is optional. When omitted, the entry MUST include a `justification` field explaining why a command cannot be provided (e.g., the dependency is a human-managed credential with no programmatic health check).
- **`justification`** is required only when `verification_command` is absent. It must not be empty — a blank justification is treated as malformed.

---

## Example Block

```yaml
external_dependencies:
  - name: "PostgreSQL database (prod)"
    ownership: exists
    handling: claude_auto
    claude_has_access: yes
    verification_command: "psql $DATABASE_URL -c 'SELECT 1' > /dev/null 2>&1"

  - name: "Stripe restricted API key"
    ownership: exists
    handling: user_manual
    claude_has_access: no
    justification: "API key is a human-managed secret stored in 1Password; no programmatic health check is available without exposing the key in a command."
    confirmation_token_required: true

  - name: "Auth0 tenant (staging)"
    ownership: linked-epic-a68d-9346
    handling: claude_auto
    claude_has_access: unknown
    verification_command: "curl -sf https://my-tenant.auth0.com/.well-known/openid-configuration > /dev/null"
```

---

## Notes

1. **`verification_command` vs. `justification`**: Exactly one of these must be present per entry. An entry with both is malformed; an entry with neither is malformed.
2. **`ownership: linked-epic-<id>`**: The `<id>` portion must be a valid 8-character ticket ID of an open epic in the same tracker. Skills that parse this field may resolve the linked epic to verify its status before proceeding.
3. **`handling: user_manual` + `claude_has_access: no`**: The canonical pattern for human-managed secrets and externally provisioned infrastructure. Skills must not attempt to auto-verify these entries; instead, they must surface a `DEPENDENCY_BLOCKED` signal to the orchestrator.
4. **`handling: user_manual` + `claude_has_access: yes`**: Valid and permitted. Claude can observe or health-check the dependency autonomously, but a human step is still required before Claude can use it (e.g., Claude can verify a service is running but a human must rotate the key before the next phase). Skills should log a note suggesting upgrade to `claude_auto` only if the manual step is purely administrative (e.g., an approval), not when the step involves secret rotation or external provisioning. The `DEPENDENCY_BLOCKED` signal is still emitted; the difference is that Claude can confirm the dependency exists while waiting.
5. **`handling: claude_auto` + `claude_has_access: no`**: A contradiction — Claude cannot proceed autonomously without access. Emitters MUST flag this as `EXTERNAL_DEPENDENCY_CONTRADICTION: <name> — handling=claude_auto conflicts with claude_has_access=no` and treat it as a blocking condition equivalent to `user_manual`.
6. **`claude_has_access: unknown`**: Skills should attempt verification via `verification_command` at the start of each relevant phase and update the field to `yes` or `no` before recording findings. Leaving a field as `unknown` after a verification attempt is a malformed state.
7. **`confirmation_token_required: true` + `verification_command` present**: Invalid combination — `confirmation_token_required` is only meaningful on entries where `verification_command` is absent. Emitters MUST NOT set both. Consumers that encounter this combination MUST log a warning and ignore `confirmation_token_required`.

---

## Consumers

The following skills emit or consume the External Dependencies block:

| Skill | Role | Notes |
|---|---|---|
| `skills/brainstorm/SKILL.md` | Emitter | Identifies external dependencies during feasibility analysis; populates initial block with `ownership` and `handling` classification |
| `skills/preplanning/SKILL.md` | Emitter + Consumer | Refines block per story; links dependencies to specific stories via `linked-epic-<id>` when cross-epic delivery applies |
| `skills/implementation-plan/SKILL.md` | Consumer | Reads block at plan entry; surfaces `user_manual` + `claude_has_access: no` entries as blockers before task decomposition |
| `skills/sprint/SKILL.md` | Consumer | Verifies `claude_auto` entries via `verification_command` at Phase 1 kickoff; emits `DEPENDENCY_BLOCKED` and pauses for `user_manual` entries with `claude_has_access: no` |

All implementors must read this contract before modifying any skill that emits or parses the `external_dependencies` block. Changes to field names, enum values, or required/optional status require updating all conforming emitters and parsers and this document atomically in the same commit.

---

## Versioning

This contract is versioned. Breaking changes (field renames, enum removals, required→optional promotions) increment the version. Additive changes (new optional fields) are backward-compatible.

### Change Log

- **2026-04-19**: Initial version — defines External Dependencies block schema for planning pipeline skills. Establishes `ownership`, `handling`, `claude_has_access`, and `verification_command` fields with full enum definitions, optionality rules, and consumer table.
- **2026-04-19**: Additive — added `confirmation_token_required` (boolean, optional, default false) for sprint pause-handshake audit trail on `user_manual` entries without `verification_command`.
