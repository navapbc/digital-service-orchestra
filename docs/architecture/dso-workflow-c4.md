# DSO Plugin Workflow: C4 Architecture Diagrams

This document maps the agentic software-development workflow implemented by the
Digital Service Orchestra (DSO) plugin, using the [C4 model](https://c4model.com/).

The core workflow is a four-stage pipeline:

```
/dso:brainstorm  →  /dso:preplanning  →  /dso:implementation-plan  →  /dso:sprint
```

Each stage refines the previous stage's output: a feature idea becomes an epic,
the epic decomposes into stories, each story decomposes into TDD tasks, and
those tasks are executed under multi-agent orchestration.

Diagrams progress from highest-level context (Level 1) to per-skill internals
(Level 3). Mermaid C4 directives are used for Levels 1–2; Level 3 uses
flowcharts because per-skill flow has more shape than C4 component diagrams
can represent cleanly.

> **Pre-rendered images** of every diagram below are available under
> [`diagrams/`](diagrams/README.md) (SVG + PNG) for contexts where mermaid
> won't render — Confluence, Word/PDF export, slide decks, printing.

---

## Where Do I Start? — Skill Entry Decision Tree

The four core skills look linear in the pipeline diagram, but in practice
`/dso:sprint` is the most common entry point: it orchestrates the other three
on demand. Use this decision tree to pick the right starting command.

```mermaid
flowchart TD
  start([I want to work on something]):::start
  q1{Do I have a ticket ID?}
  start --> q1

  q1 -->|no — just an idea| bs1["/dso:brainstorm"]
  q1 -->|yes| q2{What ticket type?}

  q2 -->|bug| fb["/dso:fix-bug bug-id"]
  q2 -->|epic, story, or task| q3{Is it an epic?}

  q3 -->|yes — epic| q4{Has it been brainstormed?<br/>brainstorm:complete tag}
  q3 -->|no — story or task| q5{Does it have children?}

  q4 -->|no — scrutiny:pending<br/>or zero-child unbrainstormed| bs2["/dso:brainstorm epic-id"]
  q4 -->|yes — ready to plan or execute| sp1["/dso:sprint epic-id"]

  q5 -->|story with no tasks| ip1["/dso:implementation-plan story-id"]
  q5 -->|story/task with children| sp2["/dso:sprint story-or-task-id"]

  bs1 --> bs_out[Epic created<br/>brainstorm:complete tag set]
  bs2 --> bs_out
  bs_out --> sp_route([Run /dso:sprint epic-id<br/>to execute])

  note["Sprint cascade-invokes /dso:preplanning<br/>and /dso:implementation-plan on demand.<br/>You rarely need to invoke them directly."]:::note
  sp1 -.-> note
  sp_route -.-> note

  classDef start fill:#fef3c7,stroke:#92400e
  classDef note fill:#f3e8ff,stroke:#7e22ce,color:#000
```

**Cheat sheet** for common situations:

| Situation                                                | Command                                     |
|----------------------------------------------------------|---------------------------------------------|
| Brand-new feature idea, no ticket yet                    | `/dso:brainstorm`                           |
| Existing epic with `scrutiny:pending` tag                | `/dso:brainstorm <epic-id>`                 |
| Existing epic without `brainstorm:complete`              | `/dso:brainstorm <epic-id>`                 |
| Epic ready to execute, has `brainstorm:complete`         | `/dso:sprint <epic-id>` (cascades as needed) |
| Bug or defect to investigate                             | `/dso:fix-bug <bug-id>`                     |
| Story with no tasks (rare — usually do this via sprint)  | `/dso:implementation-plan <story-id>`       |
| Imported Jira ticket (`jira-*` ID)                       | Same as native — type-detection routes it   |

Skill back-edges (less common, but they exist):

- `/dso:sprint` Phase A → `/dso:preplanning` (when story coverage is unmet)
- `/dso:sprint` Phase B → `/dso:implementation-plan` (per story being expanded)
- `/dso:sprint` Phase B cascade → `/dso:brainstorm` (on `REPLAN_ESCALATE: brainstorm`)
- `/dso:preplanning` Phase A.1.5 → `/dso:implementation-plan` (SIMPLE epics skip stories)
- `/dso:implementation-plan` Step 4 / Step 6 → `/dso:oscillation-check` (cycle ≥ 2)

---

## Level 1 — System Context

Shows the DSO plugin in its environment: who uses it and which external
systems it talks to.

```mermaid
C4Context
  title System Context — DSO Plugin

  Person(dev, "Developer / Operator", "Invokes /dso:* skills via Claude Code; reviews diagrams, plans, PRs.")

  System_Boundary(harness, "Claude Code Harness") {
    System(dso, "DSO Plugin", "Skills, agents, hooks, scripts that orchestrate the four-stage workflow.")
  }

  System_Ext(llm, "Anthropic LLM API", "Backs all sub-agents (haiku / sonnet / opus).")
  System_Ext(fs, "Repository Filesystem", "Source code, tests, configs.")
  System_Ext(tickets, "Ticket Store", "Event log on orphan tickets branch.")
  System_Ext(git, "Git / GitHub", "Worktrees, branches, PRs.")
  System_Ext(actions, "GitHub Actions", "12 workflows: CI, llm-review, Jira reconciler.")
  System_Ext(jira, "Jira (optional)", "Synced via reconciler bridge.")

  Rel(dev, dso, "Invokes skills")
  Rel(dso, llm, "Dispatches sub-agents")
  Rel(dso, fs, "Reads / edits code")
  Rel(dso, tickets, "CRUD epics / stories / tasks")
  Rel(dso, git, "Worktrees, branches, PRs")
  Rel(git, actions, "Triggers workflows")
  Rel(actions, llm, "Dispatches code-reviewers")
  Rel(actions, tickets, "Mutates via reconciler")
  Rel(actions, jira, "Bidirectional sync")
```

Key contracts at this boundary:

| Surface             | Read                                    | Written by DSO                                                  |
|---------------------|-----------------------------------------|-----------------------------------------------------------------|
| Ticket Store        | `dso ticket show / list / deps`         | `ticket create / transition / tag / comment / link`             |
| Git / GitHub        | branch state, PR diffs, required-checks | new branches, sprint draft PR, merges via `merge-to-main.sh`    |
| Filesystem          | code, configs, design docs              | edits via sub-agent Bash/Edit/Write tools                       |
| LLM API             | model availability                      | structured prompts, JSON envelopes (receipt-only contracts)     |

---

## Level 2 — Container

Shows the major subsystems inside the DSO plugin.

```mermaid
C4Container
  title Container — Inside the DSO Plugin

  Person(dev, "Developer")

  System_Boundary(dso, "DSO Plugin") {
    Container(core, "Core Workflow Skills", "Markdown", "brainstorm, preplanning, implementation-plan, sprint")
    Container(support, "Supporting Skills", "Markdown", "review, commit, fix-bug, oscillation-check, etc.")
    Container(agents, "Sub-Agent Pool", "Agent files", "~53 dso:* agents (reviewers, decomposers, verifiers)")
    Container(workflows, "Shared Workflows", "Markdown", "scrutiny-pipeline, remediation-loop, REVIEW, COMMIT")
    Container(prompts, "Shared Prompts", "Markdown", "behavioral-testing, complexity-gate, scale-inference")
    Container(scripts, "Scripts", "Bash / Python", "ticket CLI, validators, merge-to-main, lifecycle")
    Container(hooks, "Hooks", "Bash", "pre-commit gates, PostToolUse, PreToolUse")
    ContainerDb(tickdb, "Ticket Event Log", "Orphan branch", "Append-only events per ticket; scratch store")
    ContainerDb(artifacts, "Artifact Store", "Local files", "Scrutiny outputs, review findings, sentinels")
  }

  System_Boundary(ghaboundary, "GitHub Actions") {
    Container(ci, "ci.yml", "GHA", "Primary CI gate + llm-review")
    Container(subpr, "review-sub-pr.yml", "GHA", "Per-story PR review")
    Container(recon, "reconcile-bridge trio", "GHA", "Jira reconciler + canary + weekly fsck")
    Container(maint, "Maintenance workflows", "GHA", "lifecycle, calibration, template e2e")
    Container(plat, "Platform CI", "GHA", "Python skills, platform matrix, perf, portability")
  }

  System_Ext(llm, "LLM API")
  System_Ext(git, "Git / GitHub")
  System_Ext(jira, "Jira")

  Rel(dev, core, "Invokes")
  Rel(core, support, "Invokes via Skill tool")
  Rel(core, agents, "Dispatches")
  Rel(support, agents, "Dispatches")
  Rel(core, workflows, "Reads")
  Rel(core, prompts, "Reads")
  Rel(agents, prompts, "Reads")
  Rel(core, scripts, "Executes")
  Rel(scripts, tickdb, "Reads / writes")
  Rel(scripts, git, "Worktree + merge ops")
  Rel(hooks, scripts, "Runs gates")
  Rel(agents, llm, "Per-tier dispatch")
  Rel(core, artifacts, "Writes")
  Rel(git, ci, "Push / PR triggers")
  Rel(git, subpr, "Sub-PR triggers")
  Rel(ci, agents, "Dispatches reviewers")
  Rel(subpr, agents, "Dispatches reviewers")
  Rel(recon, scripts, "Invokes reconciler")
  Rel(recon, jira, "ACLI sync")
  Rel(recon, tickdb, "SYNC events")
  Rel(maint, scripts, "Lifecycle + calibration")
  Rel(plat, scripts, "Platform tests")
```

Key cross-container conventions:

- **Sub-agent dispatch**: orchestrator skills use the Agent tool with named
  `subagent_type` values (e.g., `dso:story-decomposer`). Each named agent has
  a fallback path to `subagent_type: "general-purpose"` with the agent file
  read inline.
- **Scratch + receipt contracts**: large sub-agent outputs are written to the
  ticket scratch store and only a 3-field receipt is returned, keeping
  orchestrator context small (`receipt-parse.sh`, `ticket-scratch.sh`).
- **PRECONDITIONS gate**: each stage records its completion via
  `preconditions-record.sh`; the next stage validates via
  `preconditions-validator.sh`. The four-stage pipeline is welded together
  through these gates plus tags (`brainstorm:complete`, `scrutiny:pending`,
  `ui_probes:deferred`, `interaction:deferred`).

---

## Level 3 — Pipeline Components (Cross-Skill Flow)

Shows how the four core skills hand off through the ticket system.

```mermaid
flowchart LR
  user([Developer]):::actor

  subgraph brainstorm["/dso:brainstorm"]
    direction TB
    bs1[Phase 1<br/>Socratic Dialogue]
    bs2[Phase 1.5<br/>UI-Copy Detector]
    bs3[Phase 2<br/>Approach + Scrutiny]
    bs4[Phase 3<br/>Epic Ticket Write]
    bs1 --> bs2 --> bs3 --> bs4
  end

  subgraph preplanning["/dso:preplanning"]
    direction TB
    pp1[Phase A<br/>Reconciliation +<br/>Complexity Route]
    pp2[Phase B<br/>External Deps]
    pp3[Story Decomposition]
    pp4[Phase C-D<br/>Risk + Integration]
    pp5[Phase E<br/>Adversarial Review]
    pp6[Phase F-G<br/>Slicing + Research]
    pp7[Phase H<br/>Write Stories]
    pp1 --> pp2 --> pp3 --> pp4 --> pp5 --> pp6 --> pp7
  end

  subgraph implplan["/dso:implementation-plan"]
    direction TB
    ip1[Step 1<br/>Contextual Discovery]
    ip2[Step 2<br/>Architectural Review]
    ip3[Step 3<br/>Task Drafting]
    ip4[Step 4<br/>Plan Review]
    ip5[Step 5<br/>Task Create]
    ip6[Step 6<br/>Gap Analysis]
    ip1 --> ip2 --> ip3 --> ip4 --> ip5 --> ip6
  end

  subgraph sprint["/dso:sprint"]
    direction TB
    sp1[Phase A-B<br/>Init + Planning]
    sp2[Phase C-D<br/>Batch Prep + Manual Pause]
    sp3[Phase E<br/>Sub-Agent Launch]
    sp4[Phase F<br/>Story Validation]
    sp5[Phase G<br/>Epic Validation]
    sp6[Phase H-I<br/>Remediation + Closure]
    sp1 --> sp2 --> sp3 --> sp4 --> sp5 --> sp6
  end

  user -->|"feature idea"| brainstorm
  brainstorm -->|"epic ticket<br/>brainstorm:complete"| preplanning
  preplanning -->|"story tickets<br/>+ done definitions"| implplan
  implplan -->|"task tickets<br/>+ TDD specs"| sprint
  sprint -->|"PR merged<br/>epic closed"| user

  classDef actor fill:#fef3c7,stroke:#92400e,color:#000
  classDef skill fill:#dbeafe,stroke:#1e40af,color:#000
  class brainstorm,preplanning,implplan,sprint skill
```

### Handoff artifacts

| From → To              | Artifact                                                                         | Stored where                              |
|------------------------|----------------------------------------------------------------------------------|-------------------------------------------|
| brainstorm → next      | Epic ticket; `brainstorm:complete` tag; `### Planning Intelligence Log` comment | Ticket store                              |
| brainstorm → next      | PRECONDITIONS baseline record (`brainstorm_complete` gate)                       | Ticket events                             |
| brainstorm → next      | `brainstorm-sentinel` file                                                       | Artifact store                            |
| preplanning → impl-plan | Child stories with `## Done Definitions` (each `← Satisfies: sc-N`)            | Ticket store (story tickets)              |
| preplanning → impl-plan | `PREPLANNING_CONTEXT:` comment on epic (schema_version 2)                        | Epic ticket comment                       |
| preplanning → impl-plan | `verify_commands` per DD (from story-decomposer)                                 | Ticket events on each story               |
| impl-plan → sprint     | Task tickets with `## Story DD Coverage` + TDD `testing_mode` + AC               | Ticket store (task tickets)               |
| sprint → user          | Closed epic, merged PR, completion-verifier P1=PASS                              | Ticket store + Git                        |

---

## Level 3 — `/dso:brainstorm` Internals

```mermaid
flowchart TB
  start([Invocation:<br/>/dso:brainstorm or<br/>/dso:brainstorm epic-id]):::start

  start --> typegate{Type Detection<br/>Gate}
  typegate -->|epic| p1
  typegate -->|story/task/bug<br/>convert| convert[phases/convert-to-epic.md]
  typegate -->|story/task/bug<br/>enrich| enrich[phases/enrich-in-place.md]
  convert --> p1
  enrich --> done

  subgraph p1["Phase 1 — Context + Dialogue"]
    p1a[Scale Inference Protocol] --> p1b[Codebase Investigation]
    p1b --> p1c[Tell-Me-More Loop<br/>one question at a time]
    p1c --> p1d[Phase 1 Gate:<br/>Understanding Summary →<br/>Intent Gap Analysis]
  end

  p1 --> ui15{UI Intent<br/>Detection?}
  ui15 -->|clear-ui| probes[UX Probe Set<br/>3 probes]
  ui15 -->|clear-non-ui| skipui[skip probes]
  ui15 -->|ambiguous| haiku1[haiku UI classifier<br/>prompt: ui-detection-classifier.md]
  haiku1 --> ui15decide{result}
  ui15decide -->|ui| probes
  ui15decide -->|non-ui| skipui
  probes --> p15
  skipui --> p15

  subgraph p15["Phase 1.5 — UI-Copy Detector"]
    p15a[Signal scan]
    p15b[Idempotency guard]
    p15c[Tag copy-needed<br/>+ ## Copy Needs section]
    p15a --> p15b --> p15c
  end

  p15 --> ecls[classify-epic-class.sh<br/>→ EPIC_CLASS]
  ecls --> probe{architectural?}
  probe -->|yes| archprobe[run-architectural-probe.sh<br/>dso:architectural-probe]
  probe -->|no| p2
  archprobe --> p2

  subgraph p2["Phase 2 — Approach + Spec"]
    p2a[Propose 2-3 approaches<br/>complexity-gate.md]
    p2b[Draft Epic Spec<br/>SCs + Closure Checks<br/>verifiable-sc-check.md]
    p2c[Step 2.15<br/>Verify-intents]
    p2d[Step 2.25<br/>Cross-Epic Scan]
    p2e[Scrutiny Pipeline]
    p2f[Step 4<br/>Approval Gate]
    p2a --> p2b --> p2c --> p2d --> p2e --> p2f
  end

  p2d -->|haiku| cei[dso:cross-epic-<br/>interaction-classifier]
  p2e -->|sub-agents| scrut[shared/workflows/<br/>epic-scrutiny-pipeline.md<br/>→ red-team-reviewer<br/>→ blue-team-filter<br/>→ feasibility-reviewer<br/>→ bot-psychologist]

  p2 --> p3

  subgraph p3["Phase 3 — Ticket Integration"]
    p3a[Follow-on Gate]
    p3b[ticket create epic]
    p3c[ticket link depends_on]
    p3d[validate-issues.sh]
    p3e[Write PIL comment<br/>+ emit brainstorm-fidelity result]
    p3f[preconditions-record.sh<br/>+ tag brainstorm:complete]
    p3g[Write brainstorm-sentinel]
    p3a --> p3b --> p3c --> p3d --> p3e --> p3f --> p3g
  end

  p3 --> done([Brainstorm complete])

  classDef start fill:#fef3c7,stroke:#92400e
  classDef phase fill:#dbeafe,stroke:#1e40af
  class p1,p15,p2,p3 phase
```

**Sub-agents dispatched** (all via Agent tool):

| Agent                                          | Tier   | Where                       | Purpose                                                       |
|-----------------------------------------------|--------|-----------------------------|---------------------------------------------------------------|
| haiku UI classifier (prompt-only, no named agent) | haiku  | Phase 1.5                   | Ambiguous UI/non-UI classification — `general-purpose` + `prompts/ui-detection-classifier.md` |
| `dso:cross-epic-interaction-classifier`        | haiku  | Step 2.25                   | Detect overlaps with open epics (batched ceil(N/5))           |
| `dso:architectural-probe`                      | opus   | Conditional (architectural) | E2E test scaffold for architectural epics before scrutiny     |
| `dso:red-team-reviewer`                        | opus   | Scrutiny pipeline           | Adversarial epic audit (8-category taxonomy)                  |
| `dso:blue-team-filter`                         | sonnet | Scrutiny pipeline           | Triage red-team findings                                      |
| `dso:feasibility-reviewer`                     | sonnet | Scrutiny pipeline (conditional) | Verify external tool integration feasibility               |
| `dso:bot-psychologist`                         | opus   | Scrutiny Step 5 (conditional)   | Debug LLM-instruction signals                              |
| Agent Clarity / Scope / Value reviewers        | sonnet | Scrutiny Step 4             | Three-axis fidelity review (general-purpose dispatch)         |
| `dso:bug-classifier-haiku`                     | haiku  | Bug-close bookkeeping       | Classify bug ticket slug                                      |

---

## Level 3 — `/dso:preplanning` Internals

```mermaid
flowchart TB
  start([/dso:preplanning epic-id]):::start

  start --> gates[Gates:<br/>scrutiny:pending<br/>interaction:deferred<br/>ui_probes:deferred<br/>brainstorm preconditions]

  gates --> a1[Phase A.1 Select<br/>+ Load Epic]
  a1 --> a15[A.1.5<br/>Complexity Classifier<br/>dso:complexity-evaluator]
  a15 --> route{Tier?}
  route -->|SIMPLE| impl[Invoke<br/>/dso:implementation-plan]
  route -->|MODERATE| lightweight[Lightweight Mode<br/>enrich epic only]
  route -->|COMPLEX| a2

  a2[A.2 Escalation Policy<br/>autonomous /<br/>escalate-when-blocked /<br/>escalate-unless-confident]
  a2 --> a3[A.3-5 Reconcile<br/>existing children]
  a3 --> b[Phase B<br/>External Deps Reading]

  b -->|claude_auto| bauto[Story: Verify and integrate X]
  b -->|user_manual| bman[Story tagged<br/>manual:awaiting_user]

  bauto --> sd
  bman --> sd

  subgraph sd["Story Decomposition"]
    sd1[Dispatch<br/>dso:story-decomposer<br/>opus<br/>via scratch + receipt]
    sd2[Validate<br/>sc_coverage_plan<br/>+ story_drafts<br/>+ verify_commands]
    sd1 --> sd2
  end

  sd --> c[Phase C<br/>Risk & Scope Scan<br/>6 reviewer areas]
  c --> d{external<br/>integration?}
  d -->|yes| dres[Phase D<br/>Integration Research<br/>WebSearch + verify]
  d -->|no| e
  dres --> e

  e{≥3 stories?}
  e -->|yes| eadv[Phase E<br/>Adversarial Review]
  e -->|no| refusal

  subgraph eadv["Phase E Adversarial Review"]
    e1["red-team-reviewer (opus)<br/>mode: story_review"]
    e2["blue-team-filter (sonnet)"]
    e3{findings?}
    e4["Remediation Loop + oscillation-check"]
    eDone[exit]
    e1 --> e2 --> e3
    e3 -->|non-empty| e4 --> e1
    e3 -->|empty| eDone
  end

  eadv --> refusal
  refusal[Refusal Gate:<br/>External Deps coverage<br/>for externally-shaped SCs]
  refusal --> f[Phase F<br/>Walking Skeleton<br/>+ Foundation/Enhancement<br/>+ INVEST]
  f --> g[Phase G<br/>Story-Level Research]

  g --> h

  subgraph h["Phase H — Verification + Traceability"]
    h1[Create story tickets<br/>via ticket create story]
    h2[set-verify-commands<br/>per DD]
    h3{UI story?}
    h4[Dispatch<br/>dso:ui-designer]
    h5[validate-issues.sh]
    h6[Write<br/>PREPLANNING_CONTEXT<br/>comment on epic]
    h1 --> h2 --> h3
    h3 -->|yes| h4 --> h5
    h3 -->|no| h5
    h5 --> h6
  end

  h --> done([Preplanning complete])
  lightweight --> done
  impl --> done

  classDef start fill:#fef3c7,stroke:#92400e
  classDef phase fill:#dbeafe,stroke:#1e40af
  class eadv,sd,h phase
```

**Sub-agents dispatched**:

| Agent                            | Tier   | Where               | Purpose                                                  |
|----------------------------------|--------|---------------------|----------------------------------------------------------|
| `dso:complexity-evaluator`       | haiku  | A.1.5               | Classify SIMPLE / MODERATE / COMPLEX                     |
| `dso:story-decomposer`           | opus   | Story Decomposition | Draft vertical-slice stories covering every SC           |
| `dso:red-team-reviewer`          | opus   | Phase E             | Cross-story blind spots + 8-category taxonomy            |
| `dso:blue-team-filter`           | sonnet | Phase E             | Triage red-team findings                                 |
| `dso:ui-designer`                | varies | Phase H             | Wireframe / design manifest per UI story                 |

Scripts used: `ticket-scratch.sh`, `receipt-parse.sh`, `append_review_cycle.py`,
`preconditions-validator.sh`, `validate-issues.sh`, `planning-config.sh`,
`classify-sc-shape.sh`, `consult-recipe-registry.sh`.

---

## Level 3 — `/dso:implementation-plan` Internals

```mermaid
flowchart TB
  start([/dso:implementation-plan<br/>story-id or epic-id]):::start

  start --> guard[SUB-AGENT-GUARD:<br/>orchestrator-level only]
  guard --> preflt[Pre-flight Tag Guards<br/>check-tag-guards.sh<br/>scrutiny_pending /<br/>interaction_deferred /<br/>manual_awaiting_user]
  preflt --> copybypass{copy-story<br/>tag?}
  copybypass -->|yes| bypass([STATUS:bypass<br/>handoff to sprint])
  copybypass -->|no| s1

  subgraph s1["Step 1 — Contextual Discovery"]
    s1a[Re-invocation guard<br/>check-reinvocation.sh]
    s1b[Epic Type Detection]
    s1c[Architectural Alignment<br/>+ ADR scan]
    s1d[Recipe Consultation<br/>consult-recipe-registry.sh]
    s1e[Ambiguity Scan +<br/>Unsatisfiable Criteria]
    s1f[Cross-Cutting Detection<br/>≥3 layers / ≥5 interfaces]
    s1a --> s1b --> s1c --> s1d --> s1e --> s1f
  end

  s1 --> doconly{doc-only<br/>story?}
  doconly -->|yes| s3
  doconly -->|no| prop

  subgraph prop["Proposal Generation"]
    prop1[Dispatch<br/>dso:approach-proposer<br/>opus]
    prop2[Validate<br/>≥3 distinct proposals<br/>4 structural axes<br/>complexity gates]
    prop1 --> prop2
  end

  prop --> rloop

  subgraph rloop["Resolution Loop"]
    rl1[Dispatch<br/>dso:approach-decision-maker<br/>opus]
    rl2{mode?}
    rl3[counter_proposal<br/>NEW_COUNT++<br/>retry ≤2]
    rl1 --> rl2
    rl2 -->|selection| rlSel[Selected proposal]
    rl2 -->|counter_proposal| rl3
    rl3 --> prop
  end

  rloop --> s2{new<br/>pattern?}
  s2 -->|yes| s2rev[Step 2:<br/>REVIEW-PROTOCOL-WORKFLOW<br/>+ 3 architectural reviewers<br/>best-practices /<br/>project-alignment /<br/>justification]
  s2 -->|no| s3
  s2rev --> s3

  subgraph s3["Step 3 — Task Drafting"]
    s3a[File Impact Enumeration<br/>+ Consumer Detection]
    s3b[Testing Mode Classification<br/>RED / GREEN / UPDATE / recipe]
    s3c[Dispatch<br/>dso:task-decomposer<br/>opus<br/>via scratch + receipt]
    s3d[Validate<br/>dd_partition_map<br/>+ task_drafts<br/>+ AC library<br/>+ Story DD Coverage]
    s3a --> s3b --> s3c --> s3d
  end

  s3 --> s4

  subgraph s4["Step 4 — Plan Review"]
    s4a[REVIEW-PROTOCOL-WORKFLOW<br/>pass_threshold 5<br/>5 reviewers]
    s4b{pass?}
    s4c[Remediation:<br/>re-dispatch task-decomposer<br/>+ /dso:oscillation-check at N≥2]
    s4a --> s4b
    s4b -->|fail| s4c --> s4a
    s4b -->|pass| s4done
  end

  s4done --> s5

  s5[Step 5 — Task Create<br/>ticket create task<br/>--parent story-id<br/>+ AC + verify commands]
  s5 --> s5b[Step 5b<br/>Behavioral Coverage<br/>Cross-Check<br/>haiku]
  s5b --> s6{TRIVIAL?}
  s6 -->|no| s6gap

  subgraph s6gap["Step 6 — Gap Analysis"]
    s6a[Dispatch opus<br/>prompt: gap-analysis.md]
    s6b{gaps?}
    s6c[Re-dispatch<br/>dso:task-decomposer<br/>+ oscillation-check<br/>at N≥2]
    s6a --> s6b
    s6b -->|gaps| s6c --> s6a
    s6b -->|clean| done
  end

  s6 -->|yes| done
  s6gap --> done([Plan complete])
  bypass --> done

  classDef start fill:#fef3c7,stroke:#92400e
  classDef phase fill:#dbeafe,stroke:#1e40af
  class s1,prop,rloop,s3,s4,s6gap phase
```

**Sub-agents dispatched**:

| Agent                          | Tier | Where     | Purpose                                              |
|--------------------------------|------|-----------|------------------------------------------------------|
| `dso:approach-proposer`        | opus | Proposal Generation; Step 2 remediation | ≥3 distinct proposals with complexity gates |
| `dso:approach-decision-maker`  | opus | Resolution Loop | Selection / counter-proposal ADR rationale     |
| `dso:task-decomposer`          | opus | Step 3; Step 4 / 6 remediation | Atomic TDD task drafts with AC                |
| opus gap-analysis (prompt-only, no named agent) | opus | Step 6    | Detect Done Definition coverage gaps — `general-purpose` + `prompts/gap-analysis.md` |
| 3 architectural reviewers      | varies | Step 2 (conditional) | best-practices, project-alignment, justification |
| 5 plan reviewers               | varies | Step 4    | task-design, tdd, safety, dependencies, completeness |
| haiku behavioral cross-check   | haiku  | Step 5b   | Validate behavioral DDs have behavioral verify commands |

Skills invoked: `/dso:oscillation-check` (Step 4 and Step 6 cycle ≥2).
Workflows: `REVIEW-PROTOCOL-WORKFLOW.md`, `remediation-loop-protocol.md`.

---

## Level 3 — `/dso:sprint` Internals

```mermaid
flowchart TB
  start([/dso:sprint epic-id]):::start

  subgraph a["Phase A — Init + Ticket Selection"]
    a1[Resolve primary ticket<br/>list-epics --has-tag=brainstorm:complete]
    a2{ticket type?}
    a3[Validate status open/in_progress]
    a4[Bug routing →<br/>/dso:fix-bug]
    a5[Drift Detection<br/>sprint-drift-check.sh]
    a6[SC Coverage Gate<br/>haiku → sonnet → opus]
    a7[Preplanning Gate<br/>epic-complexity-evaluator<br/>haiku]
    a8{tier?}
    a9[Invoke /dso:preplanning<br/>lightweight or full]
    a10[Create draft PR<br/>ci-pr mode]
    a1 --> a2 -->|bug| a4
    a2 -->|epic/story| a3 --> a5 --> a6 --> a7 --> a8
    a8 -->|MODERATE/COMPLEX| a9 --> a10
    a8 -->|SIMPLE| a10
  end

  a --> b

  subgraph b["Phase B — Task Analysis"]
    b1[Filter design-blocked<br/>+ manual:awaiting_user]
    b2[Per-story complexity<br/>dso:complexity-evaluator<br/>haiku]
    b3[Dispatch<br/>/dso:implementation-plan<br/>per story]
    b4{REPLAN_ESCALATE?}
    b5[d-replan-collect<br/>cascade to<br/>/dso:brainstorm or<br/>/dso:preplanning<br/>cycle-capped]
    b1 --> b2 --> b3 --> b4
    b4 -->|yes| b5 --> b1
    b4 -->|no| bDone
  end

  b --> c

  subgraph c["Phase C — Batch Prep"]
    c1[agent-batch-lifecycle.sh<br/>pre-check<br/>usage-aware cap]
    c2[check-recipe-engines.sh]
    c3[ticket next-batch<br/>--epic=ID]
    c4[Claim tasks<br/>transition open in_progress]
    c5[Pull latest main]
    c1 --> c2 --> c3 --> c4 --> c5
  end

  c --> d{manual:<br/>awaiting_user?}
  d -->|yes| dpause[Phase D<br/>Manual-Pause Handshake]
  d -->|no| e
  dpause --> e

  subgraph e["Phase E — Sub-Agent Launch"]
    e1[Compose batch<br/>per-task subagent_type<br/>+ model selection]
    e2[Doc story?<br/>dso:doc-writer]
    e3[Copy story?<br/>dso:gov-copy-writer]
    e4[Code task?<br/>task-execution.md<br/>haiku/sonnet/opus]
    e5[RED test?<br/>dso:red-test-writer<br/>+ dso:red-test-evaluator]
    e1 --> e2
    e1 --> e3
    e1 --> e4
    e1 --> e5
  end

  e --> f

  subgraph f["Phase F — Post-Batch Processing<br/>(story validation)"]
    f1[Test Gate / Lint Gate /<br/>AC Gate]
    f2[Per-worktree review<br/>→ /dso:review<br/>→ dso:code-reviewer-*]
    f3[Story-level dispatch<br/>dso:completion-verifier]
    f4{P1 verdict?}
    f5[Dispatch<br/>dso:verification-<br/>remediation-planner]
    f6[Close story<br/>transition closed]
    f1 --> f2 --> f3 --> f4
    f4 -->|non-PASS| f5 --> fRemed[Remediation]
    f4 -->|PASS| f6
  end

  f --> ctx{more tasks<br/>or context<br/>≥70%?}
  ctx -->|more tasks| c
  ctx -->|context| compact["/compact"]
  compact --> c
  ctx -->|done| g

  subgraph g["Phase G — Post-Primary Ticket Validation<br/>(epic-level)"]
    g1[Integration + E2E gates<br/>epic-ci-and-e2e-gates.md]
    g2[Epic-level dispatch<br/>dso:completion-verifier]
    g3{P1 verdict?}
    g4[planner-dispatch:<br/>dso:verification-<br/>remediation-planner]
    g5["/dso:validate-work"]
    g6[Epic-specific<br/>validation agent<br/>UI vs backend]
    g1 --> g2 --> g3
    g3 -->|non-PASS| g4 --> gRemed[Remediation]
    g3 -->|PASS| g5 --> g6
  end

  g --> h{remediation<br/>needed?}
  h -->|yes| hloop[Phase H<br/>remediation-loop.md<br/>+ gap-classification<br/>+ bounded attempts<br/>+ oscillation check]
  h -->|no| i
  hloop --> b

  subgraph i["Phase I — Closure"]
    i1[Remove .sprint-active]
    i2[Verify merged to main]
    i3[Close epic]
    i4["/dso:end-session<br/>--bump minor"]
    i1 --> i2 --> i3 --> i4
  end

  i --> done([Sprint complete])

  classDef start fill:#fef3c7,stroke:#92400e
  classDef phase fill:#dbeafe,stroke:#1e40af
  class a,b,c,e,f,g,i phase
```

**Sub-agents dispatched** (selected — sprint dispatches many):

| Agent                                    | Tier         | Where                       | Purpose                                                    |
|------------------------------------------|--------------|-----------------------------|------------------------------------------------------------|
| `dso:complexity-evaluator`               | haiku        | Phase A.7, Phase B          | Epic and per-story tier classification                     |
| SC-coverage classifier set                | haiku→sonnet→opus | Phase A.3-A.5         | SC traceability gate (escalating tiers)                    |
| `dso:doc-writer`                         | sonnet       | Phase E                     | Doc stories                                                |
| `dso:gov-copy-writer`                    | sonnet       | Phase E                     | Copy / rewrite stories (federal style canon)               |
| `dso:red-test-writer`                    | sonnet       | Phase E (RED tasks)         | Write failing tests for TDD                                |
| `dso:red-test-evaluator`                 | sonnet       | Phase E (RED tasks)         | Triage red-test results                                    |
| `dso:code-reviewer-{light,standard,deep}` | varies      | Phase F per commit          | Code review via tier classifier                            |
| `dso:completion-verifier`                | sonnet       | Phase F (story), Phase G (epic) | Verify done definitions + success criteria              |
| `dso:verification-remediation-planner`   | opus         | Phase F, G                  | Classify verifier failures, route remediation              |
| Task-execution sub-agents                 | haiku/sonnet/opus | Phase E              | Implement individual tasks                                 |
| `dso:plan-review`                        | sonnet       | Pre-presentation (via /dso:plan-review) | Plan quality gate                                |

Skills invoked: `/dso:implementation-plan` (Phase B), `/dso:preplanning` (Phase A
Preplanning Gate), `/dso:brainstorm` (cascade), `/dso:fix-bug` (bug routing),
`/dso:validate-work` (Phase G), `/dso:end-session` (Phase I), `/dso:review`
(per-commit), `/dso:oscillation-check` (Phase H).

Workflows: `remediation-loop.md`, `remediation-loop-protocol.md`,
`REVIEW-WORKFLOW.md`, `COMMIT-WORKFLOW.md`, `TEST-FAILURE-DISPATCH.md`,
`epic-ci-and-e2e-gates.md`.

---

## Cross-Cutting Concerns

The diagrams above intentionally don't repeat patterns that apply throughout the
plugin. The most important cross-cutting mechanisms:

```mermaid
flowchart LR
  subgraph skills["Core Skills"]
    direction TB
    sk1["/dso:brainstorm"]
    sk2["/dso:preplanning"]
    sk3["/dso:implementation-plan"]
    sk4["/dso:sprint"]
  end

  subgraph all4["used by all 4"]
    direction TB
    prec[PRECONDITIONS gate chain]
    remed[Remediation Loop +<br/>Oscillation Check]
  end

  subgraph some["used by some"]
    direction TB
    scratch["Scratch + Receipt contract<br/>(preplanning + impl-plan)"]
  end

  subgraph sprintonly["used by sprint only"]
    direction TB
    hooks[Pre-commit Hooks]
    review[REVIEW-WORKFLOW]
  end

  sk1 --> all4
  sk2 --> all4
  sk3 --> all4
  sk4 --> all4
  sk2 --> scratch
  sk3 --> scratch
  sk4 --> sprintonly

  classDef skill fill:#dbeafe,stroke:#1e40af
  classDef cross fill:#fce7f3,stroke:#9d174d
  class sk1,sk2,sk3,sk4 skill
  class prec,scratch,remed,hooks,review cross
```

| Mechanism                              | Purpose                                                                                  |
|----------------------------------------|------------------------------------------------------------------------------------------|
| PRECONDITIONS gate chain               | Each stage records a baseline; the next validates it before starting                     |
| Scratch + receipt contract             | Sub-agents write large payloads to scratch and return only a 3-field receipt             |
| Remediation Loop + Oscillation Check   | Bounded-cycle protocol with hard gate at N ≥ 2 to prevent revert-flip-flop               |
| Pre-commit hooks                       | Block raw commits, enforce review gate, test gate, story-branch invariant                |
| REVIEW-WORKFLOW tier classifier        | Deterministic light / standard / deep / opus selection from diff complexity              |

---

## Review and Gate Timeline (Idea → Merge)

The per-skill diagrams each show their local review/gate. This diagram
consolidates **every** review, gate, and verification point along the path
from a feature idea to a merged PR, in execution order. Each box names the
mechanism and the sub-agent or hook responsible.

```mermaid
flowchart LR
  idea([Feature idea]):::start

  subgraph bs_gates["/dso:brainstorm — scrutiny + approval"]
    direction TB
    g_bs1[Cross-Epic Interaction Classifier<br/>haiku — Step 2.25]
    g_bs2[Scrutiny Pipeline<br/>red-team + blue-team + feasibility<br/>+ Agent Clarity + Scope + Value<br/>+ bot-psychologist conditional]
    g_bs3[Approval Gate<br/>user confirmation]
    g_bs1 --> g_bs2 --> g_bs3
  end

  subgraph pp_gates["/dso:preplanning — story-level review"]
    direction TB
    g_pp1[Complexity Evaluator<br/>haiku — A.1.5]
    g_pp2[Phase E Adversarial Review<br/>red-team-reviewer + blue-team-filter<br/>cross-story blind-spot audit]
    g_pp3[Refusal Gate<br/>External Deps coverage<br/>for externally-shaped SCs]
    g_pp1 --> g_pp2 --> g_pp3
  end

  subgraph ip_gates["/dso:implementation-plan — plan review"]
    direction TB
    g_ip1[Architectural Review<br/>3 reviewers — Step 2 conditional<br/>pass_threshold 4]
    g_ip2[Plan Review<br/>5 reviewers — Step 4<br/>pass_threshold 5]
    g_ip3[Behavioral Coverage<br/>Cross-Check<br/>haiku — Step 5b]
    g_ip4[Gap Analysis<br/>opus — Step 6]
    g_ip1 --> g_ip2 --> g_ip3 --> g_ip4
  end

  subgraph sp_gates["/dso:sprint — execution review and gates"]
    direction TB
    g_sp1[SC Coverage Gate<br/>haiku → sonnet → opus<br/>Phase A]
    g_sp2[Per-task Code Review<br/>dso:code-reviewer light / standard / deep<br/>via REVIEW-WORKFLOW classifier<br/>Phase F]
    g_sp3[Pre-commit Hooks<br/>review gate, test gate, ticket-boundary,<br/>branch invariant, compliance verifier<br/>Phase F per commit]
    g_sp4[Story Completion Verifier<br/>dso:completion-verifier<br/>P1 typed-enum verdict<br/>Phase F]
    g_sp5[Epic Completion Verifier<br/>dso:completion-verifier<br/>Phase G]
    g_sp6["/dso:validate-work<br/>5-domain validation<br/>Phase G"]
    g_sp1 --> g_sp2 --> g_sp3 --> g_sp4 --> g_sp5 --> g_sp6
  end

  subgraph ci_gates["GitHub Actions — CI on every push and PR"]
    direction TB
    g_ci1[ci.yml static gates<br/>actionlint, shellcheck, ruff,<br/>hook tests, script tests]
    g_ci2[review-sub-pr.yml<br/>llm-review on per-story PRs<br/>required check]
    g_ci3[ci.yml llm-review job<br/>tier classifier + provenance narrowing<br/>+ named code-reviewer agents<br/>on integration diff]
    g_ci4[merge-pipeline-checks<br/>umbrella required check]
    g_ci1 --> g_ci2 --> g_ci3 --> g_ci4
  end

  merged([PR merged to main]):::done

  idea --> bs_gates --> pp_gates --> ip_gates --> sp_gates --> ci_gates --> merged

  classDef start fill:#fef3c7,stroke:#92400e
  classDef done fill:#dcfce7,stroke:#166534
  classDef bs fill:#dbeafe,stroke:#1e40af
  classDef pp fill:#dbeafe,stroke:#1e40af
  classDef ip fill:#dbeafe,stroke:#1e40af
  classDef sp fill:#dbeafe,stroke:#1e40af
  classDef ci fill:#fce7f3,stroke:#9d174d
  class bs_gates bs
  class pp_gates pp
  class ip_gates ip
  class sp_gates sp
  class ci_gates ci
```

**Approximate review-point count along the happy path**: 4 in brainstorm, 3 in
preplanning, 4 in implementation-plan, 6 in sprint, 4 in CI = **~21 distinct
gate or review evaluations** between idea and merge. Most are scoped (only
fire when their preconditions are met — e.g., Phase E adversarial review only
fires when there are ≥ 3 stories; architectural review only fires when a new
pattern is proposed). Typical end-to-end runs encounter 8–12 of these.

**Failure routes** (not shown above, see per-skill diagrams):

- A failed review enters the **remediation loop** (`remediation-loop-protocol.md`)
  with a bounded cycle cap and an `/dso:oscillation-check` hard gate at cycle ≥ 2.
- Story-level verifier `P1 ≠ PASS` routes through `dso:verification-remediation-planner`
  which classifies the failure and emits one of four scopes: `replan_story`,
  `new_tasks_in_story`, `new_story_in_epic`, or `replan_epic`.
- CI `llm-review` blocking on a suspect false positive escapes via
  `/dso:fp-recovery <pr-number>` (opus-tier reviewer rerun).
- Catastrophic failure escapes via `REPLAN_ESCALATE: <upstream>` which routes
  back to `/dso:brainstorm` or `/dso:preplanning`.

---

## Level 3 — GitHub Actions Workflow Catalog

The DSO plugin is supported by 12 GitHub Actions workflows that fall into four
roles. Together they enforce the CI gate, sync with Jira, advance ticket
lifecycle, and produce telemetry rollups.

```mermaid
flowchart TB
  trigger([Trigger]):::actor

  subgraph cigate["CI Gates (PR-blocking)"]
    ci[ci.yml<br/>main CI orchestrator<br/>+ llm-review<br/>+ merge-pipeline-checks]
    subpr[review-sub-pr.yml<br/>per-story PR review]
    plat1[ci-python-skills.yml]
    plat2[ticket-platform-matrix.yml]
    plat3[ticket-perf-regression.yml]
    plat4[portability-smoke.yml]
  end

  subgraph jira["Jira Reconciliation"]
    rb[reconcile-bridge.yml<br/>every 20 min<br/>+ workflow_dispatch]
    rbc[reconcile-bridge-canary.yml<br/>hourly heartbeat]
    fsck[weekly-bridge-fsck.yml<br/>Mon 06:00 UTC]
  end

  subgraph maint["Maintenance / Telemetry"]
    tl[ticket-lifecycle.yml<br/>daily 03:00 UTC]
    cal[calibration-rollup.yml<br/>monthly + quarterly]
    e2e[template-real-url-e2e.yml<br/>daily + tag push]
  end

  trigger -->|push / PR| cigate
  trigger -->|cron + dispatch| jira
  trigger -->|cron + dispatch| maint
  trigger -->|tag v*| e2e

  ci --> out([Required checks pass])
  subpr --> out
  plat1 --> out
  plat2 --> out
  plat3 --> out
  plat4 --> out

  classDef actor fill:#fef3c7,stroke:#92400e,color:#000
  classDef gate fill:#dbeafe,stroke:#1e40af,color:#000
  classDef bridge fill:#fce7f3,stroke:#9d174d,color:#000
  classDef maint fill:#dcfce7,stroke:#166534,color:#000
  class cigate gate
  class jira bridge
  class maint maint
```

### Workflow catalog (authoritative)

| Workflow                          | Trigger                                                          | Purpose                                                                                                                  | Required check?    |
|-----------------------------------|------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------|--------------------|
| `ci.yml`                          | push (main, feature/**, etc.), PR (all), workflow_dispatch       | Lint + hooks/scripts tests + llm-review orchestration + `merge-pipeline-checks` umbrella                                  | yes (umbrella)     |
| `review-sub-pr.yml`               | PR on `session/**`, `bug-batch/**`, `worktree-**`                | LLM code review on sub-PR diff; writes `findings.json`                                                                    | yes (per-story)    |
| `ci-python-skills.yml`            | push main / feature/* / bugfix/* / epic/* / exp/* / PR / dispatch | pytest of Python skills + Sphinx docs build                                                                              | yes                |
| `ticket-platform-matrix.yml`      | push main (ticket-lib-api.sh paths), PR, dispatch                 | Cross-platform ticket lib tests: bash4/Ubuntu, bash3/macOS, busybox/Alpine                                               | yes                |
| `ticket-perf-regression.yml`      | push main (ticket-lib-api.sh paths), PR (same paths)              | hyperfine benchmarks of `ticket-lib-api.sh` + sprint workflow                                                            | yes                |
| `portability-smoke.yml`           | push main, PR                                                    | dso shim self-detection in fresh Ubuntu                                                                                   | yes                |
| `reconcile-bridge.yml`            | every 20 min cron + dispatch (modes: dry-run / bootstrap-strict / bootstrap-throttle / live) | Bidirectional Jira ↔ ticket-store reconciler via ACLI + `dso_reconciler` Python module                                   | no (background)    |
| `reconcile-bridge-canary.yml`     | hourly cron + dispatch                                           | Heartbeat: if last successful reconcile-bridge run > 2 h, file/continue/close a heartbeat-alert bug ticket               | no (alerting)      |
| `weekly-bridge-fsck.yml`          | Mon 06:00 UTC cron + dispatch                                    | Audit ticket store for orphan jira_key mappings, duplicate Jira mappings, stale SYNC events, unresolved BRIDGE_ALERTs    | no (audit)         |
| `ticket-lifecycle.yml`            | daily 03:00 UTC cron + dispatch                                  | Advance ticket state machine (auto-close stale tickets, process lifecycle events)                                        | no                 |
| `calibration-rollup.yml`          | push main + monthly cron + quarterly cron                        | Append mutation + churn calibration records on merge; generate monthly/quarterly rollup reports                          | no                 |
| `template-real-url-e2e.yml`       | daily 06:00 UTC cron + tag push `v*` + dispatch                  | E2E real-clone validation of the NextJS template repo against the contract spec                                          | release-gate       |

---

## Level 3 — `ci.yml` Internals (the llm-review orchestrator)

The primary CI workflow runs both static gates and a multi-step LLM review
orchestration. Below shows the job graph and the llm-review pipeline.

```mermaid
flowchart TB
  start([push or pull_request]):::start

  start --> changes[changes job<br/>skip-review-check.sh<br/>→ code_changed flag]

  changes -->|code_changed| static
  changes -->|always| vcheck

  subgraph static["Static + Test Gates"]
    al[actionlint]
    sc[shellcheck]
    lp[lint-python<br/>ruff]
    th[test-hooks]
    ts[test-scripts]
    al --> th
    sc --> th
    lp --> th
    sc --> ts
    lp --> ts
  end

  vcheck[validate-required-checks<br/>check-context names<br/>vs required-checks.txt]

  static --> mirror[mirror-defenses-to-pr<br/>TrackerDefenseStore<br/>→ PR comments]

  mirror --> llmreview

  subgraph llmreview["llm-review job (PR + main only)"]
    direction TB
    lr1[Step 1-3<br/>Cycle tracking<br/>DSO_REVIEW_CYCLE env]
    lr2[Step 4-8<br/>Provenance narrowing<br/>verify-session-provenance.sh<br/>+ DSO-Story-Merge trailer scan]
    lr3["Step 9<br/>Dispatch gate<br/>llm-review-dispatch-or-skip.sh"]
    lr4{exit code?}
    lr5[Skip:<br/>all provenanced<br/>or OVER_BOUND]
    lr6[Step 10<br/>ci-llm-review-runner.sh<br/>→ runner.py<br/>+ context-augmentation loop]
    lr7[review-complexity-classifier.sh<br/>→ light / standard / deep]
    lr8["Named code-reviewer agents<br/>dso:code-reviewer-light<br/>dso:code-reviewer-standard<br/>dso:code-reviewer-deep-*"]
    lr9[Step 11<br/>Liveness gate<br/>findings.json non-empty]
    lr1 --> lr2 --> lr3 --> lr4
    lr4 -->|0 or 3| lr5
    lr4 -->|1 or 2| lr6
    lr6 --> lr7 --> lr8 --> lr9
  end

  llmreview --> mpc[merge-pipeline-checks<br/>umbrella + RED-marker scan<br/>required check]

  mpc --> done([PR mergeable])

  classDef start fill:#fef3c7,stroke:#92400e
  classDef gate fill:#dbeafe,stroke:#1e40af
  classDef llm fill:#fce7f3,stroke:#9d174d
  class static gate
  class llmreview llm
```

**Key contracts**:

| Contract               | Description                                                                                                                       |
|------------------------|-----------------------------------------------------------------------------------------------------------------------------------|
| `DSO_REVIEW_CYCLE`     | Cycle counter from prior `## DSO llm-review — finding N` headers; consumed by `runner.py` for two-call architecture on cycle ≥ 2  |
| Provenance narrowing   | Classifies commits as provenanced (traced to a story PR via `DSO-Story-Merge:` trailer) vs unprovenanced                          |
| OVER_BOUND (exit 3)    | Provenance check signal: high-complexity integration, skip review (escape valve)                                                  |
| `findings.json`        | Reviewer output written by sub-agent; liveness-gated in Step 11 (catches silent exit-0)                                           |
| `TrackerDefenseStore`  | Prior defenses stored on `tickets` orphan branch; mirrored to PR via `mirror-defenses-to-pr` job                                  |
| Tier classifier        | `review-complexity-classifier.sh` — deterministic light/standard/deep selection (no LLM call); FP-recovery escape opens opus tier |

**Integration with the four core skills**:

- `/dso:sprint` Phase A creates a draft PR (`create-sprint-draft-pr.sh`) which
  starts the CI clock. Per-story merges into the session branch trigger
  `review-sub-pr.yml`, each writing a `DSO-Story-Merge:` trailer.
- `/dso:commit` and `/dso:review` write `reviewer-findings.json` locally; CI
  re-runs `ci-llm-review-runner.sh` on the integration diff and compares.
- `/dso:fp-recovery <pr-number>` is the escape valve when CI llm-review blocks
  on a suspected false positive — runs `dso:code-reviewer-standard` at opus
  tier on the PR diff.
- `merge-to-main.sh` (invoked by `/dso:sprint` Phase I or `/dso:end-session`)
  waits for `merge-pipeline-checks` to clear before merging.

---

## Level 3 — Jira Reconciliation Trio

```mermaid
flowchart TB
  cronA[(cron */20 min)]:::cron
  cronB[(cron hourly)]:::cron
  cronC[(cron Mon 06:00 UTC)]:::cron
  disp[(workflow_dispatch<br/>modes: dry-run / bootstrap / live)]:::dispatch

  subgraph rb["reconcile-bridge.yml"]
    rb1[Pre-flight: BRIDGE_ENV_ID<br/>+ __main__.py exists]
    rb2[Mount tickets worktree]
    rb3[Install requirements.lock<br/>+ download ACLI<br/>SHA256 verify]
    rb4[acli jira auth login]
    rb5[Set bridge bot git identity]
    rb6[python -m dso_reconciler<br/>--mode MODE]
    rb7[Commit + fetch-rebase-push<br/>5-retry exponential backoff]
    rb8[Failure alert →<br/>chronic-failure ticket]
    rb1 --> rb2 --> rb3 --> rb4 --> rb5 --> rb6 --> rb7
    rb6 -.->|on failure| rb8
  end

  subgraph rbc["reconcile-bridge-canary.yml"]
    rbc1[GitHub API: last<br/>successful rb run]
    rbc2{stale<br/>>2h?}
    rbc3[Open / continue<br/>heartbeat-alert ticket]
    rbc4[Close ticket on recovery]
    rbc5[Exit 1 on stale<br/>→ GHA failure UI]
    rbc1 --> rbc2
    rbc2 -->|stale| rbc3 --> rbc5
    rbc2 -->|healthy + ticket open| rbc4
  end

  subgraph fsck["weekly-bridge-fsck.yml"]
    f1[Mount tickets worktree]
    f2[python ticket-bridge-fsck.py]
    f3[Detect orphan jira_keys<br/>+ duplicate mappings<br/>+ stale SYNC events<br/>+ unresolved alerts]
    f4[Exit 1 on anomalies<br/>→ on-call investigates]
    f1 --> f2 --> f3 --> f4
  end

  cronA --> rb
  disp --> rb
  cronB --> rbc
  cronC --> fsck

  rbc -.->|reads run history| ghapi[(GitHub Actions API)]
  rb -.->|writes SYNC events| store[(tickets branch)]
  fsck -.->|reads events| store
  rbc -.->|opens / closes tickets| store
  rb -.->|bidirectional ACLI sync| jira[(Jira / DIG project)]

  classDef cron fill:#fef3c7,stroke:#92400e,color:#000
  classDef dispatch fill:#fef3c7,stroke:#92400e,color:#000
  classDef workflow fill:#fce7f3,stroke:#9d174d,color:#000
  class rb,rbc,fsck workflow
