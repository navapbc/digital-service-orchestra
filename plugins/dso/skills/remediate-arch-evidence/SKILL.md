---
name: remediate-arch-evidence
description: Use to remediate a single epic that has been flagged by the architecture-vs-evidence audit (tag `arch-evidence:remediation-needed`). Reads the audit findings for that one epic, walks the user through structured remediation per flagged probe (self-use SC, workflow-trigger audit, state-lifecycle table, bypass governance pairing, spec-phase decomposition, External Dependencies block), applies remediations to the epic description, verifies, and updates tags. Single-epic scope only — for multiple flagged epics, invoke once per epic in fresh sessions. Trigger phrases include "remediate epic <id>", "remediate <id> for architecture-vs-evidence", "fix arch-evidence gaps in <id>", "address audit findings on <id>".
user-invocable: true
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
---

<SUB-AGENT-GUARD>
Requires Agent tool (Phase 4 verification dispatch). If running as a sub-agent (Agent tool unavailable), STOP and return: "ERROR: /dso:remediate-arch-evidence requires orchestrator context (verification dispatch); invoke from orchestrator."
</SUB-AGENT-GUARD>

# Remediate Epic — Architecture-vs-Evidence Audit

You are a Principal Software Engineer remediating a single epic whose original brainstorm did not yet apply the architecture-vs-evidence probes. Walk the user through structured remediation per flagged probe and update the epic in place.

<HARD-GATE>
This skill operates on ONE epic per invocation. Do NOT batch multiple epics in a single session. Do NOT remediate an epic that is not tagged `arch-evidence:remediation-needed`. Do NOT skip the verification phase. Do NOT close the epic — remediation is description-level, not a status transition.
</HARD-GATE>

<ANTI-REDUNDANCY-GATE>
Before forming any question to the user: re-read the audit's `suggested_remediation` for the current probe. If the suggestion already names the remediation and the user has not pushed back, present it for confirmation rather than re-asking the underlying design.
</ANTI-REDUNDANCY-GATE>

## Configuration

The audit data path is configurable via the dso-config.conf key `remediate_arch_evidence.audit_path` (default: `docs/findings/architecture-vs-evidence-audit-2026-05-16.json`). The skill reads this file at Phase 0; absence is a fail-fast condition.

The tag namespace is `arch-evidence:remediation-needed` (input gate) → `arch-evidence:remediation-complete` (full remediation) or `arch-evidence:remediation-partial` (some probes deferred).

## Usage

```
/dso:remediate-arch-evidence <epic-id>
```

`<epic-id>` is required. The id format matches the project's ticket-id pattern; bridge IDs (e.g., `jira-dig-2562`) are accepted.

---

## Phase 0: Input Validation + Audit Data Load

### Step 0.1 — Validate epic id

```bash
EPIC_ID="$1"
if [ -z "$EPIC_ID" ]; then
    echo "ERROR: /dso:remediate-arch-evidence requires <epic-id> argument." >&2
    exit 2
fi

.claude/scripts/dso ticket exists "$EPIC_ID" >/dev/null 2>&1 || {
    echo "ERROR: epic $EPIC_ID not found in ticket tracker." >&2
    exit 2
}
```

### Step 0.2 — Verify input tag

```bash
EPIC_JSON=$(.claude/scripts/dso ticket show "$EPIC_ID" 2>/dev/null)
HAS_TAG=$(echo "$EPIC_JSON" | python3 -c "import json,sys; t=json.load(sys.stdin).get('tags') or []; print('yes' if 'arch-evidence:remediation-needed' in t else 'no')")
if [ "$HAS_TAG" != "yes" ]; then
    echo "ERROR: epic $EPIC_ID does not carry the arch-evidence:remediation-needed tag." >&2
    echo "       This skill is for audit-flagged epics only. See: docs/findings/architecture-vs-evidence-audit-*.md" >&2
    exit 2
fi
```

### Step 0.3 — Load audit findings for this epic

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
AUDIT_PATH_CONFIG=$(grep -E '^remediate_arch_evidence\.audit_path=' "$REPO_ROOT/.claude/dso-config.conf" 2>/dev/null | cut -d= -f2-)
AUDIT_PATH="${AUDIT_PATH_CONFIG:-docs/findings/architecture-vs-evidence-audit-2026-05-16.json}"

