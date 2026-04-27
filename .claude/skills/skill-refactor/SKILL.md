---
name: skill-refactor
description: Use when the user wants to critically review and refactor an existing DSO skill for clarity, token efficiency, and reliability — includes script relocation, reference updates, change-detector test removal, and ticket reconciliation. Invoke when the user says "review the <skill> skill", "optimize <skill>", "clean up <skill>", or similar language about auditing or improving a specific skill file.
user-invocable: true
allowed-tools: Read, Write, Edit, Glob, Grep, Bash, Agent
---

# Skill Refactor

End-to-end process for auditing and improving a DSO skill: review → approved plan → code/doc/test changes → ticket reconciliation → committed result.

This skill codifies a workflow executed successfully on `/dso:architect-foundation` and the onboarding-adjacent scripts. Apply it to any skill where the user wants a token-efficiency and reliability pass.

## When to use

User signals: "review the X skill", "audit X", "can we optimize X?", "clean up X", "X is bloated", "X isn't reliable", or any request that implies critiquing a specific skill file and improving it.

## Inputs

- Skill name (bare, no `dso:` prefix) — e.g., `architect-foundation`, `brainstorm`.
- The skill's SKILL.md at `plugins/dso/skills/<name>/SKILL.md`.
- Any co-located phase files under `plugins/dso/skills/<name>/phases/` or equivalent.

## Workflow

The workflow is **eight sequential phases**. Do not skip. Phases 1 and 2 are synchronous with the user; Phases 3–8 execute autonomously once the plan is approved.

```
P1 Critical review            → present findings
P2 Remediation plan           → await explicit approval
P3 Script relocation          → move skill-scoped scripts to shared sub-dir
P4 Reference updates          → skill body, tests, docs
P5 Change-detector test sweep → remove prose-grepping tests
P6 Ticket reconciliation      → comment on open tickets affected
P7 Renumbering                → renumber phases (A,B,C…) and steps (1,2,3…); update cross-skill refs
P8 Commit                     → via COMMIT-WORKFLOW.md; surface review findings
```

---

## Hard gates: compress, do not remove

A **hard gate** is anything in a skill that enforces a contract or triggers a downstream check. Hard gates may be **compressed** (verbose prose collapsed to a one-liner) but must NOT be **removed** during refactor — even when they appear duplicated, restated, or "owned elsewhere." Removing a hard gate silently loosens the skill's safety surface; compressing it preserves the gate while reducing token cost.

**Identifying hard gates** — treat any of the following as a gate, regardless of how prose-heavy it looks:

- **Schema/hash assertions** that match a value in a script or config (e.g., `Caller schema hash: <hash>` lines mirroring `validate-review-output.sh` constants — these are cross-skill conventions and removal asymmetrically breaks one skill).
- **Validation invocations** the orchestrator is expected to run (`validate-*.sh`, `check-*.sh`, `--ci` calls) — even when a workflow doc *also* runs them, the in-skill copy may be the only path under certain entry modes.
- **Pass/fail thresholds** (`pass_threshold: 4`, `min score`, `all dimensions ≥ N`).
- **Caller IDs, signal labels, contract names** (`caller_id: "design-review"`, `FEASIBILITY_GAP`, `REPLAN_ESCALATE`) — these are wire-format identifiers consumed by validators, agents, or hooks.
- **Approval gates** (`await explicit approval`, `STOP and wait for user`) and **SUB-AGENT-GUARD** blocks.
- **Severity overrides, escalation rules, max attempt counts** that mirror config keys.
- **Test markers, RED-zone boundaries, `.test-index` entries** that the test gate consumes.

**Compression patterns that ARE allowed**:

- A 7-line "Score Aggregation Rules" section restating `/dso:review-protocol` mechanics → one line: *"Aggregation, conflicts, and revision are owned by `/dso:review-protocol`."* The mechanics are owned elsewhere (no gate is removed); only the prose copy is collapsed.
- A 10-line bash invocation block duplicating a workflow-owned validation call → removed *only* when the workflow definitively owns invocation under every entry mode the skill supports. Verify by reading the workflow doc end-to-end before removing.
- A duplicated reviewer/perspective table appearing in both `SKILL.md` and `docs/review-criteria.md` → keep one copy as the single source of truth; replace the other with a one-line link.