```

**Relationships**: `reconcile-bridge.yml` is the **active healer** (writes
events both ways); `reconcile-bridge-canary.yml` is a **passive monitor**
(opens a heartbeat-alert ticket if the active healer goes silent for >2 h);
`weekly-bridge-fsck.yml` is a **passive auditor** (surfaces ledger anomalies
weekly for human investigation). The canary is NOT a staging tier — modes for
gradual rollout / rollback are operator-selected via `workflow_dispatch` on
the main reconciler.

---

## DSO ↔ CI Integration Sequence

This sequence shows how `/dso:sprint` interacts with GitHub Actions across a
full epic execution.

```mermaid
sequenceDiagram
  participant Dev as Developer
  participant Sprint as /dso:sprint
  participant Git as Local Git
  participant GH as GitHub
  participant SubPR as review-sub-pr.yml
  participant Agents as code-reviewers
  participant CI as ci.yml
  participant FP as /dso:fp-recovery
  participant Merge as merge-to-main.sh

  Dev->>Sprint: /dso:sprint epic-id
  Sprint->>Git: create session branch
  Sprint->>GH: open draft PR
  Note over GH,CI: ci-pr mode
  GH->>CI: PR opened
  CI-->>GH: static gates

  loop per story
    Sprint->>Git: story branch + DSO-Story-Merge trailer
    Sprint->>GH: push story PR
    GH->>SubPR: trigger
    SubPR->>Agents: dispatch reviewer
    Agents-->>SubPR: findings
    SubPR-->>GH: required check
    GH-->>Sprint: check passed
  end

  Sprint->>Sprint: Phase G epic verify
  Sprint->>Merge: merge-to-main.sh
  Merge->>GH: PR ready
  GH->>CI: re-trigger
  CI->>Agents: llm-review (provenance-narrowed)
  Agents-->>CI: findings

  alt critical findings block merge
    Note over Dev,FP: FP-recovery escape
    Dev->>FP: /dso:fp-recovery
    FP->>Agents: dispatch @ opus
    Agents-->>FP: rescored
    FP-->>Dev: verdict
    Note over Dev: fix + push if needed
    GH->>CI: re-trigger
    CI->>Agents: llm-review
    Agents-->>CI: cleared
  else findings minor or none
    Note over CI: standard path
  end

  CI-->>GH: checks pass
  Merge->>GH: gh pr merge
  GH-->>Dev: merged

  GH->>CI: post-merge
  CI->>CI: calibration-rollup

  Note over GH: every 20 min
  GH->>GH: reconcile-bridge: Jira sync