if [ ! -f "$REPO_ROOT/$AUDIT_PATH" ]; then
    echo "ERROR: audit findings file not found at $AUDIT_PATH" >&2
    echo "       Configure via remediate_arch_evidence.audit_path in dso-config.conf." >&2
    exit 2
fi

# Extract the record for this epic only — do not load all 39 records into context
RECORD=$(python3 -c "
import json
with open('$REPO_ROOT/$AUDIT_PATH') as f:
    data = json.load(f)
for r in data:
    if r['epic_id'] == '$EPIC_ID':
        print(json.dumps(r, indent=2))
        break
" )
if [ -z "$RECORD" ]; then
    echo "ERROR: no audit record found for epic $EPIC_ID in $AUDIT_PATH" >&2
    exit 2
fi
echo "$RECORD"
```

Hold the `RECORD` JSON in your working context — it has `flagged_probes`, `severity`, `evidence_per_probe`, and `suggested_remediation`.

If `flagged_probes` is empty (severity=none), STOP and emit: "Audit record shows no flagged probes for epic $EPIC_ID. Remove the arch-evidence:remediation-needed tag and exit." Then untag and exit.

---

## Phase 1: Present Audit Summary to User

Render this single user-facing message (no questions yet — purely informational):

```
Remediating epic <id> against architecture-vs-evidence audit (2026-05-16).

Severity: <high|medium>
Flagged probes: <list>

For each flagged probe, the audit's evidence and suggested remediation are below. I'll walk through them one at a time, ask which to address now, and apply confirmed remediations to the epic description.

[Probe N: <name>]
  Evidence: <evidence_per_probe[N]>
  Suggested: <suggested_remediation excerpt for probe N, if separable>

(repeat per flagged probe)
```

Probe name reference (use these labels):
- Probe 1: Architectural-class self-use
- Probe 2: Workflow-trigger audit
- Probe 3: Shared-state-variable lifecycle
- Probe 4: Bypass governance pairing
- Probe 5: Spec-phase coverage
- Probe 6: External-outcome SC capture

After the summary, ask exactly one question:

> Which of these probes should we address in this session? Reply with probe numbers (e.g., "1 3 6" or "all"), or "none" to abort.

Wait for response. If user selects a subset, deferred probes stay in the audit and the epic will end with `arch-evidence:remediation-partial`. If "all", end with `:remediation-complete` if every probe resolves cleanly.

---

## Phase 2: Per-Probe Remediation Dialogue

For each selected probe, in this priority order (1 → 5 → 3 → 4 → 6 → 2), run the corresponding remediation sub-flow.

<HARD-GATE>
One probe at a time. Do not present a draft for two probes in one message. Each probe gets its own confirm-edit-verify cycle.
</HARD-GATE>

### Probe 1 — Architectural-class self-use

Read the epic's current Success Criteria. Drafting prompt:

> The epic ships orchestration changes ({evidence}). To pair the deliverable with a self-application validation, here's a proposed self-use SC:
>
> > "SC<N>: This epic's own sprint exercises {the deliverable} on at least one real case before closure — {one concrete observable artifact: a specific commit-validation log entry, a workflow firing, a ticket transition, a generated artifact file at a named path}. Verification: {command or artifact-file check}."
>
> Append as-is, revise, or skip?

Wait for user response. On "append" or revised wording, edit the epic description in place via `dso ticket edit --description` (preserving all other content). On "skip", record this probe as DEFERRED.

### Probe 2 — Workflow-trigger audit

Enumerate every CI workflow file in the project's detected CI directory (project-agnostic: check `.github/workflows/`, `.gitlab-ci.yml`, `.circleci/`, `azure-pipelines*.yml`, `Jenkinsfile`, `bitbucket-pipelines.yml`). For each, extract the `pull_request.branches`, `push.branches`, `pull_request_target.branches` arrays via `yq` (if available) or `grep`.

Drafting prompt:

> The epic introduces ref pattern {pattern}. Existing workflow trigger filters that need review:
>
> | Workflow file | Current filters | Should include {pattern}? |
> |---|---|---|
> | <file> | <filters> | unknown |
>
> Propose adding {pattern} to: {list, derived from heuristic — workflow uses `pull_request` AND its base list omits the new pattern}.
>
> Confirm the list, revise, or skip?

On confirm, edit the epic description to add an Operational Constraints note listing each workflow file + the change required. Do NOT edit the workflow files themselves — that's sprint-execution work.

### Probe 3 — Shared-state-variable lifecycle

Identify state variables from the audit's evidence string and from epic SCs (config keys, marker files, env vars, repo variables, repo-level tags). For each, ask one question:

> State variable: `{var-name}` ({source}).
>
> Lifecycle owner table:
> - CREATE: who writes it first? ({proposed default if obvious}, or please specify)
> - UPDATE: which phases/scripts mutate it? ({list})
> - CONSUME: which workflows/scripts read it? ({list})
> - RETIRE: when and by whom is it cleared? ({proposed default if obvious}, or please specify)
>
> Confirm, revise, or skip this variable?

On confirm per variable, accumulate into a State Lifecycle Owner block. After all variables in the probe are covered, edit the epic description to add a State Lifecycle Owner section under Operational Constraints.

### Probe 4 — Bypass governance pairing

For each bypass mechanism identified in the audit evidence (env var, CLI flag, escape hatch):

> Bypass mechanism: `{name}` ({mechanism-type}).
>
> Governance pairing (per the architecture-vs-evidence rule):
> - Audit logging: each invocation writes to {proposed path}
> - Required justification companion: {proposed var/flag name with non-empty content}
> - Abuse detection: surveillance at sprint Phase I closure / debug-everything closure equivalent (count + reasons surfaced before authorizing closure)
>
> Confirm, revise, or skip?

On confirm, edit the epic description to add the governance pairing as a new SC or as a sub-clause of the existing bypass SC.

### Probe 5 — Spec-phase coverage

Read the epic's description and Approach section. Identify any ordered phase language. For each named phase:

> Phase named: `{phase-name}` ({where in spec}).
>
> Coverage options:
> - (a) Materialize as a distinct SC: drafted as `{draft SC}`
> - (b) Materialize as a story in preplanning (recorded as a preplanning-checkpoint note in the epic description)
> - (c) Inline the phase's deliverable into an existing SC (specify which)
>
> Choose, or skip this phase?

On choice, apply the edit. Do NOT auto-create story tickets — that's preplanning work. Record the chosen mapping in the epic description so preplanning honors it.

### Probe 6 — External-outcome SC capture

For each SC whose verification depends on external state, draft an External Dependencies block entry:

> External dependency: `{id-slug}` (verifies `SC<N>`).
> - description: `{one-line}`
> - ownership: external | internal — defaults to external (operator) for operator-manual; internal for code-managed
> - handling: `user_manual` | `claude_auto` — defaults to user_manual for ownership=external
> - claude_has_access: true | false — defaults to false for ownership=external + user_manual
> - verification_command: `{proposed command}` (must be read-only)
> - verification_safety: read-only | mutating — must be read-only
>
> Confirm, revise per field, or skip?

On confirm, accumulate into an External Dependencies block. Render the block per `${CLAUDE_PLUGIN_ROOT}/docs/contracts/external-dependencies-block.md` after all entries are collected.

---

## Phase 3: Apply Remediations

After every selected probe has been resolved (CONFIRMED or DEFERRED):

1. Compose the revised epic description: original description + new SCs (probes 1, 4) + new Operational Constraints sections (probes 2, 3, 6) + Spec Phase Coverage mapping (probe 5) + External Dependencies block (probe 6).

2. Update the epic via `.claude/scripts/dso ticket edit "$EPIC_ID" --description "$REVISED"`.

3. If any SC was added, validate the ticket: `.claude/scripts/dso ticket quality-check "$EPIC_ID"`. On failure, report the failure to the user and offer to revise the latest SC draft.

<HARD-GATE>
Never edit the epic description to remove existing content. Remediation is additive. If a probe's remediation requires removing or altering existing SCs, surface the conflict to the user and pause; do not auto-resolve.
</HARD-GATE>

---

## Phase 4: Verify

For each probe that was CONFIRMED in Phase 2, dispatch a single sub-agent to re-verify the probe against the revised epic description:

```
Agent invocation per CONFIRMED probe:
  description: "Verify probe <N> on epic <id> post-remediation"
  subagent_type: general-purpose
  model: sonnet (default; bump to opus if the orchestrator's session-level preference is opus)
  prompt: <inline the probe definition + the revised epic description + ask "does the probe still flag, yes/no, with evidence?">
```

Aggregate results:
- If all CONFIRMED probes return "no flag" → remediation-complete path.
- If any CONFIRMED probe still flags → report the residual gap to the user and offer to refine the remediation. Do not advance to Phase 5.

DEFERRED probes are excluded from verification — they remain in the audit data and will be re-flagged on the next audit cycle.

---

## Phase 5: Tag + PIL Update + Completion

### Step 5.1 — Compose the PIL comment

```
### Planning Intelligence Log — Architecture-vs-Evidence Remediation (2026-05-16 audit)

- audit_source: docs/findings/architecture-vs-evidence-audit-*.md
- audit_record: {flagged_probes from Phase 0}
- session_outcome:
    confirmed_probes: <list with the SC numbers / sections they added>
    deferred_probes: <list with reason from the user>
- verification:
    method: per-probe sub-agent re-check against revised description
    result: pass | partial
- next_step: <none | re-run /dso:remediate-arch-evidence after deferred work is ready>
```

Write via `.claude/scripts/dso ticket comment "$EPIC_ID" "$PIL_BODY"`.

### Step 5.2 — Update tags

```bash
.claude/scripts/dso ticket untag "$EPIC_ID" arch-evidence:remediation-needed

if [ "$RESULT" = "complete" ]; then
    .claude/scripts/dso ticket tag "$EPIC_ID" arch-evidence:remediation-complete
else
    .claude/scripts/dso ticket tag "$EPIC_ID" arch-evidence:remediation-partial
fi
```

If `arch-evidence:remediation-partial` is applied, the epic is eligible for re-invocation of this skill once the deferred probes have inputs ready (e.g., an external system the user couldn't specify during this session).

### Step 5.3 — Completion line

Emit exactly one line and end:

```
Architecture-vs-evidence remediation <complete|partial> for epic <id>.
```

Do not invoke any other skill. Do not auto-transition the epic. Do not auto-file follow-up tickets.

---

## Guardrails

- **One epic per invocation.** Multi-epic remediation is intentionally not supported; each impacted epic gets a fresh session.
- **Description-additive only.** This skill never removes content from an epic description. If a probe's remediation conflicts with existing content, surface the conflict; do not auto-resolve.
- **No sprint/preplanning calls.** Remediation operates on the epic record alone. Story decomposition (probe 5 option b) is recorded as a preplanning-checkpoint note for the next /dso:preplanning invocation to honor.
- **Plugin-agnostic paths.** All CI workflow detection uses host-project-relative paths or `${CLAUDE_PLUGIN_ROOT}/`; the audit-data path is configurable; no hardcoded plugin-installation paths in this skill's logic.
- **User attention is finite.** Probes are presented in priority order (1 → 5 → 3 → 4 → 6 → 2) so the highest-leverage gaps get attention first; the user can stop after any subset.
- **No back-channel ticket writes.** All ticket mutations go through `.claude/scripts/dso ticket edit|tag|untag|comment` — no direct file edits to the ticket-tracker storage directory.

---

## Quick Reference

| Phase | Goal | Key Activities |
|-------|------|---------------|
| 0: Input + Audit Load | Validate epic id + audit data | Tag check, audit JSON lookup for this one epic |
| 1: Audit Summary | Present flags to user | Inform-only message + scope question |
| 2: Per-Probe Remediation | Apply remediation per selected probe | One probe at a time, priority order 1→5→3→4→6→2 |
| 3: Apply | Edit epic description | `ticket edit --description`, validate via quality-check |
| 4: Verify | Re-check post-edit | Sub-agent per CONFIRMED probe, aggregate to complete vs partial |
| 5: Tag + PIL + Complete | Record outcome | Tag rotation, PIL comment, single completion line |