**Removal patterns that are NOT allowed**:

- Deleting a schema hash, caller_id, signal label, or pass threshold because it "appears in the script too." Cross-references are the gate; both ends must remain visible.
- Deleting a validation invocation because a workflow doc *also* runs it, without first confirming the workflow runs it under every entry mode (interactive, dryrun, sub-agent dispatch, resume).
- Deleting an approval gate because the protocol the skill calls *also* has one. The skill-level gate may be load-bearing for entry modes that bypass the protocol.
- Deleting a SUB-AGENT-GUARD or its test reference.

**Procedure**: when Phase 1 diagnosis flags content as duplicated/restated/extractable, classify each item as **gate** or **prose**. Gates get compressed (one-line pointer + retain the identifier); prose gets removed. Surface the classification in the Phase 2 plan so the user can audit it.

**When in doubt, compress, do not remove.** Asymmetric cost: a removed gate may not surface as a failure for many sessions, and the loss is silent.

---

## Phase 1 — Critical review

Read the target SKILL.md in full. Identify, concretely:

1. **Reliability problems**: undefined terms/codes referenced repeatedly, ambiguous phases, missing wiring instructions, scattered `--auto`/mode branches that should be consolidated, duplication that creates drift risk.
2. **Token cost**: sections that are load-on-demand candidates (CI templates, anti-pattern catalogs, per-stack tables already codified in sibling scripts), prose over-elaboration of simple rules, examples that could live in a reference doc. For each candidate, classify as **gate** or **prose** per the "Hard gates" section above — gates get compressed, prose gets removed.
3. **Deterministic-command extraction candidates**: agent-executed bash blocks that are mechanical enough to live in a dedicated script (emit JSON, detect artifacts, slug and write files).
4. **Structural issues**: multiple approval gates for the same decision at different granularity, phases that exist solely to invoke `/dso:review` or similar one-liners, sub-agent guards repeated inline instead of shared.

**Output to the user**: a critical-review report with four sections — *What's working*, *Problems that hurt reliability*, *Token-cost / extractability*, *Structural fixes*. Give concrete file references and estimated line reduction.

Do not propose changes yet — this phase is diagnostic only.

## Phase 2 — Remediation plan (blocking approval gate)

Convert the review into a concrete plan:

- **Files to create** (new reference docs, new helper scripts) with one-line rationale each.
- **Files to modify** (SKILL.md rewrite, inline shim-call updates).
- **Scripts to relocate** (see Phase 3) with destination path.
- **Change-detector tests to remove** (see Phase 5) — names only; evidence comes in P5.
- **Gate/prose classification table** for every duplicate or restated section flagged in Phase 1, marking each as **gate** (compress, retain identifier) or **prose** (remove). Apply the criteria from the "Hard gates" section above. The user audits this table — gate misclassifications get caught here, not after the commit.
- **Expected token reduction** (estimated line delta for SKILL.md).

Present the plan and offer the user three explicit options:

1. **Approve** — proceed to Phase 3.
2. **Red-team review first** — dispatch an opus sub-agent to adversarially scrutinize the plan; revise based on findings; re-present.
3. **Revise** — user pushes back on specific items; rework Phase 1 / Phase 2 and re-present.

Do not assume option 1 is the default. State the three options. Wait for the user's choice.

**Under `/dso:dryrun`**: Same three options apply; note that dry-run mode will skip the write steps if option 1 is chosen.

### Phase 2.5 — Red-team review (only when user picks option 2)

Launch an opus sub-agent to red-team the proposed plan. Direct the agent to:

- Carefully step through scenarios the target skill may encounter and ensure that the proposed changes will improve reliability without causing regression.
- Provide general feedback on the proposed plan.

