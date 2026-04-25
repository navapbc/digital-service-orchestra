---
name: architect-foundation
description: Deep-dive architectural scaffolding for an existing project — reads .claude/project-understanding.md (written by /dso:onboarding), uses Socratic dialogue to uncover enforcement preferences and anti-pattern risks, and generates targeted enforcement scaffolding without re-running project detection.
user-invocable: true
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
---

<SUB-AGENT-GUARD>
Requires Agent tool. If running as a sub-agent (Agent tool unavailable), STOP and return: "ERROR: /dso:architect-foundation requires Agent tool; invoke from orchestrator."
</SUB-AGENT-GUARD>

# Architect Foundation

Establish positive architectural patterns and the enforcement mechanisms that keep them in place, building on the project detection already done by `/dso:onboarding`.

## Usage

```
/dso:architect-foundation           # interactive
/dso:architect-foundation --auto    # non-interactive (see Auto-Mode Behavior below)
```

Supports dryrun: `/dso:dryrun /dso:architect-foundation`.

## Inputs

- **Required**: `.claude/project-understanding.md` (from `/dso:onboarding`).
- **Reference prompts**: load on demand.
  - Anti-pattern codes AP-1…AP-5: `skills/shared/prompts/anti-patterns.md`.
  - Fitness-function templates: `skills/architect-foundation/fitness-function-templates.md`.
  - CI skeleton blocks: `skills/shared/prompts/ci-skeleton-templates.md`.

## Workflow

```
P0 Read understanding + detect existing artifacts
P1 Socratic gap-fill (one open question at a time)
P2 Recommendation synthesis (per-item accept/reject/discuss)
P3 Write scaffolding (single batched confirmation)
P4 Wire enforcement + ADRs + peer review
```

There is **one approval gate per phase**, not three. The P2 per-recommendation loop replaces a blueprint-level validation loop.

## Auto-Mode Behavior

When invoked with `--auto`:

| Phase | Behavior under --auto |
|-------|------------------------|
| P0 | Same. Fail with an actionable error if `project-understanding.md` is missing or incomplete (list needed fields). |
| P1 | Skipped — select recommended defaults from the understanding file. Report the chosen defaults in a summary table. |
| P2 | Accept all synthesized recommendations without per-item review. |
| P3 | Skip the "proceed with writing N files?" confirmation; skip `prefill-config.sh` post-write confirmation. |
| P4 | Still runs `/dso:review`; applies critical/important findings automatically. |

Log each skipped gate as `[DSO INFO] auto-mode: skipped <gate>`.

---

## Phase 0 — Read understanding and detect prior artifacts

1. Read `.claude/project-understanding.md`. Extract the facts already known (stack, interface type, test dirs, CI, any recorded architecture decisions). These must NOT be re-asked in P1.
2. Do **not** re-run stack detection — trust the understanding file.
3. Run `.claude/scripts/dso onboarding/detect-enforcement-artifacts.sh`. Parse JSON for `arch_enforcement_md`, `adr_dir`, `adr_count`, `claude_md_invariants_section`. If any is `true`, enter **re-run mode** (append-only merge; see "Re-run rules" below).
4. Opening message to the user: "I've read `.claude/project-understanding.md`. Already known: [list 3–5 facts]. [Prior artifacts detected: …] I have N questions before generating enforcement."

## Phase 1 — Socratic gap-fill

Ask **one open-ended question at a time.** No multiple-choice menus. Follow-ups are shaped by what the user says.

Question bank — ask only gaps not answered by P0. Each question is tagged with the AP codes it informs (see `skills/shared/prompts/anti-patterns.md` for definitions):

**Group A — Abstraction surface (drives anti-pattern risk):**

- **A1** Will the system support ≥2 interchangeable implementations of the same concept (providers, formats, strategies)? *Informs AP-2, AP-3, AP-4.*
- **A2** How will components share state — via a mutable object or immutable messages? *Informs AP-1.*
- **A3** Roughly how many environment-specific config values are expected? *Informs AP-5.*

**Group B — Enforcement preference:**

- **B1** Where should enforcement surface — edit-time, test-time, or CI-time? Which layer does the team trust most?
- **B2** Which AP codes concern the team most? Any project-specific anti-patterns to add?
- **B3** Rules the team knows they want but haven't codified (e.g., "no direct DB from handlers")? What's the history behind each?

**Group C — Scope:**

- **C1** Full enforcement layer, or only the rules needed to codify B3?

## Phase 2 — Recommendation synthesis

For each candidate enforcement mechanism, produce a recommendation citing the actual project file/pattern that triggered it. Template:

