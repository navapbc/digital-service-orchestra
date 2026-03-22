---
id: dso-5ooy
status: open
deps: [w21-ykic, w21-ovpn]
links: [dso-8l5h]
created: 2026-03-21T23:27:40Z
type: epic
priority: 2
assignee: Joe Oakhart
---
# Conditional Security & Performance Review Overlays


## Notes

<!-- note-id: k3xxzh2r -->
<!-- timestamp: 2026-03-21T23:28:18Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->


## Context

Security and performance concerns cut across all review dimensions but don't belong as permanent sub-criteria in every review — they waste tokens on changes with no security/performance surface. This epic adds conditional review overlays that trigger only when the classifier detects relevant signals, orthogonal to the tier system (any tier can trigger an overlay).

## Brainstorm Research (to be resumed)

### Architecture Decision
- Security and performance reviews are **conditional overlays**, not permanent dimensions
- Triggered by classifier signals alongside tier routing: classifier emits trigger flags (security_review: true, performance_review: true)
- Any tier level can trigger an overlay — a Light tier change touching auth still gets security review
- Each overlay has its own dedicated reviewer agent, checklist, and findings that merge into reviewer-findings.json

### Security Review Triggers (proposed)
- Code that touches external integrations
- Code that touches data layer
- Authentication or authorization code
- Encryption-related code

### Security Review Criteria (from research)
Source: Anthropic claude-code-security-review (OWASP-aligned)
- Injection attacks: SQL, command, LDAP, XPath, NoSQL, XXE
- Authentication & authorization: broken auth, privilege escalation, insecure direct object references, auth bypass, session flaws
- Data exposure: hardcoded secrets, sensitive data logging, information disclosure, PII handling violations
- Cryptographic issues: weak algorithms, improper key management, insecure RNG
- Input validation: missing validation, improper sanitization, buffer overflows
- Business logic flaws: race conditions, TOCTOU (time-of-check-time-of-use)
- Configuration security: insecure defaults, missing security headers, permissive CORS
- Supply chain: vulnerable dependencies, typosquatting
- Code execution: RCE via deserialization, pickle injection, eval injection
- XSS: reflected, stored, DOM-based
- Error message information leakage (OWASP): errors that reveal internal state

### Performance Review Triggers (proposed)
- Any operation more expensive than O(n)
- Code that touches infrastructure
- Code that touches data layer
- Future enhancement: trigger on spike in test runtime or application latency in E2E testing (needs friction-free way to surface this data)

### Performance Review Criteria (from research)
- N+1 query problems
- Nested loops over large datasets
- Inefficient algorithms or database queries
- Memory usage patterns and potential leaks
- Bundle size and optimization opportunities
- Sequential I/O where parallel is possible (AI-specific)
- Image optimization

### Integration Architecture (to be designed)
Pipeline becomes: classifier → tier + overlay triggers → dispatch tier reviewer(s) + overlay reviewer(s) → merged findings → resolution loop
- Overlay reviewers need own agent definitions and checklists
- Findings merge into same reviewer-findings.json and scoring
- Classifier/dispatch changes needed to trigger overlays
- Performance runtime trigger (pytest --durations baseline comparison) deferred as future enhancement to avoid friction

### Open Questions
- Exact classifier signal thresholds for triggering overlays
- Whether overlays should have their own severity scale or use the existing critical/important/minor
- How overlay findings interact with the autonomous resolution loop
- Whether the security overlay replaces or supplements the existing dso-0wi2 sensitive-info security review

## Dependencies
- w21-ykic (Tiered Review Architecture): requires classifier infrastructure to add overlay trigger signals
- w21-ovpn (Review Intelligence & Precision): requires enriched checklist architecture (reviewer-delta files, confidence scoring, false-positive filters)


**2026-03-22T05:52:37Z**


## Spec (finalized — replaces prior brainstorm research)

## Context

Security and performance concerns cut across all review dimensions but don't belong as permanent sub-criteria in every review — they waste tokens on changes with no security or performance surface. When a change does touch sensitive code, the standard tier review lacks the depth and focus of a dedicated specialist. Engineers today either miss security issues until production or get blocked by false positives on changes with no real security surface. This epic adds conditional review overlays that trigger through defense-in-depth classification: deterministic pattern matching in the tier classifier provides first-line detection, while lightweight checklist items in the standard reviewer provide a fallback signal. Security uses a red/blue team architecture — aggressive detection followed by context-aware triage — to maximize recall without blocking valid changes. Performance uses a single calibrated reviewer with bright-line severity rules tied to scaling behavior and resource exhaustion. Both overlays use opus for the reasoning depth these concerns require. This epic supersedes the security review flag previously proposed in dso-0wi2.

## Success Criteria

1. The tier classifier (review-complexity-classifier.sh, delivered by w21-ykic) is extended to emit two additional boolean flags (security_overlay, performance_overlay) alongside the tier score, triggered by deterministic pattern matching on file paths, import statements, and diff content associated with security-sensitive or performance-sensitive changes.

2. When a deterministic signal fires, the corresponding overlay launches in parallel with the tier reviewer. When no deterministic signal fires but the tier reviewer's checklist item for that overlay (see criterion 3) is marked affirmative, the overlay launches serially after tier review completes. When neither fires, no overlay runs.