Brief the sub-agent with: full file paths to the target SKILL.md and any extracted helpers, the complete plan (every change, every classification table entry), and a starter list of scenarios to walk (happy path, every error branch the skill currently handles, every gate the plan compresses or removes, every contract the plan extracts). Ask the sub-agent to add scenarios beyond the seed list.

Output format the sub-agent should use:

- **Scenarios walked** — each scenario, expected behavior under the new plan, verdict (OK / RISK / BUG).
- **Specific concerns (numbered)** — claim, evidence (file:line or scenario), severity (blocker / important / nit), suggested fix.
- **Gate misclassifications (if any)** — item, current class, proposed class, reason.
- **General feedback** — bulleted observations.

When the sub-agent returns, **critically evaluate each finding for validity before acting on it**. Do not blindly accept; do not blindly reject. For each finding, write one of:

- **Accept** — revise the plan accordingly.
- **Partially accept** — revise with a narrower fix.
- **Reject** — explain why the concern doesn't hold.

Present the revised plan with explicit "accepted / partially accepted / rejected" status per finding, then return to the three-option gate at the top of Phase 2. The user may red-team again if substantial changes were made, approve, or revise further.

## Phase 3 — Script relocation (skill-scoped scripts only)

Determine which scripts are used only by this skill (or a tightly-coupled pair — e.g., onboarding + architect-foundation both consume the same scripts).

```bash
# Enumerate every script the skill references.
grep -oE '[a-z0-9_-]+\.sh' plugins/dso/skills/<name>/SKILL.md plugins/dso/skills/<name>/phases/*.md 2>/dev/null | sort -u

# For each candidate script, find all referrers across the plugin + host project.
for s in <candidates>; do
  echo "=== $s ==="
  grep -rln "${s}" plugins/dso/ .claude/ tests/ docs/ 2>/dev/null | grep -v "^plugins/dso/scripts/${s%.sh}\.sh$"
done
```

A script is **skill-scoped** when all referrers fall into: (a) the skill's own SKILL.md and phase files, (b) the script itself, (c) test files, (d) sibling scripts it directly sources, (e) documentation. Cross-cutting dependencies (referenced by multiple unrelated skills or by non-skill hooks) **stay where they are**.

For each skill-scoped script:

1. `mkdir -p plugins/dso/scripts/<skill-name>/` (or the shared sub-dir — e.g., `onboarding/` for skills that share scripts).
2. `git mv` each script into the sub-dir.
3. **Fix internal `_PLUGIN_ROOT` resolution**: scripts relocated one level deeper need `$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)` instead of `/..`. Every `_PLUGIN_ROOT`, `_SCRIPT_PLUGIN_DIR`, `_DSO_PLUGIN_DIR`, and `_SCRIPT_DIR/../…` pattern needs audit.
4. If a moved script references a sibling that **stays**, add `/../` to the relative path (e.g., `$SCRIPT_DIR/../detect-stack.sh`).

Verify: run the relocated script with `--help` or a safe read-only invocation; confirm it resolves the plugin root correctly.

## Phase 4 — Reference updates

Update every caller of the moved scripts to use the new shim path. The DSO shim dispatches through sub-paths automatically — calls become `.claude/scripts/dso <sub-dir>/<script>.sh`. No shim changes required.

Order of operations:

1. **Skill body** (SKILL.md, phase files): every `bash "$PLUGIN_SCRIPTS/<script>.sh"` and `.claude/scripts/dso <script>.sh` → add the sub-dir prefix.
2. **Sibling scripts**: comments referencing moved scripts — update prose to current path (optional but prevents future confusion).
3. **Project docs**: `plugins/dso/docs/**`, `docs/**` — find and update executable command references. ADRs should get a revision note appended rather than in-place edits (use `.claude/scripts/dso onboarding/adr-upsert.sh` when available).
4. **Test files**: bulk sed, one file at a time (macOS BSD sed cannot take multiple files via `<<<`):

