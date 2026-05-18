---
name: remediate-arch-evidence
description: Use to remediate epics flagged by the architecture-vs-evidence audit (tag `arch-evidence:remediation-needed`). Reads the audit findings for the named epic, applies probe-specific patterns established in the 2026-05-18 reference remediation pass (self-use SCs, state-lifecycle tables, bypass governance pairings, in-session CLI verification for external deps), and updates tags. Default scope is single-epic; batch mode permitted on opus-tier sessions with priming-mitigation discipline. Trigger phrases include "remediate epic <id>", "remediate <id> for architecture-vs-evidence", "fix arch-evidence gaps in <id>", "address audit findings on <id>".
user-invocable: true
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
---

<SUB-AGENT-GUARD>
Requires Agent tool (Phase 4 verification dispatch). If running as a sub-agent (Agent tool unavailable), STOP and return: "ERROR: /dso:remediate-arch-evidence requires orchestrator context (verification dispatch); invoke from orchestrator."
</SUB-AGENT-GUARD>

# Remediate Epic — Architecture-vs-Evidence Audit

You are a Principal Software Engineer remediating epics whose original brainstorms did not yet apply the architecture-vs-evidence probes. Apply the established probe-specific patterns (this file's Phase 2 reference templates) and update the epic in place.

<HARD-GATE>
Do NOT remediate an epic that is not tagged `arch-evidence:remediation-needed`. Do NOT skip the verification phase (Phase 4). Do NOT close the epic — remediation is description-level, not a status transition. Do NOT remove existing description content; remediation is additive.
</HARD-GATE>

<ANTI-REDUNDANCY-GATE>
Before forming any question to the user: re-read the audit's `suggested_remediation` for the current probe AND the reference pattern in Phase 2 below. If both already name the remediation and the user has not pushed back, draft the additive change and present it for confirmation rather than re-asking the underlying design.
</ANTI-REDUNDANCY-GATE>

## Batch mode

The skill defaults to single-epic per invocation but supports batching when:
- Session is on an opus-tier model with sufficient context (1M context tier);
- The user has explicitly authorized batching;
- The orchestrator applies priming-mitigation discipline: re-read each epic's audit findings fresh, resist pattern-matching to prior remediations, tailor each table/SC to that epic's specific state vars and SC structure.

The audit baseline assumes brainstorm-complete deliverables. If the target epic carries `brainstorm:complete` but its description self-declares as a stub awaiting follow-on brainstorm (e.g., "Run /dso:brainstorm <this-epic-id> before implementation"), apply the tag-integrity fix in Phase 0 Step 0.4 rather than substantive remediation.

## In-session verifiability rule

Every remediation added by this skill MUST have an in-session verification command — a shell-executable check that runs within the sprint that delivers the epic. This rule supersedes the audit's "structured External Dependencies block" pattern wherever the block would gate closure on truly external state.

**Tool surfaces that count as in-session-verifiable:**
- `.claude/scripts/dso ticket *` (ticket CLI)
- `gh` (GitHub CLI: PRs, workflows, rulesets, code-scanning, secrets, branch protection)
- `aws` (AWS CLI: Lambda, S3, IAM, sts, code-scanning equivalents)
- `acli jira` (Jira workflow status probes)
- `docker`, `docker manifest`, `curl` (container availability, HTTP healthchecks)
- `grep`, `jq`, `python3 -c`, `npx playwright`, language-specific CLIs
- File-system probes: `test -f`, `test -x`, `wc -l`, log/artifact reads
- Sub-agent dispatches that produce structured artifacts (ticket comments, log files)

**Tool surfaces that do NOT count as in-session-verifiable:**
- Real wall-clock time elapsing (e.g., "4 weeks of telemetry")
- Real human action (PR merge approvals from reviewers other than the orchestrator)
- Real consuming-project adoption in real CI runs at projects outside this repo

**Override pattern for genuinely-external residuals:** when a probe touches both in-session-verifiable and genuinely-external surfaces, apply the structured block to the in-session pieces AND document the external residual as "operational, not gating" with the rationale ("capability verified in-session; emergence observed post-ship"). This is the pattern documented on 411b-a047 (4-week wall-clock telemetry) and 69e8-af39 (SC7 human-approval PR merge) in the 2026-05-18 reference pass.

## Configuration

The audit data path is configurable via the dso-config.conf key `remediate_arch_evidence.audit_path` (default: `docs/findings/architecture-vs-evidence-audit-2026-05-16.json`). The skill reads this file at Phase 0; absence is a fail-fast condition.

The tag namespace is `arch-evidence:remediation-needed` (input gate) → `arch-evidence:remediation-complete` (all flagged probes resolved or substantively dispositioned) or `arch-evidence:remediation-partial` (some probes deferred under documented project rules — e.g., probe-5 zero-children-rule deferral).

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
EPIC_JSON=$(.claude/scripts/dso ticket show "$EPIC_ID" --format=llm 2>/dev/null)
HAS_TAG=$(echo "$EPIC_JSON" | python3 -c "import json,sys; t=json.load(sys.stdin).get('tg') or []; print('yes' if 'arch-evidence:remediation-needed' in t else 'no')")
if [ "$HAS_TAG" != "yes" ]; then
    echo "ERROR: epic $EPIC_ID does not carry the arch-evidence:remediation-needed tag." >&2
    echo "       This skill is for audit-flagged epics only." >&2
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
    exit 2
fi

RECORD=$(python3 -c "
import json
with open('$REPO_ROOT/$AUDIT_PATH') as f:
    data = json.load(f)
for r in data:
    if r['epic_id'] == '$EPIC_ID':
        print(json.dumps(r, indent=2))
        break
")
if [ -z "$RECORD" ]; then
    echo "ERROR: no audit record found for epic $EPIC_ID in $AUDIT_PATH" >&2
    exit 2
fi
echo "$RECORD"
```

If `flagged_probes` is empty (severity=none), STOP and emit: "Audit record shows no flagged probes for epic $EPIC_ID. Removing the arch-evidence:remediation-needed tag." Then untag and exit.

### Step 0.4 — Tag-integrity pre-check (stub-epic detection)

Read the epic description. If it contains language declaring itself a stub awaiting a dedicated brainstorm session (e.g., "This is a stub epic", "requires its own /dso:brainstorm session", "scrutiny skipped"), the `brainstorm:complete` tag is mis-applied and the audit baseline does not apply. In that case:

1. Comment on the epic recording the tag-integrity correction with rationale (cite description self-declaration + PIL "scrutiny skipped" entries).
2. Remove BOTH `brainstorm:complete` AND `arch-evidence:remediation-needed`.
3. List the audit's flagged-probe concerns as input for the future genuine brainstorm session.
4. Exit without substantive remediation.

Reference case: af26-dd5a-df6d-4f81 (2026-05-16 pass).

### Step 0.5 — Child count (probe-5 disposition)

```bash
CHILD_COUNT=$(.claude/scripts/dso ticket list-descendants "$EPIC_ID" 2>/dev/null | python3 -c "
import json,sys
d = json.load(sys.stdin)
print(sum(len(d.get(k,[])) for k in ['stories','tasks','bugs']))
")
echo "CHILD_COUNT=$CHILD_COUNT"
```

Hold this value for Phase 2's probe-5 routing decision.

---

## Phase 1: Present Audit Summary to User

Render one informational message (no questions yet):

```
Remediating epic <id> against architecture-vs-evidence audit (<audit date>).

Severity: <high|medium>
Flagged probes: <list>
Child count: <CHILD_COUNT>

For each flagged probe, the audit's evidence and the reference remediation pattern are below. After this summary, propose the remediation for each probe in priority order and apply on confirmation.

[Probe N: <name>]
  Evidence: <evidence_per_probe[N]>
  Suggested (audit): <suggested_remediation excerpt for probe N>
  Pattern (this skill, Phase 2): <one-line summary of the reference pattern>

(repeat per flagged probe)
```

Probe name reference:
- Probe 1: Architectural-class self-use
- Probe 2: Workflow-trigger audit
- Probe 3: Shared-state-variable lifecycle
- Probe 4: Bypass governance pairing
- Probe 5: Spec-phase coverage
- Probe 6: External-outcome SC capture

After the summary, ask one question:

> Which of these probes should we address in this session? Reply with probe numbers (e.g., "1 3 6"), "all" (the default), "none" to abort, or a list with edits ("1, 3, 6 — but on probe 6 the AWS deployment is verifiable in-session because we have aws CLI access").

---

## Phase 2: Probe-Specific Reference Patterns

Apply patterns in priority order (1 → 5 → 3 → 4 → 6 → 2). Draft the additive content, present once for user confirmation, then proceed; do not pause per micro-decision when the pattern already provides a complete template.

### Probe 1 — Architectural-class self-use

**When the epic ships orchestration changes** (CI workflow files, `.claude/**` content, plugin skills/agents/hooks, git hooks, scripts under `${CLAUDE_PLUGIN_ROOT}/scripts/`): add a self-use SC requiring the epic's own sprint to USE the deliverable on real (or fixture) artifacts before sprint close.

**Reference template:**

> **SC<N> (self-use, Probe-1 remediation, architecture-vs-evidence audit <date>):** During the <epic-id> sprint, <the deliverable> is exercised end-to-end on <real sprint artifacts | a specific named fixture> before sprint close.
>
> Verification (in-session, at sprint Phase I):
> - `<concrete in-session command>` returns <expected>.
> - `<concrete in-session command>` returns <expected>.

**Fallback rule:** if no organic sprint artifact will exercise the deliverable, allow a synthetic fixture path BUT require explicit justification in sprint closure notes if used. Reference: f27a-3c6a SC9.

### Probe 2 — Workflow-trigger audit

**When the epic introduces a new git ref pattern or modifies CI workflow triggers:** enumerate trigger filters for every workflow file that should fire on the new pattern, citing the project's trigger convention.

**Reference template:**

> **Workflow Trigger Filter Enumeration (Probe-2 remediation):**
>
> | Trigger | Setting | Rationale |
> |---|---|---|
> | `pull_request` | `<types and branches setting>` | <rationale citing project convention + relevant bug if applicable> |
> | `pull_request_target` | <Not used / used> | <security rationale> |
> | `push` | <Not used / used> | <cost/PR-time-only rationale> |
>
> Verification (in-session): `grep -A 20 '^on:' <workflow-file>` shows the documented configuration.

**Project convention check:** in this repo, `pull_request` workflows OMIT base-branch filters (per `ci.yml` bug 3914-0848-faad-4f6a — restricting to `branches: [main]` skipped per-story PRs).

### Probe 3 — Shared-state-variable lifecycle

**When the epic introduces shared state** (config keys, ticket tags, log files, repo variables, environment variables, lock files, ticket comments as manifests): add a State Lifecycle Owner Block enumerating CREATE / UPDATE / CONSUME / RETIRE per variable.

**Reference template:**

> **State Lifecycle Owner Block (Probe-3 remediation):**
>
> | Variable | CREATE | UPDATE | CONSUME | RETIRE |
> |---|---|---|---|---|
> | `<var>` | <who writes first> | <who mutates and how — explicit merge vs overwrite vs append on re-onboarding> | <who reads> | <retirement story> |
>
> Verification (in-session): `<commands that prove each owner reference resolves>`.

**RETIRE owner conventions (use these phrasings):**

- **`N/A — persistent by design`** — for config keys, versioned schemas, event-sourced ticket comments, immutable historical records. Always paired with a documented rationale (e.g., "append-only per ticket-system v3 semantics", "versioned contract; retired only via formal version bump").
- **Implicit with ticket close** — for ticket-field values and tags that persist on closed tickets as historical record.
- **Released on script exit** — for short-lived locks/in-memory state.
- **Operator-managed cleanup** — for artifacts the operator manages manually (log rotation, archive directories).
- **Cascade-deleted with parent** — for child tickets/comments cleaned up when the parent is deleted.
- **Cleared on next session-start / worktree teardown** — for session-bound state.

**UPDATE owner conventions for re-runs:**

- **Merge by default with explicit reset flag** — preferred. Re-running onboarding preserves existing values unless `--reset-<scope>` flag passed (reference: 6add-c1fc semgrep.*).
- **Append-only** — new entries added, no overwrites (reference: 7510 semgrep.custom_rulesets).
- **Refresh on stack change** — keys rewritten only on detected stack change (reference: 87e9 commands.test_runner with `/dso:onboarding --refresh-stack`).

### Probe 4 — Bypass governance pairing

**When the epic introduces a bypass mechanism** (env var, CLI flag, `--force`, `--no-*`, escape hatch): pair with audit logging, required justification, and Phase I abuse-detection.

**Reference template:**

> **Bypass Governance — `<bypass-name>` (Probe-4 remediation):**
>
> - **Audit log:** every invocation writes a structured JSON line to `<log-path>` with `{timestamp, <bypass-specific fields>, justification, session_id}`.
> - **Required justification companion:** `<bypass-name>` requires `--reason="..."` (or equivalent) with non-empty content; the bypass command exits non-zero without it. **Hard enforcement** (not soft) — refuse to proceed.
> - **Abuse-detection at sprint Phase I / end-session:** sprint closure inspects the log; surfaces a MUST-display block when count exceeds threshold (default: 3 per session, configurable) OR when concentration patterns indicate engineered bypass (e.g., one bypass accounting for >50% of invocations). Operator confirms the surfaced block before authorizing sprint closure.
> - **Verification (in-session):** synthetic test invokes the bypass without `--reason` and asserts non-zero exit + error message; with `--reason="test"` succeeds and the log captures the entry.

References: a524 (`--force` on test-run), d765 (`--no-sdk` / `--no-overlay` / `--overlay-mode=overwrite`), 8d21 (engine-missing LLM fallback).

### Probe 5 — Spec-phase coverage

**Zero-children rule:** if `CHILD_COUNT == 0`, skip probe 5 entirely. Phase decomposition into stories belongs to the sprint's preplanning step, not to this remediation. The audit's "preplanning explicitly deferred" finding is a documented project pattern.

**When `CHILD_COUNT > 0`:** the spec names ordered phases but the existing stories don't reflect the phase breakdown. Apply the level-tagging pattern.

**Reference template:**

> **Spec-phase coverage mapping (Probe-5 remediation):**
>
> The Approach section names <N> ordered phases (<phase 1 name>, <phase 2 name>, ...). Each child story/task must carry a `<phase-namespace>:<N>` tag to make phase ordering enforceable. Mapping at the time of this remediation (preplanning to confirm):
>
> | Phase | Children |
> |---|---|
> | Phase 1 — <name> | <ticket-ids> |
> | Phase 2 — <name> | <ticket-ids> |
> | ... | ... |
>
> Sprint dispatch order: Phase 1 batch before Phase 2 batch before Phase N batch. Preplanning task (added to sprint setup): apply tags to each child before dispatch.
>
> Verification (in-session, at sprint Phase A):
> - `.claude/scripts/dso ticket list --parent=<epic-id> --format=llm | python3 -c "...sum tag-prefix matches..."` returns ≥ child count.
> - Sprint dispatch logs show batch ordering.

Reference: c13f-6196 (level:1/2/3 across 8 child tasks).

### Probe 6 — External-outcome SC capture

**Reframing rule:** the audit's literal "structured External Dependencies block" suggestion frequently violates the in-session-verifiability rule because it gates closure on external state. Replace with:

1. **An in-session CLI verification table** for every touchpoint the available CLIs (gh, aws, acli, docker, curl, ticket CLI) can reach.
2. **Override carve-out** for genuinely-external residuals (real wall-clock elapse, real human approval, real third-party adoption): document as "operational, not gating" with a capability-verified-in-session counterpart.

**Reference template:**

> **External-dependency verification (Probe-6 remediation):**
>
> Before Phase I:
>
> | Resource | In-session verification command | Expected |
> |---|---|---|
> | <resource> | `<gh / aws / acli / curl / docker command>` | <expected output> |
> | ... | ... | ... |
>
> The sprint cannot declare Phase I complete with any of the <N> checks failing. <Concrete resource names anchored to dso-config.conf keys written by the setup scripts and consumed by all verification commands.>

**Override addendum (when a touchpoint is genuinely external):**

> Explicit override note: <SC-id>'s <touchpoint> is acknowledged as operationally external. Sprint closure does NOT gate on <emergence>; closure DOES require that <capability-in-session check> AND <operational artifact captured>. This is the "capability verified in-session; emergence operational" pattern, documented for <reference epic>.

References: d2f9 (AWS Lambda + S3 verified via AWS CLI), 0cbc (Jira workflow via acli), 53ef (CLAUDE_CODE_SESSION_ID empirical-probe artifact + operator-backfill log), 69e8 (override on SC7 human PR-merge approval), 411b (override on 4-week wall-clock telemetry emergence).

---

## Phase 3: Apply Remediations

For each selected probe, compose the additive content and apply via `.claude/scripts/dso ticket edit "$EPIC_ID" --description="$REVISED"`.

**Section-header detection:** epic descriptions may use either `## Section Name` (markdown) or `SECTION NAME:` (uppercase prose) styles. Insertion logic must check both:

```python
sections_md = ['\n## Dependencies\n', '\n## Scenario Analysis\n', '\n## Approach\n']
sections_uc = ['DEPENDENCIES:', 'SCENARIO ANALYSIS:', 'APPROACH:']

for s in sections_md:
    if s in src:
        src = src.replace(s, ADDITION + s, 1); break
else:
    for s in sections_uc:
        if s in src:
            src = src.replace(s, ADDITION + '\n' + s, 1); break
    else:
        src += ADDITION
```

After edit, validate the ticket: `.claude/scripts/dso ticket quality-check "$EPIC_ID"`. The "legacy - no AC/file impact" warning is preexisting (not introduced by remediation) and does not block.

<HARD-GATE>
Never edit the epic description to remove existing content. Remediation is additive. If a probe's remediation requires removing or altering existing SCs, surface the conflict to the user and pause; do not auto-resolve.
</HARD-GATE>

---

## Phase 4: Verify

For each probe that was CONFIRMED in Phase 2, dispatch a sub-agent to re-verify the probe against the revised epic description. Batch verifications across probes (parallel sub-agents) to minimize wall-clock time.

```
Agent invocation per CONFIRMED probe (parallel batch when possible):
  description: "Verify probe <N> on epic <id> post-remediation"
  subagent_type: general-purpose
  model: sonnet (deep-tier opus reserved for cases where sonnet returned FLAG and re-evaluation is needed)
  prompt: <inline probe definition + revised epic file path on disk + the explicit "does the probe still flag, yes/no, with evidence?" question + the project-rule note that AWS/gh/acli/CLI commands count as in-session-verifiable>
```

The sub-agent reads the revised epic FROM DISK (`/tmp/<epic-id>-revised.md` or the live ticket via `dso ticket show`), not from the prompt — keeps the orchestrator's context light.

Aggregate results:
- All CONFIRMED probes returned NO_FLAG → remediation-complete path.
- Any CONFIRMED probe still flagged → report the residual gap to the user, offer to refine the remediation, do not advance to Phase 5.

DEFERRED probes are excluded from verification.

---

## Phase 5: Tag + PIL Update + Completion

### Step 5.1 — Compose the PIL comment

```
### Planning Intelligence Log — Architecture-vs-Evidence Remediation (<date>)

- audit_source: <audit path>
- audit_record: flagged_probes = [<list>], severity = <high|medium>
- session_outcome:
    confirmed_probes:
      - probe_<N>: <one-line summary citing the added section + concrete artifact (SC number, table name)>
    deferred_probes:
      - probe_<N>: <reason — zero-children rule, external-residual override, etc.>
- verification:
    method: per-probe sub-agent re-check against revised description (sonnet)
    result: pass (all CONFIRMED probes NO_FLAG with section citations)
- next_step: <none | follow-on action>
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

**`:remediation-complete` qualifies when:** all flagged probes are either (a) substantively remediated and verified NO_FLAG, OR (b) deferred under a documented project rule (zero-children for probe 5, override-pattern for genuinely-external probe-6 residuals) where the in-session-verifiable portions of the probe have been remediated.

**`:remediation-partial` qualifies when:** at least one probe is deferred without a documented project rule covering it (typically: a probe the user explicitly declined to address in this session, or a probe whose remediation required input the user couldn't yet provide).

### Step 5.3 — Completion line

Emit exactly one line and end:

```
Architecture-vs-evidence remediation <complete|partial> for epic <id>.
```

Do not invoke any other skill. Do not auto-transition the epic. Do not auto-file follow-on tickets unless the PIL explicitly named one.

---

## Phase 6 (optional): Already-decomposed-epic guidance

If the epic has child stories/tasks AND remediation added new SCs that aren't covered by existing children, the orchestrator (NOT this skill) should follow up. Surface this guidance to the user at session end:

| Probe added | Recommended follow-up |
|---|---|
| Probe 1 (self-use SC) | **Create a new story** at the END of the dependency chain (`depends_on` all other stories). Dogfooding only happens after deliverables are built. |
| Probe 3 (state lifecycle) | **Update existing stories** whose tasks create/consume the state vars — fold RETIRE expectations into their done definitions. No new stories needed. |
| Probe 4 (bypass governance) | **Create a new story** for audit-log + justification + abuse-detection wiring. Usually a single small story. |
| Probe 5 (phase mapping) | **Tag existing stories** with `level:N` / `phase:N` + add sprint dispatch-order rule. No new stories. |
| Probe 6 (external-dep verification) | **Create a new story** (if checks belong in `validate.sh` or a permanent CI gate) OR add a **preplanning preflight item** (if the checks only run at sprint Phase A and don't ship in code). |

Rerunning full preplanning is rarely the right call — it discards existing story-level work and dependency wiring. Only justified when remediation reshaped the epic's structure (e.g., probe 5 phase-mapping requires reorganizing many stories).

---

## Guardrails

- **Description-additive only.** This skill never removes content from an epic description. If a probe's remediation conflicts with existing content, surface the conflict; do not auto-resolve.
- **No sprint/preplanning calls.** Remediation operates on the epic record alone. Phase 6 guidance is informational, not auto-executed.
- **Plugin-agnostic paths.** All CI workflow detection uses host-project-relative paths or `${CLAUDE_PLUGIN_ROOT}/`; the audit-data path is configurable.
- **User attention is finite.** Probes are presented in priority order (1 → 5 → 3 → 4 → 6 → 2) so the highest-leverage gaps get attention first; the user can stop after any subset.
- **No back-channel ticket writes.** All ticket mutations go through `.claude/scripts/dso ticket edit|tag|untag|comment`.
- **Avoid background ticket-CLI loops.** Iterating `dso ticket tag/untag/comment` over many epics inside a bash loop with `run_in_background=true` has been observed to terminate before the loop completes. Process per-epic ticket mutations in the foreground OR batch as one heredoc-driven Bash call.

---

## Quick Reference

| Phase | Goal | Key Activities |
|-------|------|---------------|
| 0: Input + Audit Load | Validate epic id + audit data + child count + stub detection | Tag check, audit JSON lookup, descendants count, tag-integrity pre-check |
| 1: Audit Summary | Present flags + reference patterns | Inform-only message + scope question |
| 2: Per-Probe Remediation | Apply patterns per selected probe | Probe-specific reference templates (priority 1→5→3→4→6→2) |
| 3: Apply | Edit epic description | `ticket edit --description`; section-header detection for `##` and uppercase styles |
| 4: Verify | Re-check post-edit | Parallel sub-agent batch per CONFIRMED probe (sonnet default) |
| 5: Tag + PIL + Complete | Record outcome | Tag rotation per disposition rules, PIL comment, single completion line |
| 6 (optional): Follow-up guidance | Inform orchestrator about decomposition implications | Probe-to-story-action table |
