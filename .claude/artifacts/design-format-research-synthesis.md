# Design Format Research Synthesis

Research conducted 2026-03-30 for epic dso-v558. Evaluates DSO's 3-artifact design manifest format against industry approaches and academic findings.

---

## Research Sources

### Academic Papers
- **PrototypeFlow** ([arXiv 2412.20071](https://arxiv.org/html/2412.20071v3)) — Human-AI synergy in UI design with intent clarification and alignment
- **DCGen** ([arXiv 2406.16386](https://arxiv.org/html/2406.16386v1)) — Divide-and-conquer approach to screenshot-to-code with hierarchical intermediate representation

### Industry Publications
- **Hardik Pandya** ([Expose your design system to LLMs](https://hvpandya.com/llm-design-systems)) — 3-layer approach: spec files + token layer + audit. Atlassian case study (64 spec files, 230+ tokens)
- **Storybook MCP** ([Codrops](https://tympanus.net/codrops/2025/12/09/supercharge-your-design-system-with-llms-and-storybook-mcp/)) — Component Manifest as curated metadata payload for LLM agents
- **LogRocket** ([Design-to-code with Figma MCP](https://blog.logrocket.com/ux-design/design-to-code-with-figma-mcp/)) — Structuring Figma files for MCP and AI-powered code generation
- **Addy Osmani** ([How to write a good spec for AI agents](https://addyosmani.com/blog/good-spec/), [AI-driven prototyping](https://addyo.substack.com/p/ai-driven-prototyping-v0-bolt-and)) — Spec format best practices; v0/Bolt/Lovable comparison
- **Design Tokens Meet Agents** ([Medium/Praxen](https://medium.com/@Praxen/when-design-tokens-meet-agents-e77ef9f239f3)) — Structuring tokens for agent consumption
- **Chrome DevTools** ([Efficient token usage](https://developer.chrome.com/blog/designing-devtools-efficient-token-usage)) — Token efficiency in AI assistance
- **GitHub** ([Spec-driven development](https://github.blog/ai-and-ml/generative-ai/spec-driven-development-with-ai-get-started-with-a-new-open-source-toolkit/)) — Spec Kit and the SDD movement

---

## Key Research Findings

### Finding 1: Structured text decisively outperforms visual input for LLM code generation

Every source confirms this. The LogRocket article states: **"An image alone doesn't give an AI model enough context to produce a pixel-perfect result."** Pandya's work shows structured spec files prevent the LLM from fabricating values: "Instead of the LLM deciding 'what blue should this link be?', it reads a spec file and finds `var(--color-link)`."

The design tokens article is explicit: **"Agents cannot interpret screenshots; they require semantic token definitions that explain *when* and *why* to use each token, not just what it looks like."**

**Implication for DSO:** Our spatial-layout.json (structured hierarchy) and tokens.md (semantic behavioral specs) are the right primary formats. The SVG wireframe serves human reviewers, not implementation agents.

### Finding 2: Natural language outperforms code as an intermediate representation

DCGen (arXiv 2406.16386) directly tested this: they compared natural language descriptions vs UI code as the intermediate format passed between pipeline stages. **Natural language descriptions generally performed better.** They found that "smaller coding errors tend to propagate and accumulate during the assembly process" when using code-based intermediates.

**Implication for DSO:** Our tokens.md (markdown behavioral specifications) is a stronger intermediate format than generated code would be. HTML wireframes, while useful for pushing to Figma, should NOT be the format the implementation agent reads for behavioral intent.

### Finding 3: Intermediate representation transparency is critical for intent preservation

PrototypeFlow (arXiv 2412.20071) found that designers need to **"review and refine intermediate results"** — making intermediate checkpoints transparent was a key success factor. Their ablation study showed removing theme description transparency caused local inconsistencies.

**Implication for DSO:** Our 3-artifact split (each artifact visible and reviewable independently) provides this transparency. The ID-Linkage Method enables stakeholders to trace any element across all representations.

### Finding 4: Curated component metadata dramatically reduces token cost

Storybook MCP found that **"a single component generation task can consume 50K-100K tokens just to load context before the agent starts writing code."** Their Component Manifest — a curated metadata payload with component APIs, validated patterns, and test suites — dramatically reduces this.

**Implication for DSO:** Our spatial-layout.json serves the same role as the Component Manifest: curated metadata (component type, design system ref, props, ARIA) rather than raw source code. The implementation agent reads structured specs instead of scanning the codebase.

### Finding 5: Small, focused context beats one giant prompt

Osmani's spec guide emphasizes: **"Small, focused context beats one giant prompt."** Too many directives simultaneously reduces adherence (the "curse of instructions").

**Implication for DSO:** Our 3-artifact split enables **modular context loading** — the implementation agent can load only the relevant artifact for each step:
- Step 1 (structure): Read spatial-layout.json only (~2-5k tokens)
- Step 2 (layout): Cross-reference SVG spatial positions (~5-12k tokens)
- Step 3 (behavior): Read tokens.md sections as needed (~1-3k per section)

This is more token-efficient than a single monolithic spec that must be loaded entirely.

### Finding 6: Audit/verification prevents drift

Pandya's 3-layer approach includes audit scripts that scan output and flag hardcoded violations. **"Zero errors required"** for deployment — drift is a blocking issue. Design tokens should include whitelisted names to prevent hallucinated tokens like `color.button.magic.blue`.

**Implication for DSO:** Our format's ID-Linkage validation catches structural inconsistencies, but we lack a token audit layer. This could be added as a post-implementation check that verifies the code references only tokens declared in tokens.md.

### Finding 7: The "70% problem" in AI UI generation

Osmani's comparison of v0/Bolt/Lovable found they all hit a **"complexity threshold where shifting to editing code locally will be necessary"** — roughly 70% of the design can be generated, but the remaining 30% requires human refinement. None of these tools preserve design intent systematically.

**Implication for DSO:** Our structured specification approach is designed to push past this threshold by providing the implementation agent with explicit behavioral specs, not just visual targets. The 3-artifact format encodes the "last 30%" (interactions, states, a11y, responsive rules) that pure visual approaches miss.

### Finding 8: Code Connect is the #1 way to ensure component reuse

LogRocket's Figma MCP article: **"Code Connect is the #1 way to get consistent component reuse in code."** Mapping Figma components to actual codebase components ensures agents reference the real component library rather than generating from scratch.

**Implication for DSO:** Our `design_system_ref` field in spatial-layout.json serves the same purpose as Code Connect — it tells the implementation agent exactly where to import each component from. The EXISTING/MODIFIED/NEW tags extend this by classifying the sourcing strategy.

---

## Evaluation: DSO's 3-Artifact Format Against Research Findings

| Research Finding | DSO Format Alignment | Gap? |
|-----------------|---------------------|------|
| Structured text > visual | **Strong** — JSON + markdown are primary; SVG is supplementary | SVG could be optional for agent consumption |
| Natural language > code as IR | **Strong** — tokens.md uses markdown, not code | None |
| Intermediate transparency | **Strong** — 3 artifacts are independently reviewable | None |
| Curated component metadata | **Strong** — spatial-layout.json is a component manifest | None |
| Modular context loading | **Strong** — 3-artifact split enables per-step loading | Could be more granular (tokens.md sections as separate files) |
| Audit/verification | **Partial** — ID-linkage validation exists | Missing: token audit for hardcoded values |
| Behavioral encoding | **Strong** — tokens.md captures interactions, states, a11y, responsive | None — this is our key differentiator |
| Component sourcing | **Strong** — EXISTING/MODIFIED/NEW + design_system_ref | None |

**Overall assessment: The 3-artifact format is well-aligned with research best practices.** It is MORE comprehensive than most industry approaches (which focus on visual + component specs but skip behavioral encoding) and follows the right format choices (structured text over visual, natural language over code, modular over monolithic).

---

## Implication for Pull-Back Format

### The SVG Insight

The research reveals something important: **the SVG wireframe is primarily a human artifact, not an agent artifact.** The implementation agent's primary sources are:
1. spatial-layout.json (component structure, props, sourcing strategy)
2. tokens.md (behavioral specs, design tokens, a11y, states)

The SVG provides supplementary spatial proportion hints, but the JSON `spatial_hint` field takes precedence when they conflict (per the skill spec). This means:

- On **push** to Figma: The HTML wireframe (generated from all 3 artifacts) is the right format — it's a visual artifact for the human designer
- On **pull** from Figma: We need to regenerate **JSON + markdown**, not SVG. The SVG can be reconstructed from Figma screenshots or `get_screenshot` output if needed for human review later.

### Recommended Pull-Back: Regenerate JSON + Markdown with Behavioral Merge

```
PULL FROM FIGMA:
  get_design_context  → component hierarchy + code → NEW spatial-layout.json
  get_metadata        → positions, sizes         → spatial_hint updates
  get_variable_defs   → design token values       → tokens.md Section 5 updates

MERGE WITH ORIGINAL:
  Original tokens.md Sections 1-4 (interactions, responsive, a11y, states)
    + Updated Section 5 (design tokens from Figma)
    + Reconciliation flags for structural changes
  = Updated tokens.md

  Original spatial-layout.json EXISTING/MODIFIED/NEW tags
    + design_system_ref paths
    + modification_notes, justification
    + Updated hierarchy and spatial_hints from Figma
    + [DESIGNER_ADDED] flag for new components
  = Updated spatial-layout.json

SVG DEFERRED:
  Not regenerated during pull.
  Can be created on-demand from get_screenshot or from the implementation.
  The implementation agent does not need it.

CHANGELOG:
  Appended to manifest.md documenting what the designer changed.
```

### Token Budget

| Step | Tokens | Notes |
|------|--------|-------|
| Pull (MCP calls) | ~3-5k | get_design_context + get_metadata + get_variable_defs |
| Read original artifacts | ~10-24k | Full 3-artifact set for merge context |
| Merge + regeneration | ~8-15k | Conversion agent output |
| **Updated manifest (agent reads)** | **~5-12k** | JSON + markdown only (no SVG) |

By dropping SVG from the pull-back, we save ~5-12k tokens on the regeneration step AND ~5-12k on every subsequent implementation agent read. The implementation agent reads a **leaner 2-artifact set** that carries the same design intent.