```bash
FILES=$(for s in <moved-scripts>; do grep -rln "${s}\.sh" tests/ 2>/dev/null; done | sort -u)
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  sed -i '' -E \
    -e "s#/scripts/(<A>|<B>|…)\.sh#/scripts/<sub-dir>/\\1.sh#g" \
    -e "s#(^|[^/])scripts/(<A>|<B>|…)\.sh#\\1scripts/<sub-dir>/\\2.sh#g" \
    "$f"
done <<< "$FILES"
```

5. **`.test-index`**: the source-path column also needs rewriting for moved scripts:

```bash
sed -i '' -E 's#^plugins/dso/scripts/(<A>|<B>|…)\.sh:#plugins/dso/scripts/<sub-dir>/\1.sh:#g' .test-index
```

6. **Verification**: `grep -r "scripts/<script>\.sh" plugins/ tests/ docs/ | grep -v "<sub-dir>/"` must return zero relevant hits.

## Phase 5 — Change-detector test sweep

Find tests whose only job is asserting prose phrases appear in instruction-file text — violating the project's behavioral-testing-standard Rule 5 ("test the structural boundary, not the content").

### Classifier

```bash
python3 << 'PY'
import re, os, glob, sys
ROOT = sys.argv[1]
SKILL_VAR = re.compile(r'grep\s+-q[iE]*\s+[^|<>]*"\$[A-Z_]*(SKILL|AGENT|PROMPT|PHASE|MD|FILE|PATH)[A-Z_]*"', re.I)
SCRIPT_EXEC = re.compile(r'(?:^|\s)(bash|python3|sh|\./|\$SCRIPT|\$.*_SCRIPT|\.claude/scripts/dso|plugins/dso/scripts|run_under|jq\s+-r)\b')

def test_funcs(text):
    for m in re.finditer(r'^(test_[A-Za-z0-9_]+)\(\)\s*\{\s*$', text, re.M):
        name, start, depth, i = m.group(1), m.end(), 1, m.end()
        while i < len(text) and depth > 0:
            if text[i] == '{': depth += 1
            elif text[i] == '}':
                depth -= 1
                if depth == 0: break
            i += 1
        yield name, text[start:i]

for f in sorted(glob.glob(f"{ROOT}/tests/skills/test-*.sh")):
    text = open(f).read()
    for name, body in test_funcs(text):
        if not SKILL_VAR.search(body): continue
        if SCRIPT_EXEC.search(re.sub(r'#.*', '', body)): continue
        loc = len([l for l in body.splitlines() if l.strip()])
        if loc > 25: continue
        gm = re.search(r'grep\s+-q[iE]*\s+[^|<>]*"([^"]+)"', body)
        print(f"{os.path.basename(f)}:{name}  grep: {(gm.group(1) if gm else '?')[:60]}")
PY
```

### Triage

**Callers test (decisive)**: a string is a gate ONLY if something else binds to its exact spelling — a `source` block calls the function, a parser regex matches a signal, a config reader matches a key, Step N writes a variable that Step M reads, a hook scans for the path. No binding caller → not a gate, regardless of how name-shaped the string looks.

**Keep** if the grep target has a binding caller:
- Function names sourced/invoked elsewhere, signal labels (`FEASIBILITY_GAP`), tag constants (`scrutiny:pending`), config keys (`version.file_path`), cross-step variables, file paths consumers read, frontmatter keys, `SUB-AGENT-GUARD`, structural markers (`^## Phase`, `^### Step`), NEGATIVE assertions.

**Remove** if the grep target has no binding caller:
- Prose phrases that could be reworded preserving meaning (`"always generate.*adr"`, `"open-ended questions"`).
- **CLI command literals in instruction prose** (`git stash`, `ticket create ...`, `git log main..HEAD`) — the agent calls the *concept*, not the literal string; the same behavior has many valid implementations.

**Structural anchors don't sanctify the inner assertion.** Narrowing the search region (`awk '/A/,/B/'`, `^### .* Title`) only changes *where* the test looks; classification depends on *what* it asserts inside.