3. The tier reviewer agents delivered by w21-ovpn are extended with two permanent lightweight classification checklist items — one security flag, one performance flag — added to each agent's reviewer-delta file. These items indicate whether the change warrants specialized overlay review and are always present regardless of whether a deterministic signal fired. Their presence is verifiable by inspecting the reviewer-delta files and confirmed by the items appearing in reviewer output on any diff.

4. The security overlay uses a red/blue team architecture: a red team opus agent reviews the diff without ticket context using an aggressive detection directive, then a blue team opus agent evaluates each red team finding with full ticket context and can dismiss (invalid in context), downgrade (real but lower severity — e.g., important to minor), or sustain (stands as-is) each finding. Only findings that survive blue team review at critical or important severity block the commit.

5. The security red team evaluates criteria focused on where AI reasoning adds value beyond deterministic tools: authorization completeness, data flow from untrusted input to dangerous sinks (multi-hop and cross-file), fail-open error handling, state machine integrity, privilege escalation via indirect paths, cryptographic misuse (correct algorithm applied incorrectly), TOCTOU race conditions, and trust boundary violations. Newly introduced entry points and sensitive data exposure patterns are lenses for additional scrutiny, not standalone findings. Criteria that deterministic scanning tools (Bandit, Semgrep) catch reliably are explicitly excluded from the prompt with a note that tooling coverage is handled separately.

6. The performance overlay uses a single opus reviewer with two bright-line severity tests applied in order: (a) It breaks — will this cause a timeout, OOM, crash, connection exhaustion, or resource starvation under expected load? Then critical. (b) It scales — does this issue get worse as data volume, user count, request rate, or time increases? Then important. If neither test applies (fixed cost regardless of scale), then minor. Only critical and important findings block.

7. The performance reviewer evaluates criteria focused on where AI reasoning adds value: database calls inside loop bodies, sequential I/O that could be parallel, unbounded accumulation without eviction, over-fetching relative to downstream usage, blocking operations in concurrent/async contexts, cache stampede potential, unnecessary materialization of lazy/streaming data, and connection/resource pool misuse. Operations with non-linear complexity and frequently-called code paths are lenses for additional scrutiny, not standalone findings. Criteria that deterministic tools (Ruff PERF, perflint) catch reliably are explicitly excluded.

8. Overlay findings use the existing severity scale (critical/important/minor) and enter the autonomous resolution loop established by w21-ovpn. Minor findings create tracking tickets via the same path as standard review minor findings.

9. Both overlay prompts include false-positive reduction: hard exclusion lists (test-only files, issues deterministic tools should catch, theoretical concerns requiring unusual conditions to manifest), scope restriction to changed code in the diff, anti-manufacturing directives, and rationalizations-to-reject lists (common reasoning shortcuts that produce false positives).

10. The security red team, security blue team, and performance reviewer are each implemented as dedicated plugin agents with per-agent reviewer-delta files, built using the source-fragment build process (build-review-agents.sh) delivered by w21-ykic story dso-9ltc. This epic creates the three new delta files and agent definitions; it does not deliver the build infrastructure itself.

11. Engineers submitting changes that touch security-sensitive or performance-sensitive code paths receive overlay findings scoped to context-aware concerns that deterministic scanners would miss. For security, blue team triage filters findings to those relevant to the actual change, preventing false positives from blocking valid code. For performance, the bright-line severity rules ensure only scaling failures and resource exhaustion block — fixed-cost optimizations are tracked but do not interrupt the engineer's workflow.

12. Before the epic is closed, both overlays are run retrospectively against the last 20 merged commits that touched security-sensitive or performance-sensitive paths (as classified by the new classifier). The retrospective reports: overlay trigger rate, findings generated per overlay, blue team dismissal rate for security, and severity distribution for performance. These baselines are committed as the initial calibration reference for post-deployment monitoring.

## Approach

Defense-in-depth classification with deterministic triggers in the tier classifier and lightweight reviewer flags as fallback. Security uses a red/blue team architecture (red team opus for aggressive detection without context, blue team opus for context-aware triage with dismiss/downgrade/sustain authority). Performance uses a single calibrated opus reviewer with bright-line severity rules. Both overlays are orthogonal to the tier system — any tier can trigger an overlay.

## Dependencies

- w21-ykic (Tiered Review Architecture): classifier infrastructure for adding overlay trigger signals, tier routing for overlay dispatch, agent build process (dso-9ltc)
- w21-ovpn (Review Intelligence & Precision): enriched checklist architecture (reviewer-delta files that this epic extends with classification items), confidence scoring framework, resolution loop that overlay findings enter
- dso-8l5h (Extract review and evaluation sub-agents): coordination dependency (not blocking) — both epics produce dedicated plugin agents and should use consistent conventions

## Supersedes

Security review flag from dso-0wi2 (project-level config flags). The overlay approach provides conditional, classifier-triggered security review rather than a blanket project-level flag.

## Research Artifacts

Detailed research on security and performance review criteria, deterministic tooling landscape, and Claude Code plugin prior art was conducted during brainstorm. Key sources: OWASP Secure Code Review Guide, Anthropic claude-code-security-review plugin, Trail of Bits security-review-skill, Semgrep/Bandit/CodeQL capability analysis, perflint/Ruff PERF analysis, Tarek Ziade algorithmic complexity study. Research informed the criteria selection (AI-advantaged only) and false-positive reduction techniques.

