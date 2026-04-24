# Architectural Anti-Pattern Catalog (AP-1…AP-5)

Shared anti-pattern codes used by `/dso:architect-foundation` and any other skill that reasons about architectural risk. Each code is a compact, named failure mode with an enforcement mechanism the architect-foundation skill can recommend.

| Code | Name | Trigger signal | Failure mode | Enforcement mechanism |
|------|------|----------------|--------------|------------------------|
| **AP-1** | Contract without enforcement | Shared mutable state crosses a component boundary (pipeline dict, request context, shared cache). | Callers mutate state the contract says is read-only; bugs appear far from the mutation site. | State-immutability mechanism that fails at **runtime**, not just in docs (frozen dataclasses, immutable records, message-passing). |
| **AP-2** | Error hierarchy leakage | ≥2 variants/providers behind one interface (LLM providers, payment gateways, storage backends). | Provider-specific SDK exceptions leak through the abstraction; callers end up catching vendor types. | Abstract error hierarchy in the interface layer (retryable / rate-limited / authentication / permanent). Each provider maps SDK errors to these categories. |
| **AP-3** | Incomplete coverage | ≥2 variants keyed by enum / string / type tag (output formats, strategy handlers). | A new variant is added without a handler; silent fallback or runtime `KeyError` in production. | Variant registry with a completeness invariant — test-time fitness function asserts registered handlers equal the enum's values. |
| **AP-4** | Parallel inheritance | Variant set grows along two axes (e.g., {CSV, JSON, XML} × {stream, batch}). | Every new axis value forces N edits across siblings; easy to miss one. | Composition over inheritance: factor the cross-cutting axis into a strategy object the registry composes. Fitness function asserts the Cartesian product is complete. |
| **AP-5** | Config bypass | >10 environment-dependent config values, or `os.getenv` / `process.env` read outside a config module. | Business logic diverges per-environment in subtle ways; tests pass locally, fail in staging. | Single typed config module; business logic receives config via constructor injection. Fitness function: `grep` for raw env reads outside the config module returns zero matches. |

## How to use these codes

- **In dialogue** (Phase 1 Group A of architect-foundation): the user's answers map to AP codes via the Trigger signal column.
- **In the blueprint** (Phase 2): include the Enforcement mechanism row for each AP triggered.
- **In fitness functions** (Phase 3): the enforcement mechanism for AP-3, AP-4, AP-5 is directly testable. AP-1 and AP-2 require structural code changes plus a test that verifies the change.

## Adding project-specific anti-patterns

Projects may define AP-6+ for domain-specific risks (e.g., "all PII must flow through the redaction layer"). Record the new code in `ARCH_ENFORCEMENT.md` with the same four columns as the table above.