| Inner assertion | Binding caller? | Verdict |
|---|---|---|
| `RATIONALIZED_FAILURES_FROM_STEP_5` | Step N reads what Step M wrote | gate |
| `sweep_tool_errors` | `source ...; sweep_tool_errors` | gate |
| `git stash` | none — baseline check has many forms | change detector |
| `ticket create` | none — one invocation among alternatives | change detector |

When in doubt, **keep**.

### Removal

For each confirmed change detector, remove:
1. The `# test_X: ...` comment block and `test_X() { ... }` definition.
2. The `test_X` invocation line in the runner section.
3. Any `REVIEW-DEFENSE:` or `.test-index` RED-marker that referenced it.

If the entire test file is change detectors, `git rm` the file.

### Report back to the user

Summarize: N tests removed across M files, list the kept-but-flagged cases with one-line rationale for each.

## Phase 6 — Ticket reconciliation

Find open tickets that reference the skill or moved scripts by **path** or **structural name** (phase numbers, step names, section titles that have been renamed). Conceptual references are fine; pathed references are stale.

```bash
for st in open in_progress in_review; do
  .claude/scripts/dso ticket list --format=llm --status=$st 2>/dev/null | python3 -c "
import json, sys
kws = [<moved-script-names>, '<skill-name>', <old-phase-names>, <removed-section-titles>]
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try: t = json.loads(line)
    except: continue
    blob = (t.get('ttl','') + ' ' + (t.get('desc') or '') + ' ' + ' '.join(t.get('tags') or [])).lower()
    if any(k.lower() in blob for k in kws):
        print(f\"{t['id']} [{t['t']}] {t['ttl'][:90]}\")
"
done
```

For each hit:
- **Stale path** (script name): add a ticket comment noting the new path. Do NOT rewrite the description — preserve history.
- **Stale structural reference** (e.g., "Phase 3 Enforcer Setup" after rewrite): add a comment mapping old section to new section.
- **Conceptual reference** (skill name, feature concept): no action.

```bash
.claude/scripts/dso ticket comment <id> "NOTE (path update YYYY-MM-DD): <old> moved to <new>. <brief impact>."
```

## Phase 7 — Renumbering

After all structural edits are complete and before commit, renumber the skill's phases and steps so the surface form matches the post-refactor structure (gaps, deletions, and reorderings produce numbering like "Phase 2.6 / Step 1a / Step 0.5" that confuses readers and tests). This phase is mechanical: do not change behavior, only labels.

### Renumbering rules

- **Phases use sequential capital letters starting with `A`**: the first top-level work unit becomes `Phase A`, the second `Phase B`, and so on. Setup-only sections (Mindset, Usage, Migration Check, Step 0 housekeeping) stay un-numbered.
- **Steps within a phase use sequential whole numbers starting with `1`**: `Step 1, Step 2, Step 3` — never `Step 0.5`, `Step 1a`, `Step 1.5`. Sub-steps that are genuinely conditional get a clear conditional name (e.g., `Step 4: Resolve Conflicts (only when Step 3 reports conflicts)`), not a fractional number.
- **Mode/branch sections** (entry-mode dispatchers like Bug-Fix Mode, Validation Mode) stay named, not lettered. They sit between Phases and refer into them.
- **Section headers**: rename the phase heading from `## Phase N: Title` to `## Phase X: Title` (where X is the new letter); rename step headings from `### Step N.M: Title` to `### Step K: Title` (where K is the new sequential whole number within that phase).

### Procedure

> **Method**: scripts and `Edit` calls are both acceptable. The discipline that matters is **(1) build the explicit mapping table first**, **(2) one substitution pass, no double-mapping**, **(3) hand-audit cross-skill refs**, **(4) post-grep verify**. Skipping any of these — regardless of method — produces silent breakages: missed refs, off-by-one mappings, doubled substitutions where target labels collide with source labels, and mis-mapped cross-skill references (`fix-bug Step 1.5` rewritten as if it were a local step). The bug is not in the tool; the bug is in iteration discipline.

