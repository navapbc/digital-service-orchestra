---
id: dso-5ooy
status: open
deps: [w21-ykic, w21-ovpn]
links: []
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

