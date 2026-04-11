# Debugging Research: LLM Agent Bug-Fixing Best Practices

**Date:** 2026-03-18
**Context:** Research conducted during brainstorm for epic dso-tmmj (Methodical debugging improvements — dso:fix-bug skill)

---

## Sources

- [LLM-based Agents for Automated Bug Fixing: How Far Are We? (arxiv 2411.10213)](https://arxiv.org/html/2411.10213v2)
- [Evaluating Agent-based Program Repair at Google (Passerine, arxiv 2501.07531)](https://arxiv.org/html/2501.07531v1)
- [Agentic Bug Reproduction for Effective APR at Google (arxiv 2502.01821)](https://arxiv.org/html/2502.01821v2)
- [TDFlow: Agentic Workflows for Test Driven Software Engineering (arxiv 2510.23761)](https://arxiv.org/html/2510.23761v1)
- [TDD-Bench Verified: Can LLMs Generate Tests Before Issues Resolved? (arxiv 2412.02883)](https://arxiv.org/html/2412.02883v1)
- [Agentless: Demystifying LLM-based Software Engineering Agents (arxiv 2407.01489)](https://arxiv.org/html/2407.01489v1)
- [A Unified Debugging Approach via LLM-Based Multi-Agent Synergy / FixAgent (arxiv 2404.17153)](https://arxiv.org/html/2404.17153v1)
- [DoVer: Intervention-Driven Auto Debugging for LLM Multi-Agent Systems (arxiv 2512.06749)](https://arxiv.org/html/2512.06749)
- [Diversity Empowers Intelligence: Integrating Expertise of Software Engineering Agents (arxiv 2408.07060)](https://arxiv.org/html/2408.07060v1)
- [A Survey of LLM-based Automated Program Repair: Taxonomies, Design Paradigms, and Applications (arxiv 2506.23749)](https://arxiv.org/html/2506.23749v1)
- [Why LLMs Fail: Failure Analysis for Automated Security Patch Generation (arxiv 2603.10072)](https://arxiv.org/html/2603.10072)
- [Enhancing Fault Localization Through Ordered Code Analysis with LLM Agents and Self-Reflection (arxiv 2409.13642)](https://arxiv.org/html/2409.13642v1)
- [Agentic Code Reasoning / Semi-Formal Reasoning (Meta, arxiv 2603.01896)](https://arxiv.org/pdf/2603.01896)
- [AgentRx: Systematic Debugging for AI Agents (Microsoft Research)](https://www.microsoft.com/en-us/research/blog/systematic-debugging-for-ai-agents-introducing-the-agentrx-framework/)
- [One Agent Isn't Enough — Multi-Agent Convergence (Ben Redmond)](https://benr.build/blog/one-agent-isnt-enough)
- [Blast Radius for Bug Fixing (Taro/Joint Taro)](https://www.jointaro.com/lesson/Lc0DptTAyBIe9Ghf74k6/to-fix-software-bugs-you-must-understand-their-blast-radius/)
- [GitHub Copilot Autofix: Found Means Fixed (GitHub Blog)](https://github.blog/news-insights/product-news/found-means-fixed-introducing-code-scanning-autofix-powered-by-github-copilot-and-codeql/)
- [Patch Overfitting Problem in Automated Program Repair (ACM FSE 2024)](https://dl.acm.org/doi/10.1145/3663529.3663776)
- [SWE-Bench Pro: Long-Horizon Software Engineering Tasks (Scale AI)](https://static.scale.com/uploads/654197dc94d34f66c0f5184e/SWEAP_Eval_Scale%20(9).pdf)
- [Devin Agents 101: Getting Things Done](https://devin.ai/agents101)
- [Confidence Thresholds: Reliable AI Systems (Briq)](https://briq.com/blog/confidence-thresholds-reliable-ai-systems)
- [Agentic Coding Lesson 10: Debugging](https://agenticoding.ai/docs/practical-techniques/lesson-10-debugging)
- [VoltAgent/awesome-claude-code-subagents: error-detective](https://github.com/VoltAgent/awesome-claude-code-subagents/blob/main/categories/04-quality-security/error-detective.md)

---

## 1. Investigation-Before-Fix Discipline

**The core finding across all top-performing systems**: structured investigation before patching is the single largest determinant of fix quality.

**Agentless (2024)** — the highest-performing open-source SWE-bench agent at the time — uses a strict three-stage *localization -> repair -> validation* pipeline with no autonomous tool use. It outperforms complex multi-turn agents while costing $0.34/issue vs. $4+. Key insight: "complex tool usage/design" in fully agentic systems "lacks control in decision planning," often requiring 30-40 turns to solve single issues. The simpler structured approach forces disciplined investigation rather than meandering exploration.

**Google Passerine (2025)** — in production at Google — found that agents skip test execution (the NO_TEST_SMELL) in 66% of *failing* human-reported bug trajectories vs. 13% of *passing* ones. In other words, failing to run tests during investigation is strongly predictive of a bad patch. Machine-reported bugs with structured stack traces got 73% plausible patches; human-reported narrative bugs with fewer code-term signals got only 25.6%. The richer the investigation inputs, the higher the fix rate.

**AgentRx (Microsoft Research)** achieved +23.6% absolute improvement in failure localization and +22.9% in root-cause attribution by requiring *evidence-backed violation logs* before attributing failures. Rather than asking where the problem is, it "pinpoints the first unrecoverable critical failure step," preventing developers from addressing symptoms many steps after the actual error.

---

## 2. Bug Reproduction as Investigation Foundation

**The strongest single intervention in automated repair**: generating a bug reproduction test (BRT) before attempting a patch.

**Google Agentic Bug Reproduction study (2025)**: Providing a generated BRT to the Passerine repair system increased plausible patches from 57% to 74% — a 30% relative improvement. More strikingly: "the probability of Passerine generating a plausible fix given that the generated BRT was used is 33%, compared to only 2% when the BRT was not used." Agents also took fewer steps when given BRTs, suggesting better problem framing rather than random search.

**TDD-Bench Verified (2024)**: Confirmed that tests written before fixes clarify desired behavior. LLM-based test file selection "plays the most significant role" in test quality — achieving 56-62% accuracy vs. 15% for traditional retrieval.

**SWE-bench empirical study on 500 bugs**: "Drafting clear and comprehensive bug reproduction cases within the issue can greatly reduce the difficulty of reproducing the bug." Cases with complete reproducible examples generated "related" reproduction scripts 80.4% of the time; cases with insufficient information only 64%. Agents struggle to reproduce when given vague descriptions, and incorrect reproductions "can result in the failure of the entire solving process."

---

## 3. TDD: Write Failing Test Before Fix

**TDFlow (2025)**: When given human-written failing tests, TDFlow achieves **94.3% success rate** on SWE-bench Verified. When using LLM-generated tests, it drops to 68%. When LLM-generated tests are valid (Bad Test Rate = 0), performance recovers to 93.3%. Conclusion: **"the primary obstacle to human-level software engineering lies within test generation, rather than issue resolution."**

**Broader TDD research**: "TDD led to 18% higher quality code defined by pass rate on functional black box tests."

**Actionable implication**: An agent that first writes a failing test, then patches to make it pass, is structurally constrained to fix the described behavior — not an adjacent symptom.

---

## 4. Root Cause vs. Symptom: The Core Failure Mode

**SWE-bench empirical analysis** identified this as the dominant failure: "The model's understanding should extend beyond the location where the issue occurs (i.e., the symptoms) and include deeper reasoning about the relationship between multiple suspicious locations."

**FixAgent (multi-agent framework)**: Uses **intermediate variable tracking** that "forces agents to analyze the code along the logic execution paths and provide more bug-oriented explanations." Removing program context (specifications and dependencies) reduced correct fixes by 112 bugs — the largest single ablation effect.

**Security patch failures (2026)**: 10.3% of LLM-generated security patches were the most dangerous category — patches that pass all tests but remain exploitable, representing symptom-fixes that mask underlying issues. The bimodal distribution showed "patches either succeed completely (24.8%) or fail substantially, with almost no near-success cases (0.3%)."

---

## 5. The Plausible-vs-Correct Patch Problem (Overfitting)

In C code benchmarks, 73-81% of APR patches are overfitting — they pass the test suite but fail as general solutions. Essential cause: "the test cases used for guiding patch generation are incomplete."

**Implication**: Test-suite passage alone is insufficient as a correctness oracle. Agents need: (a) adversarial edge-case tests, (b) proof-of-concept reproduction tests that specifically target the root cause, and (c) semantic reasoning about *why* the patch is correct, not just *whether* it passes tests.

---

## 6. Structured Reasoning During Investigation

**Semi-formal reasoning (Meta, 2026)**: Requiring agents to construct explicit premises, trace execution paths, and derive formal conclusions. For fault localization on Defects4J, semi-formal reasoning improved Top-5 accuracy by 5 percentage points. For patch equivalence verification, accuracy improved from 78% to 93%.

**Ordered code analysis**: Dependency-graph-sorted ordering achieved a **22% Top-1 accuracy improvement** over execution-ordered baselines. Self-reflection (agents critiquing their own localization outputs) improved performance by ~11%.

**DoVer (do-then-verify pipeline)**: Executes targeted interventions against suspected failure points and measures differential outcomes. On GAIA Level-1 cases, this achieved 27.5% recovery of failed trials and +15.7% progress toward task completion.

---

## 7. Multi-Agent Approaches: Parallel Hypothesis Generation

**The convergence confidence principle**: When two agents independently suggest the same approach, that's evidence it's a local maximum. 4 agents exploring a calibration problem through different lenses all independently converged on the same root cause. The synthesizer "tends toward simpler solutions when convergence supports it."

**DEI framework (2024)**: A group of open-source SWE agents with a maximum individual resolve rate of 27.3% achieved **34.3% resolve rate with diverse ensemble integration** — a 25% relative improvement. Optimal ensemble size is 4-5 diverse agents, not unlimited.

**FixAgent multi-agent ablation**: Removing multi-agent coordination reduced correct fixes by 28 bugs on a 300-bug dataset (~9% relative). The key is *role specialization* — separate agents for localization, repair, and root cause explanation — not just parallelism.

**Convergence weighting**: Use Agent Forest / sampling-and-voting patterns. "3/5 subagents converging on a solution is evidence that solution is what you want."

---

## 8. Escalation Criteria: When NOT to Fix Autonomously

**Signals that predict autonomous failure**:
- Multiple suspicious locations with no causal explanation linking them (SWE-bench: 0% success across all 6 systems)
- Human-reported narrative bugs with fewer than 2 code-term mentions (Google: only 18% vs. 60% have sufficient code terms)
- Bugs where the patch requires changes to 5+ files or crosses subsystem boundaries (negative correlation between human patch size and LLM success)
- Bugs that require understanding non-local security semantics (0% fix rate for input validation CWEs)

**"Repair abstention"**: Google is explicitly developing abstention capabilities for Passerine — "to enable Passerine to abstain from running on bugs that it is unlikely to fix."

**Tiered autonomy model**: Fully automated for routine/structured cases; human review for medium-confidence; mandatory escalation for high-stakes or low-confidence. "The right threshold depends on the cost of each outcome."

---

## 9. Bug Classification and Routing

Machine-reported bugs (sanitizer failures, flaky test order) are "mechanical" — they have structured reproduction data, predictable fix locations, and 73% plausible patch rates. Human-reported "behavioral" bugs (narrative descriptions, ambiguous symptoms) achieve only 25.6%.

**Routing implications**: CWE-type routing in security patches improved fix rates from 0% (input validation) to 45% (infinite loops). Category-specific routing outperforms one-size-fits-all approaches.

COMPLEX bugs should be escalated to a planning/epic workflow rather than a single fix attempt (SWE-bench Pro: 17-23% on enterprise-scale issues vs. 70%+ on verified individual issues).

---

## 10. Error-Detective Sub-Agent (VoltAgent)

The `error-detective` from the `error-debugging` plugin is a pattern recognition and correlation agent. Core techniques relevant to dso:fix-bug:

**Root cause techniques**: five whys, fishbone diagrams, fault tree analysis, timeline reconstruction, hypothesis testing/elimination.

**Cascade analysis**: failure propagation, service dependencies, circuit breaker gaps, timeout chains, retry storms, resource exhaustion, domino effects.

**Investigation pattern**: "Start with symptoms, follow error chains, check correlations, verify hypotheses, document evidence, test theories, validate findings, share insights."

**Collaborative routing**: delegates to `debugger` for specific issues, `performance-engineer` for perf errors, `security-auditor` for security patterns.

---

## Design Principles Summary

| Principle | Evidence Base |
|---|---|
| Investigate first: reproduce before patching | Google BRT: +30% plausible patches; 33% vs. 2% with/without BRT |
| Write failing test before implementing fix | TDFlow: 94.3% with human tests vs. 68% without; TDD: +18% quality |
| Do structured localization (file -> class -> line) | Agentless: 77.7% -> 55.3% -> 50.8% hierarchical narrowing, lowest cost |
| Use self-reflection on localization output | +11% accuracy improvement before any external feedback |
| Apply 5-Why root cause analysis | Prevents the dominant failure mode: symptom-fixing |
| Track intermediate variable execution paths | FixAgent: largest ablation gain; prevents misguided patches |
| Read code in dependency order | +22% Top-1 fault localization accuracy |
| Score convergence across parallel hypotheses | 3/5 convergence = high confidence; ensemble: 25% relative improvement |
| Gate patch acceptance on more than test-suite pass | 73-81% of plausible patches overfit; require proof-of-concept tests |
| Escalate when: no causal link, narrative bug with <2 code terms, 5+ files | Google: 0% success; developing abstention capability |
| Classify bug type and route accordingly | Mechanical/structured -> fix; behavioral/narrative -> more investigation |