1. **Inventory current numbering** (replace `<name>` with the actual skill directory name, e.g., `debug-everything`, before running):
   ```bash
   grep -nE '^## (Phase|Step|Step [0-9])|^### Step ' plugins/dso/skills/<name>/SKILL.md
   ```
   List every phase header and every step header with its current label. Build an explicit mapping table in your reply: `Phase 1 → Phase A`, `Phase 2.6 → Phase D`, `Step 1.5 → Step 2`, etc. Walk in document order. Step numbers reset to `1` at the start of each phase — Phase A may have Steps 1–3, Phase B Steps 1–7, Phase C no steps at all (named subsections only). **The mapping table is the contract** — every later step refers to it. Show it to the user before applying.

2. **Plan the structural collapses around the renumbering, not into it**. If Phase 7 (Commit) is also restructuring blocks (e.g., collapsing "Step 1a + Step 1b" into a single "File Overlap Check + Critic Review" reference), write the collapsed content using the **original** step labels (`Step 1a`, `Step 1b`). Do NOT pre-name them with the target labels — if you write "Step 4" in a collapse and then run a renumbering pass that maps old `Step 4 → Step 9`, the collapse content gets remapped a second time and breaks. Renumbering owns the labels; collapses use the originals.

3. **Apply the substitutions in one pass** using whichever tool fits the volume:
   - **Script (Python/sed) for bulk** — fine for 50+ refs in one file. Required disciplines:
     - Process longest old-strings first (`Step 1.5` before `Step 1`, `Phase 2.6` before `Phase 2`, `Phase 11` before `Phase 1`) so prefix matches don't fire wrong.
     - Use unique-token placeholders (`__STEP_B_3__`, etc.) during the pass — substitute placeholders first, then convert placeholders to final labels at the end. This prevents the mid-pass output from being remapped a second time.
     - Run the script **once**. If you re-run the same map on already-renumbered text, target labels look like source labels and get remapped again.
   - **`Edit` calls for surgical or low-volume** — fine for under ~20 refs, or for cross-skill refs where the orchestrator must judge each match.
   - **Hybrid is the realistic case** — script the mechanical bulk, then `Edit` the few cases where context matters (sentence-ending dots, cross-skill refs, ambiguous cross-phase refs).

4. **Hand-audit cross-skill references regardless of method**. Run:
   ```bash
   grep -nE '(fix-bug|sprint|brainstorm|preplanning|<other-skill>) (Phase|Step) [0-9]' plugins/dso/skills/<name>/SKILL.md plugins/dso/skills/<name>/prompts/*.md
   ```
   Every match is a foreign reference — `fix-bug Step 1.5` means fix-bug's own Step 1.5, NOT the renumbered skill's. These must NOT be remapped. List every match before substituting; decide each one. A bulk regex pass that doesn't know about cross-skill prefixes will silently break these.

5. **Update cross-skill references that point INTO the renumbered skill**. Search every other skill, prompt file, doc, and script:
   ```bash
   grep -rEn "(/dso:<name>|<name> SKILL\.md|<name>/SKILL\.md|<name>/prompts/).*(Phase|Step) [0-9]" \
     plugins/ .claude/ docs/ tests/ 2>/dev/null
   ```
   For each candidate referrer, decide whether the reference is structural (must update to the new label, looking up via the mapping table from step 1) or conceptual (no change). Pre-existing references in `docs/designs/` and ADRs that pre-date this refactor get a **dated note appended**, not in-place edits — design docs are immutable history.

6. **Update tests**: search `tests/` for any test that asserts a specific phase/step label as a structural marker:

   ```bash
   grep -rEn "(Phase|Step) [0-9]" tests/skills/ tests/scripts/ 2>/dev/null
   ```

   Update structural assertions only (e.g., a test asserting `Phase 6` exists in SKILL.md). Tests that are change detectors should already be removed in Phase 5.