```
Recommendation N: <title>
AP code: <AP-x or project-specific>
Trigger: <cite file path or code pattern from the project>
Layer: <edit | test | CI>
Mechanism: <concrete — registry, frozen dataclass, typed config, grep-based boundary test, …>
Test isolation: <how tests remain isolated from the mechanism>
Fit: <why this project specifically benefits>
```

Present recommendations **one at a time**. For each: Accept / Reject / Discuss. After the full pass, confirm the consolidated accepted set, then proceed to P3.

Under `--auto`, accept all without review.

## Phase 3 — Write scaffolding

### Step 0 — Inventory existing plugin infrastructure (configure before creating)

```bash
.claude/scripts/dso onboarding/plugin-inventory.sh --format table
```

Parse the inventory. For each accepted P2 recommendation, check whether a plugin component already covers it. Only build custom enforcement for gaps the plugin doesn't cover. Wired hook detection is best-effort; confirm with the user if coverage is ambiguous.

### Step 1 — Pre-fill commands in dso-config.conf

```bash
.claude/scripts/dso onboarding/prefill-config.sh --project-dir "${PROJECT_DIR:-$(pwd)}"
```

This writes `commands.test_runner`, `commands.lint`, `commands.format`, `commands.format_check` for the detected stack, skipping keys that already have a value. Per-stack defaults and exact invocations live inside `prefill-config.sh` — do not duplicate them in this file. For `rust-cargo`, `golang`, `convention-based`, or `unknown` stacks the script emits empty values with a comment; prompt the user to fill them (unless `--auto`).

### Step 2 — Bootstrap `.test-index` if missing

```bash
if [[ ! -f .test-index ]]; then
    .claude/scripts/dso generate-test-index.sh
fi
```

### Step 3 — Generate fitness functions and enforcement files

Load `skills/architect-foundation/fitness-function-templates.md` **only** when this step fires. For each accepted recommendation tagged AP-1 / AP-2 / AP-3 / AP-4 / AP-5, copy the matching template (choose stack) and customize for the project's module paths. Files land under `tests/architecture/`.

Also generate / update:

- **`ARCH_ENFORCEMENT.md`** at repo root — one section per accepted recommendation using the P2 template. Detected by `check-onboarding.sh` as evidence that scaffolding has been completed.
- **`CLAUDE.md` Architectural Invariants section** — one-line rules derived from the accepted recommendations.

If generating CI, load `skills/shared/prompts/ci-skeleton-templates.md` and include only the per-stack blocks whose dependency files exist.

### Step 4 — Batched write gate (single confirmation)

Present a summary: File / Type / Action (new|update) / diff-or-full-content. Ask **once**: "Proceed with writing all N files?" On confirmation, write all files. On partial failure, preserve already-written files and report which failed. Under `--auto`, skip this gate.

## Phase 4 — Wire, ADRs, and peer review

### Step 1 — Wiring checklist

After files are written, verify each mechanism is actually enforced. Confirm and add as needed:

- **CI-time fitness functions**: a `.pre-commit-config.yaml` entry **or** a GitHub Actions step running `pytest tests/architecture/` (or the stack equivalent) before merge.
- **Edit-time rules**: corresponding entries in `ruff.toml` / `eslint.config.js` / `mypy.ini`.
- **Config keys**: each recommendation that relies on a config-driven check has its `dso-config.conf` key populated (not only prefilled blanks).

Enforcement is **inert until wired**. Do not consider the scaffolding complete until this checklist is green.

### Step 2 — Record ADRs

For every significant architectural choice made this session, write a short ADR via:

```bash
.claude/scripts/dso onboarding/adr-upsert.sh --topic "<decision topic>" --content-file <path>
```

`adr-upsert.sh` handles deduplication: if an ADR with the same slugified topic exists, it appends a dated revision note rather than creating a duplicate file. This is the sole mechanism for ADR generation; do not hand-craft filenames.

### Step 3 — Peer review

Stage the generated files and invoke `/dso:review`. Apply critical/important findings.

### Final summary

```
Architect Foundation complete.

Known from project-understanding.md: [facts]
Learned via Socratic dialogue:         [Q+A pairs]
Accepted recommendations (N):          [titles + AP codes]
Files generated/updated:               [paths]
Wiring confirmed:                      [CI entry, hook entries, config keys]
ADRs:                                  [paths]
```

---

## Re-run rules (when P0 Step 3 detects prior artifacts)

- **Append-only merge** for `ARCH_ENFORCEMENT.md`: new sections added, existing sections untouched. Skip duplicates (same recommendation title → no-op).
- **ADR dedup** is handled by `adr-upsert.sh` — no special-case logic here.
- **Report delta**: final summary shows "added N, unchanged M, duplicates skipped K".