```

**Workflow → Skill triggers (table)**:

| Workflow / Action                       | Triggered by                                  | Affects DSO skill                                       |
|----------------------------------------|-----------------------------------------------|---------------------------------------------------------|
| `ci.yml` (PR)                          | `/dso:sprint` Phase A draft PR creation       | Findings feed `/dso:review` autonomous resolution loop  |
| `review-sub-pr.yml`                    | Per-story PR merge during `/dso:sprint`       | Required-check for story PR merge                        |
| `ci.yml` (post-merge)                  | `merge-to-main.sh` final merge                | Adds calibration telemetry                              |
| `reconcile-bridge.yml`                 | cron / dispatch (out of band)                 | Adds Jira-mirror events visible to all skills           |
| `ticket-lifecycle.yml`                 | daily cron                                    | Auto-closes stale tickets; affects `/dso:retro` outputs |
| `template-real-url-e2e.yml`            | tag `v*` (release)                            | Gates release artifact for downstream consumers         |

---

## Reading Guide

- **For a quick mental model**: read Level 1 + the pipeline flowchart in Level 3.
- **For "where do I start?"**: read the Skill Entry Decision Tree near the top.
  It maps ticket state → command and lists the back-edges so the sprint-as-
  orchestrator pattern is explicit.
- **For "where will my work be reviewed?"**: read the Review and Gate Timeline
  after Cross-Cutting Concerns. It consolidates all ~21 review/gate points
  along the path from idea to merge.
- **For operating the plugin**: read each per-skill Level 3 diagram; trace
  which sub-agents fire and what each phase produces.
- **For modifying the plugin**: also consult the underlying SKILL.md files
  (`plugins/dso/skills/{brainstorm,preplanning,implementation-plan,sprint}/SKILL.md`),
  agent definitions (`plugins/dso/agents/*.md`), and workflow files
  (`plugins/dso/docs/workflows/`, `plugins/dso/skills/shared/workflows/`).
- **For sub-agent details**: the named agent table in `plugins/dso/docs/AGENTS.md`
  is the authoritative reference for tier, scope, and authority.
- **For CI / GitHub Actions**: read the Workflow Catalog section and the
  `ci.yml` internals diagram; for Jira sync, the reconciler trio diagram.
  The DSO ↔ CI sequence shows how `/dso:sprint` and CI interact across an
  epic execution.