7. **Post-grep verify (mandatory)**:
   ```bash
   grep -nE '^## (Phase|Step) [0-9]|^### Step [0-9]' plugins/dso/skills/<name>/SKILL.md  # Should be empty — no numeric phase/step headers remain
   grep -nE '(Phase|Step) [0-9]' plugins/dso/skills/<name>/SKILL.md  # Audit every hit
   grep -rEn "/dso:<name>.*(Phase|Step) [0-9]\." plugins/ .claude/ docs/ tests/ 2>/dev/null  # Any hit is a stale referrer
   ```
   The first grep must return zero hits — if any numeric header survives, the mapping pass missed it. The second grep returns inline refs; every hit is either an external reference (cross-skill, OK), an unrelated number (e.g., "Step 0 (always first)" in a quoted earlier version's prose, OK if intentional), or a stale ref (must fix). The third grep finds external referrers that point at the renumbered skill with stale numbers. Walk all three lists before declaring renumbering done.

### Reporting back to the user

Present the mapping table (`old label → new label`) and the count of cross-skill references updated. Surface any structural references you decided NOT to update with a one-line rationale.

### Non-goals

- **Do not** renumber sub-steps that have meaningful conditional semantics — convert them to named conditional steps instead (e.g., `Step 4: Resolve Conflicts (only fired when Step 3 reports overlaps)`).
- **Do not** renumber inside extracted prompt files unless the prompt itself uses Phase/Step labels (most do not — they describe self-contained procedures).
- **Do not** introduce new abstraction boundaries; renumbering is surface-only.

---

## Phase 8 — Commit

Execute `plugins/dso/docs/workflows/COMMIT-WORKFLOW.md` inline. Do not invoke `/dso:commit` via the Skill tool — that nests workflows and breaks sub-agent boundaries (CLAUDE.md Rule 10).

Expect the review workflow to trigger in Step 5. This refactor diff will likely:

- **Cross the huge-diff threshold** (≥20 files). Pattern extraction will produce heterogeneous descriptions → `ROUTING=FALLBACK` → standard deep-tier review dispatches (3 sonnet specialists + opus arch synthesis).
- **Surface correctness findings** for edge cases the refactor missed: orphaned callers in non-obvious locations (installer scripts, ADRs, test fixtures), stale `.test-index` entries, missing `mkdir -p <sub-dir>` in test setup that now writes to the sub-dir path.
- **Surface hygiene findings** for incomplete template sets (e.g., missing AP-code template), stranded tests pointing at moved content.

Apply autonomous resolution (up to `review.max_resolution_attempts`, default 5). Defend findings with evidence when they're out of scope (missing test coverage for new helper scripts → file a follow-up ticket rather than block the commit).

## Artifacts produced

- Refactored SKILL.md (typically 30–60% token reduction).
- New shared reference docs under `plugins/dso/skills/shared/prompts/` or a skill-local reference doc.
- Relocated scripts under `plugins/dso/scripts/<skill-name>/` (or shared sub-dir).
- Updated references across skills, tests, docs, `.test-index`.
- Ticket comments on all affected open tickets.
- One commit with a rich body describing all three axes (skill, scripts, tests).

## Non-goals

- **Not** for fixing a reported bug in a skill — use `/dso:fix-bug`.
- **Not** for adding new features to a skill — use `/dso:brainstorm` first, then `/dso:implementation-plan`.
- **Not** for a full rewrite of skill *semantics* — this is a structural/hygiene pass. If the skill's goals themselves need revisiting, that's a `/dso:brainstorm` job.

## Known failure modes

- **Over-aggressive change-detector removal**: if in doubt, keep. The asymmetric cost favors false negatives.
- **Under-scoped relocation**: moving a "skill-scoped" script that turns out to have a non-obvious caller (an installer, a bootstrap doc, a test fixture). Phase 7 review will typically catch these; be prepared to update one or two additional files in the resolution loop.
- **Missed `.test-index` updates**: both the source-path column (LHS of `:`) and the test-list column (RHS) may need updating for moved scripts and deleted tests. Re-grep `.test-index` after Phase 4 and Phase 5.
