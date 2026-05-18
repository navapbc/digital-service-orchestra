# Code Review False-Positive Reduction — Research and Gap Analysis

**Date**: 2026-05-17
**Author**: session research (project maintainer)
**Status**: reference document

This is the captured output of a research session that explored: (1) whether requiring LLM reviewers to attach a failing RED test per behavioral finding has prior art, (2) research-supported alternatives to that policy, (3) how the current DSO review system maps onto published anti-hallucination patterns, (4) what the in-flight epic landscape addresses, (5) what observed PR-level FPs look like in practice, and (6) what specific calibration changes would be most cost-effective. Sections are organized to be readable independently.

---

## 1. Prior art for "reviewer must attach a failing RED test per finding"

The closest direct matches in published / popular work:

- **Anthropic Claude Code `/code-review` and `/ultra-review`** — `/code-review` instructs the reviewer to *"Construct a concrete failing scenario — if you can't describe exactly how the bug manifests, it's not an issue."* This is a **described** scenario, not an executed test. `/ultra-review` raises the bar to *"independently reproduced and verified by multiple agents,"* still without enforcing an attached failing test artifact.
- **SWE-bench / SWE-bench Verified** — Formalizes the RED-test concept as `FAIL_TO_PASS`: tests must fail on the base commit and pass after the patch. All-or-nothing scoring. Strongest published enforcement of the concept, but on the *fix-author* side, not the *reviewer* side.
- **Issue2Test (arXiv 2503.16320), Libro, AssertFlip (arXiv 2507.17542)** — Research on auto-generating reproducer tests from issue reports. Issue2Test explicitly targets failing tests with execution-based filtering (discard tests that don't fail for the stated reason). AssertFlip reaches 43.6% fail-to-pass success by *inverting* passing tests — useful workaround for the "LLMs are bad at writing failing tests directly" problem.
- **Datadog / Greptile** — Adjacent: LLM filtering of static-analysis findings with retrieval-based evidence, not runnable-test gates.

**What I did not find**: no widely-used open-source LLM code-review tool (CodeRabbit, Greptile, Qodo Merge, GitHub LLM-review actions, etc.) requires the reviewer to attach a runnable failing test per behavioral finding as a hard gate. The bar across the industry is "cite code" or "describe a scenario," not "produce a RED test."

## 2. Published research on the policy and its implications

Researchers have explicitly thought through the failure modes of this policy:

- **SpecRover (Ruan, Zhang et al., ICSE 2025)** — Reviewer-agent design that produces explanation + reproducer test + accumulated specification. Critically argues *against* reproducer-test-only sufficiency: tests are precise but **incomplete** specifications. A test failing for reason X doesn't establish the bug IS X; it establishes that some defect exists. Their answer: tri-evidence bundle (test + spec + NL explanation).
- **AnyPoC (arXiv 2604.11950, 2026)** — Multi-agent PoC generation with analyzer → generator → validator → knowledge extractor. Treats the witness test as the load-bearing artifact and builds explicit anti-hallucination machinery around it (re-execution + validation).
- **c-CRAB Code Review Agent Benchmark (arXiv 2603.23448)** — Argues that executable tests should be the deterministic gate for review findings, *not* the review verdict. Reports ~40% benchmark solve rate under this gate — the policy is *known* to reject a large fraction of would-be findings.
- **"Are LLMs Reliable Code Reviewers? Systematic Overcorrection" (arXiv 2603.00539)** — Direct empirical motivation. Finds LLMs **systematically over-flag correct code as defective**. Proposes a "Fix-guided Verification Filter" grounding verdict revision in executable evidence rather than textual rationale.
- **ImpossibleBench (arXiv 2510.20270, 2025)** — Sharpest warning. Creates tasks where specs and tests deliberately conflict; any "pass" implies the agent took a spec-violating shortcut. Implication: if the reviewer's incentive is "produce a failing test," they will produce one that fails — possibly by exploiting the test harness rather than reflecting a real bug.
- **AssertFlip empirical numbers** — Even with strong models, direct generation of failing tests is hard; inversion of passing tests reaches 43.6% fail-to-pass. **~half of behavioral findings won't yield a usable RED test on first try.**

**Implications other researchers have already worked through:**

1. Yield drop is quantified: 40–60% of would-be findings fail the gate.
2. "Test fails" ≠ "finding is correct." Need spec-grounding on top.
3. Direct failing-test generation is harder than passing-test generation.
4. Reward-hacking risk: agents will exploit harness quirks when objective is "produce a failing test."
5. Path-feasibility may be a cheaper middle ground (LLM4PFA, ZeroFalse) — 70–96% FP reduction from articulating an explicit feasible path, without runnable test.
6. Reproducer + spec + NL explanation outperforms reproducer alone (SpecRover).

## 3. Well-supported alternatives to calibrate LLM reviews against FPs

Grouped by mechanism. Several compose with each other:

### 3.1 Adversarial multi-agent / refute-or-promote

- **Refute-or-Promote (arXiv 2604.19049)** — Four-stage pipeline with parallel creative + adversarial tracks. Reported caught all 4 FP candidates in their evaluation, including one where same-family agents had converged on a false positive.
- **CodeX-Verify** — Four specialized detectors; mathematical claim that diverse-detector ensembles strictly dominate single-agent reviewers.
- **Consensus Trap (arXiv 2604.17139)** — Critical caveat: unanimous agreement among same-family agents does *not* raise confidence. Refutation by an adversarial agent, not consensus by similar agents, is what changes belief.

### 3.2 Confidence calibration + abstention

- **Spiess et al., "Calibration and Correctness of Language Models for Code" (ICSE 2025)** — Empirically shows confidence is top-skewed; thresholds must be calibrated to each model's observed distribution. Local Platt-scaling on minimum-token-probability gives consistent calibration gains.
- **Fine-grained Calibration for Code Revision (arXiv 2604.06723)** — Code-revision-specific Platt scaling and per-class thresholds.
- **DINCO / "Calibrating Verbalized Confidence with Self-Generated Distractors" (arXiv 2509.25532)** — Addresses overconfidence without token-probability access.
- **CISC, ACL 2025 Findings** — Weighted majority voting using model-reported confidence; cuts samples by >40% vs unweighted self-consistency.

### 3.3 Execution-grounded but cheaper than full RED test

- **LLM4PFA (arXiv 2506.10322)** — Force the LLM to articulate an explicit feasible execution path. 72–96% FP filtering. 41–106% improvement over baselines.
- **ZeroFalse (arXiv 2510.02534)** — Structured context extraction reconstructing dataflow path between source and sink.
- **Datadog / Kharkar et al. (arXiv 2601.18844)** — Industrial deployment: 433 cases over 10 months. LLM-based FP filtering on static analysis warnings at scale without runnable tests.

### 3.4 Retrieval / repo-grounded review

- **LAURA (arXiv 2512.01356)** — RAG with exemplars + context augmentation. 42.2% / 40.4% correct-or-helpful rates (GPT-4o / DeepSeek v3) vs SOTA baselines.
- **When More Retrieval Hurts (arXiv 2511.05302)** — Important negative result: naive RAG increases noise. Hybrid sparse-dense (sparse 89% precision/61% recall; dense 85% recall/72% precision) outperforms either alone.
- **Citation-Grounded Code Comprehension (arXiv 2512.12117)** — Mechanical citation verification: line ranges must overlap retrieved chunks; **prevents hallucinated citations in 100% of attempted cases**.

### 3.5 Self-critique / iterative refinement

- **CRITIC (OpenReview)** — Tool-interactive self-critique loop.
- **VERDICT (Haize Labs)** — Production library for judge-time-compute scaling.
- **"Do Before You Judge: Self-Reference" (arXiv 2509.19880)** — Judge first attempts the task, then evaluates the candidate.

### 3.6 Human-feedback calibration loops (production-deployed)

- **Greptile** — ~85% actionable signal after 2–3 weeks of 👍/👎 feedback.
- **CodeRabbit** — `.coderabbit.yaml` natural-language config; "Chill vs Assertive" review profiles.
- **Qodo 2.0 (Feb 2026)** — Multi-agent specialization (bug / security / quality / coverage agents in parallel).
- **Ericsson Experience Report (arXiv 2507.19115)** — Industrial deployment with prompt re-calibration using expert feedback. Notes binary thumbs is limited.

### 3.7 Spec-grounded review (SpecRover line)

Findings carry bundle: explanation + reproducer test + accumulated NL spec. Tests alone are insufficient because they are precise-but-incomplete.

### 3.8 Metric / evaluation hygiene

- **Balanced Accuracy (arXiv 2512.08121)** — Recommends Balanced Accuracy (Youden's J) over precision/recall/F1 because prevalence-dependent metrics mislead during FP-tuning.
- **FPR_P / FPR_R (arXiv 2601.18844)** — Precision and recall *for the FP class itself* are the right metrics for tuning FP-reduction systems.

## 4. The adversarial-refuter risk and its mechanical mitigations

A naive adversarial refuter agent inherits the hallucination rate of the reviewer it's countering. Quantified concern: **adversarial hallucination attacks propagate planted errors at 83%** (Nature Communications Medicine 2025) — if a hallucinated finding sits in the refuter's prompt, the refuter elaborates on the false premise more often than rejecting it.

The published mitigation is **not** "use a smarter model" — it's structural: make refutations themselves mechanically verifiable, so a hallucinated refutation is rejected before it can suppress a finding.

Six research-supported mechanisms:

1. **Mechanical citation verification** (arXiv 2512.12117) — Refutation must cite `[file:start-end]` ranges; deterministic post-check verifies overlap with retrieved chunks. **100% prevention** of invalid citations.
2. **Tool-grounded refutation** ("no evidence, no answer") — Refuter must invoke a tool (grep/read/run-tests); tool output is the evidence, not the prose.
3. **Asymmetric epistemic stance, fail-closed on the refutation** — Default = preserve finding. Refuter must *earn* a drop with mechanical evidence. GSAR (arXiv 2604.23366) classifies claims grounded/ungrounded/contradicted/complementary; ungrounded refutations dropped.
4. **Premise decomposition before refutation** (arXiv 2504.06438) — Decompose finding into named predicates; verify each independently with a tool call. No slot for prose argument.
5. **Prompt isolation from the original rationale** — Refuter sees claim + cited code only, never the reviewer's chain-of-thought. Directly addresses the 83% propagation finding.
6. **Code execution as grounded supervision** (ACL EMNLP 2025) — Where feasible, run the path under the claim and use execution output as evidence.

**Conclusion**: an adversarial refuter is viable only if the refutation gate is symmetric — rejecting hallucinated refutations the same way it rejects hallucinated findings. Without mechanical grounding gates, the refuter makes things worse.

## 5. The current DSO review system — what it implements

This audit covers `code-reviewer-*` agent prompts, REVIEW-WORKFLOW.md, contracts (`review-findings-schema.md`, `review-defenses.md`, `ci-review-context-request.md`), ADR-0013, and `.github/workflows/per-branch-review.yml`.

### 5.1 Already implemented (load-bearing across prompt + schema validator + runtime)

1. **Mechanical citation verification** — `cited_lines` required; `cited_excerpt` ≥ 5 non-whitespace chars verbatim; path-jail in context-request protocol.
2. **Execution-grounded absence claims** — `verification_evidence: {command, output}` with auto-detection via `absence-claim-anchors.json`. Hard-enforced when sentinel file `absence-claim-enforcement-v1` is present.
3. **Reachability gate** — every critical/important/fragile finding requires ≥20-char caller-input → bug-site → observable-harm sentence.
4. **Caller-input verification gate** — must Grep all callers before claiming critical/important reachability.
5. **Arithmetic verification gate** — must compute step-by-step for any quantitative claim.
6. **Stale-context detection** — cited code must match HEAD; else drop.
7. **Cross-module disambiguation** — must Grep all definitions before signature-mismatch findings.
8. **Aliased import resolution** — must resolve `as Z` before "undefined" findings.
9. **Bash-source mandatory pre-check** — must Read all `source`/`.` targets before "undefined function" findings.
10. **Relation taxonomy** — NEW_INTRODUCED / NEW_PRE_EXISTING / RESUSTAIN_OF / REFRAME_OF with auto-downgrade of pre-existing findings to minor.
11. **Two-call architecture (cycle ≥ 2)** — Call 1 sees no defenses to avoid anchoring; Call 2 reconciles.
12. **Runtime proximity-overlap suppression** — `_suppress_defended_findings` in `runner.py` downgrades findings within ±5 lines of prior defended cited_lines.
13. **Runtime novelty gate** — `_apply_novelty_gate` requires token-level escape_rationale validation for NEW_INTRODUCED findings outside defended regions.
14. **Defense store with SHA-256 fingerprint** — whitespace-stripped LF-normalized content hash; semantic edits void binding.
15. **SHA-range attestation** — `story_branch_tip_sha`/`story_branch_base_sha` prevent stale defenses applying to new commits.
16. **Deep-arch synthesis dependency tracking** — drop meta-findings whose specialist premises were disproved.
17. **NOT-flag auto-downgrade rules** — 7 bug-tagged categories (bash idioms, sourced functions, trust-boundary on public config, theoretical injection on `subprocess.run([...])`, coverage-gap without concrete failure path, etc.).
18. **Severity calibration rubric** — bright-line rules + 4-criterion test for change-detector findings.
19. **AI blindspot annotations** — `domain_mismatch`, `ui_artifacts`, `spaghetti_patching`, `asymmetric_change`, `approach_viability_concern`.

This is denser anti-hallucination calibration than what production tools (Greptile, CodeRabbit, Qodo) ship.

### 5.2 Mapping research recommendations to current implementation

| Research mechanism | Current DSO state |
|---|---|
| §3.4 Citation grounding | ✓ Strong (mandatory `cited_lines` + `cited_excerpt`) |
| §3.3 Execution-grounded findings | ✓ Surgical (absence claims only; not extended to behavioral) |
| §3.5 Self-critique | ✓ Verifier sub-agent + deep-arch synthesis |
| §3.1 Diverse-detector ensemble | ~ Partial (3 deep specialists + opus synth, no adversarial refuter) |
| Oscillation control | ~ Partial (proximity-suppression + relation field; arbiter wiring incomplete) |
| Severity authority governance | ✓ ADR-0013 |
| Hallucination guards | ✓ Strong (AI blindspot annotations + verification gates) |
| §3.2 Confidence calibration | ✗ Missing (severity is enum, no per-finding confidence) |
| §3.6 Human-feedback loop | ✗ Missing (no dismissal feedback into prompts) |
| §3.7 Spec-grounded findings | ✗ Missing (no SC/DD link in findings) |
| §3.8 Balanced Accuracy / FPR_P/FPR_R | ✗ Missing (no statistical calibration metrics) |

## 6. Open epics — what they address, what they don't

### 6.1 swap-maple-flyby (`b575-ac1c-f720-4839`) — Cycle-end arbiter + workflow unification

- **Status**: in_progress, P0, brainstorm:complete, arch-evidence:remediation-needed.
- **Mechanism**: arbiter rewrite from old trinary (SUSTAIN/ACCEPT/DOWNGRADE) to per-finding BLOCK/DEFER/DROP with 8-impact-class severity floor. Jaccard ≥0.85 adaptive halt; max_cycles=4. CoVe (Chain-of-Verification) on critical/important findings. DEFER → orphan ticket; DROP → defense record.
- **Wiring gap**: runner.py does not yet dispatch `dispatch_cycle_end_arbiter` (Story S4 ef20 closure comment). Stories 5621 (CI), 7034 (local), c4f1 (e2e validation) all open. Today's effect on findings: zero.
- **Addresses (FP-class)**: severity inflation (impact-class AND-gate); oscillation cost (cycle cap + Jaccard halt). Does NOT directly address source-grep mis-flag (the dominant FP class).
- **Maps to research §3.1 + §3.5 + judge-time-compute scaling.**

### 6.2 coarse-wold-plank (`bb93-c474-d065-4d06`) — Minor-finding ticket gate

- **Status**: open, P1, scrutiny:pending. Placeholder spec.
- **Mechanism**: reroute verifier `downgrade-to-minor` rulings and low-priority reviewer minors into tracker tickets instead of PR comments.
- **Addresses**: PR-comment noise volume (~15–25%); not the FP RATE.
- **Maps to research §3.2 abstention/threshold.**

### 6.3 side-pane-tithe (`a34c-b345-1e63-4ae3`) — Calibration observability

- **Status**: open, P1, north-star, brainstorm:complete.
- **Mechanism**: `detected_by:` channel tag (7 values) + monthly/quarterly rollup via `calibration-report.sh` + `/dso:test-quality-report` skill.
- **Addresses**: measurement gap — enables rule-effectiveness queries. Doesn't directly reduce FPs but enables iteration.
- **Research gap to close**: the spec uses F1-style aggregation; **research consensus is Balanced Accuracy (arXiv 2512.08121) + FPR_P/FPR_R (arXiv 2601.18844)** for FP-reduction tuning. Worth noting in the ticket.

### 6.4 7575-5a90 — Static-analysis defense layer

- **Status**: open, P0, scrutiny:pending.
- **Mechanism**: four pre-commit hooks (hermeticity, antipatterns, config-key docs, pipefail-grep). Baseline ratchet for existing violations.
- **Addresses**: bug recurrence and reduces review surface. ~25% of recent fixes are hermeticity-class.
- **Indirect FP effect**: removes a class of patterns reviewers historically flag inconsistently.

### 6.5 loose-chasm-knot — Architecture-vs-Evidence discipline

- **Status**: open, P1, brainstorm:complete, arch-evidence:remediation-needed.
- **Mechanism**: 5 primitives + 4 cross-primitive invariants + 14 SCs targeting validation-substitution / closure-narrative paraphrase / story-DD drift failures.
- **Addresses**: completion-verifier and closure verdicts, not code review directly. Indirectly reduces preplanning DD-drift causing spec/intent-mismatch FPs.

### 6.6 chic-orbit-ruler — Implementation reliability

- **Status**: open, P0, north-star. Placeholder.
- **Mechanism**: undefined — calibrates impl-plan + sub-agent context to reduce post-implementation review findings.
- **Addresses**: shifts curve before review fires; total finding reduction.

### 6.7 4911-c7ba — Bug-classification coverage registry + a47f-b451 (follow-on)

- **Status**: open (4911 spec-complete; a47f scrutiny:pending).
- **Mechanism**: 27-slug 9-group registry; mandatory haiku classifier on `/dso:fix-bug` Phase G. Follow-on a47f-b451 aligns reviewer rubric vocabulary with the registry.
- **Addresses**: classification-drift FP class — until a47f ships, reviewers don't speak registry vocabulary.

### 6.8 deck-bulb-eel (deleted)

Was hallucination-detection + approach-viability gate. Hallucination half superseded by verifier (sue-tribe-skid, closed). **Approach-viability half (revert + retry on flawed approach) was NOT absorbed and remains a coverage gap.**

## 7. Observed PR-level FP distribution

Sample: 27 DSO llm-review findings across PRs #171–#201 (last 15 merged PRs, 2026-05-17 → 2026-05-18).

| Failure mode | Count | % of total | % of FPs |
|---|---:|---:|---:|
| Genuine bug catch (TP) | 11 | 41% | — |
| Source-grep / Rule-3 mis-flag | 7 | 26% | 44% |
| Hallucinated function/file reference | 3 | 11% | 19% |
| Spec/intent mismatch | 3 | 11% | 19% |
| Severity inflation | 2 | 7% | 12% |
| Pre-existing mis-flagged as new | 1 | 4% | 6% |
| Doc-only noise | 0 | — | — |
| Style nit | 0 | — | — |

**Current FP rate: ~59% (16/27).** Dominant FP class: source-grep / Rule-3 over-application — test-quality and standard reviewers cite *"Execute, don't inspect"* against tests that legitimately grep workflow YAML, skill markdown, or CI config (artifacts with no behavioral surface). Drove PR #199's "narrow exception" added to `reviewer-delta-standard.md`.

### Notable patterns

1. **Reliable: fail-open/fail-closed correctness findings (~100% TP within sample)** — five separate findings flagged empty-string falling through denylist, all led to fixes. Reviewer's strongest signal.
2. **Reviewer doesn't search subdirectories before declaring file missing** — PR #197 `validate-required-checks.sh` finding (file existed in `scripts/sprint/`); same root cause as bug 0736-a97e (shim subdirectory cascade).
3. **Documentation/spec-only PRs trigger demands for behavioral test coverage that cannot exist** — PRs #182, #184, #185 attracted coverage-gap findings.
4. **Severity rarely downgraded** — no evidence of in-cycle verifier downgrades in PR comments. ADR-0013 verifier severity authority appears underutilized in practice.
5. **Hallucinated tooling vocabulary** — PR #201 `ticket update --status` hallucination over canonical `ticket transition <id> <current> <new>`.
6. **Defense migration is working but reuse is low** — same source-grep finding raised against same lines (`test-onboarding-skill.sh:1522`) across multiple PRs despite defense records.

## 8. Improvement estimates

Estimated FP-rate trajectory:

| Stage | Estimated FP rate | Notes |
|---|---:|---|
| Today | ~59% | n=27 sample, last 15 merged PRs |
| swap-maple-flyby wired (Q3 2026 if S5621+S7034+Sc4f1 ship) | ~48–52% | Severity floor + oscillation bound |
| + side-pane-tithe + a47f-b451 (Q1 2027) | ~33–45% | Iterative rubric pruning |
| + §A–§E proposed additions (prompt-level, weeks) | **~5–15%** | Mechanical grounding fills structural gaps |

**Caveats**: n=27 is small. The 26% source-grep figure could vary widely in a 100-finding sample. Open-epic landing dates are aspirational — swap-maple-flyby has wiring stories shipped piecemeal.

## 9. Proposed additions, ranked by FP-rate reduction on the observed sample

### §A — Typed structural-test exception in test-quality + standard deltas (DOMINANT)

- **Targets**: source-grep / Rule-3 mis-flag (26% of total, 44% of FPs).
- **Mechanism**: extend the existing narrow exception (only covers *removal* of source-grep tests) to a **typed rule** in `code-reviewer-test-quality.md`. When the test's target artifact is in `{workflow YAML, skill markdown, agent prompt, dispatcher contract, dso-config.conf, .github/instructions/*}`, source-grep is the correct testing approach — these artifacts have no behavioral surface. Rule 3 ("Execute, don't inspect") was written for code under test, not contract documents.
- **Effect**: kills 80–90% of source-grep mis-flags. **–21–23% on FP rate.**
- **Cost**: prompt-level delta edit + build-review-agents.sh regen. Single small PR.

### §B — Subdirectory cascade pre-check in standard delta

- **Targets**: hallucinated function/file reference (11% of total, 19% of FPs).
- **Mechanism**: standard reviewer's mandatory pre-check already requires a `read_files` request before "missing reference" findings. Strengthen to extend the `read_files` request to a multi-path candidate cascade — same basename under common plugin script/hook subdirectory prefixes — so a referenced file's true location is discovered even when the literal path is incomplete. Mirrors bug 0736-a97e (dso shim subdirectory cascade). (Path-based file lookup like `find -name` / `glob` is NOT a supported context-request action today — see the context-request contract (`${CLAUDE_PLUGIN_ROOT}/docs/contracts/ci-review-context-request.md`); a future enhancement could add a `glob` action. The multi-path `read_files` cascade is the within-contract approximation.)
- **Effect**: kills 50–70% of hallucinated-reference FPs. **–6–8% on FP rate.**
- **Cost**: prompt-level delta edit.

### §C — Project-vocabulary grounding in reviewer prompts

- **Targets**: hallucinated internal-API references (PR #201 `ticket update --status`).
- **Mechanism**: inject canonical project grammars (ticket CLI reference, shim invocations, project function names) into reviewer dispatch prompts. Extends CLAUDE.md "Always Do These #12" to reviewer prompts.
- **Effect**: kills ~50% of internal-API hallucinations. **–3–5% on FP rate.**
- **Cost**: dispatcher change to fetch vocabulary; context size grows.

### §D — NEW_PRE_EXISTING auto-detection via git blame

- **Targets**: pre-existing mis-flagged as new (4% of total).
- **Mechanism**: pre-emission check in runner.py — for any finding above minor, run `git blame -L <line>,<line> -- <file>`; override relation if blame contradicts.
- **Effect**: kills 70–90% of pre-existing mis-flags. **–3–4% on FP rate.**
- **Cost**: runner.py change (~50 LOC); one git op per important+ finding.

### §E — SC/DD context injection in reviewer prompts

- **Targets**: spec/intent mismatch (11% of total, 19% of FPs).
- **Mechanism**: pass story's success criteria + done-definitions into the reviewer dispatch prompt (via expanded `{issue_context}`). Add `Done-By-Design` section the reviewer must consult before flagging missing coverage on intentional design decisions.
- **Effect**: kills 50–60% of spec/intent-mismatch FPs. **–5–7% on FP rate.**
- **Cost**: dispatcher change to fetch ticket SCs; +~500 tokens per review.

### §F — Asymmetric epistemic refuter (DEFERRED)

Originally proposed before the user surfaced that existing red-team agents themselves produce FPs. Conclusion: **viable only with mechanical grounding gates** (mandatory tool-grounded refutation evidence, fail-closed on the refutation, prompt isolation from reviewer's chain-of-thought, predicate decomposition). Without those gates, the refuter inherits reviewer hallucination rates. **Defer until §A–§E are measured.**

### §G — Per-finding calibrated confidence (DEFERRED)

Reviewer emits `confidence: float`; per-tier threshold in `dso-config.conf`. Requires side-pane-tithe's telemetry substrate for empirical calibration. **Defer until telemetry exists.**

### Aggregate proposed-addition effect

§A through §E together: **–38–47% on FP rate** (from open-epic landing zone ~35–45% down to **plausible ~5–10% end-state**).

## 10. Recommendations

**Highest leverage, lowest risk: ship §A and §B as prompt-level changes in this session.** They target the two largest FP classes (44% + 19% of FPs) with prompt edits to reviewer delta files + build-review-agents.sh regeneration. Single PR through the normal review-and-merge pipeline.

**Medium-term**: §C, §D, §E once §A+§B are measured. §D and §E touch the dispatcher/runner.py.

**Long-term**: §F and §G after side-pane-tithe ships and provides the calibration substrate. §F should only be attempted with mechanical grounding gates per §4.

**Open-epic prioritization** (project owns these — recommendation: don't change priority, but ensure):
- swap-maple-flyby wiring (Stories 5621/7034/c4f1) — needed to unlock the impact-class severity floor.
- side-pane-tithe — needed for calibration metrics; recommend adding Balanced Accuracy + FPR_P/FPR_R to the spec.
- a47f-b451 (reviewer rubric alignment with bug-classification registry) — currently scrutiny:pending; this is the eventual mechanism for §G's empirical calibration.

## 11. Source bibliography

- [SpecRover (ICSE 2025)](https://abhikrc.com/pdf/ICSE25.pdf)
- [AnyPoC (arXiv 2604.11950)](https://arxiv.org/html/2604.11950)
- [Issue2Test (arXiv 2503.16320)](https://arxiv.org/html/2503.16320)
- [AssertFlip (arXiv 2507.17542)](https://arxiv.org/pdf/2507.17542)
- [c-CRAB Code Review Agent Benchmark (arXiv 2603.23448)](https://arxiv.org/html/2603.23448v3)
- [Are LLMs Reliable Code Reviewers? Overcorrection (arXiv 2603.00539)](https://arxiv.org/html/2603.00539)
- [ImpossibleBench (arXiv 2510.20270)](https://arxiv.org/html/2510.20270v1)
- [Refute-or-Promote (arXiv 2604.19049)](https://arxiv.org/html/2604.19049v1)
- [Consensus Trap (arXiv 2604.17139)](https://arxiv.org/html/2604.17139)
- [Calibration and Correctness of LLMs for Code, Spiess et al. (ICSE 2025)](https://www.software-lab.org/publications/icse2025_calibration.pdf)
- [Fine-grained Calibration for Code Revision (arXiv 2604.06723)](https://arxiv.org/html/2604.06723v1)
- [DINCO (arXiv 2509.25532)](https://arxiv.org/html/2509.25532)
- [CISC (ACL 2025 Findings)](https://aclanthology.org/2025.findings-acl.1030/)
- [LLM4PFA (arXiv 2506.10322)](https://arxiv.org/html/2506.10322v1)
- [ZeroFalse (arXiv 2510.02534)](https://arxiv.org/html/2510.02534)
- [Reducing False Positives in Static Bug Detection (arXiv 2601.18844)](https://arxiv.org/html/2601.18844)
- [LAURA (arXiv 2512.01356)](https://arxiv.org/html/2512.01356v1)
- [When More Retrieval Hurts (arXiv 2511.05302)](https://arxiv.org/pdf/2511.05302)
- [Citation-Grounded Code Comprehension (arXiv 2512.12117)](https://arxiv.org/html/2512.12117v1)
- [GSAR Typed Grounding (arXiv 2604.23366)](https://arxiv.org/html/2604.23366v1)
- [Don't Let It Hallucinate (arXiv 2504.06438)](https://arxiv.org/html/2504.06438)
- [Code Execution as Grounded Supervision (ACL EMNLP 2025)](https://aclanthology.org/2025.emnlp-main.1260.pdf)
- [Balanced Accuracy (arXiv 2512.08121)](https://arxiv.org/html/2512.08121v1)
- [Ericsson Code Review at Scale (arXiv 2507.19115)](https://arxiv.org/html/2507.19115v2)
- [CRITIC (OpenReview)](https://openreview.net/forum?id=Sx038qxjek)
- [Do Before You Judge: Self-Reference (arXiv 2509.19880)](https://arxiv.org/pdf/2509.19880)
- [Adversarial Hallucination Attacks (Nature Communications Medicine 2025)](https://www.nature.com/articles/s43856-025-01021-3)
- [Adversarial Code Review pattern — ASDLC.io](https://asdlc.io/patterns/adversarial-code-review/)

