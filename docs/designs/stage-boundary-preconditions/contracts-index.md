# Stage-Boundary PRECONDITIONS Contracts Index

This index consolidates the load-bearing invariants from all stories in the
stage-boundary-preconditions epic (736d-b957). Each contract is a pinned invariant — any
future change to the behavior it describes requires updating the contract document and this
index.

---

## Contract Documents

| Contract | File | Story | Summary |
|----------|------|-------|---------|
| Latest-selection + LWW | `plugins/dso/docs/contracts/preconditions-schema-v2.md` | a96b-7ba8 | Latest = highest timestamp per `(gate_name, session_id, worktree_id)`; ties by filename lex; read-side LWW across full event set |
| Depth-agnostic validator | `plugins/dso/docs/contracts/preconditions-schema-v2.md` | a497-ee7c | Validators read only minimal-tier fields; ignore unknown fields; never reject well-formed standard/deep events |
| Self-verification semantics | `plugins/dso/docs/contracts/preconditions-schema-v2.md` | a497-ee7c | Schema-roundtrip + cross-stage chain via `event_id` reference; chain-of-trust rooted at brainstorm writer's schema check |
| schema_version forward-compat | `plugins/dso/docs/contracts/preconditions-schema-v2.md` | 86ad-f5e7 | Every event carries `schema_version`; unknown versions fall back to minimal interpretation with one-time warning |
| Compaction ordering | `plugins/dso/docs/contracts/preconditions-schema-v2.md` | 0263-62ba | Epic-closure validator runs before compaction; atomic-rename snapshot; reader handles both formats; retry-once on transient miss |
| FP auto-fallback scope | `plugins/dso/docs/contracts/fp-auto-fallback-scope.md` | 1e71-3886 | Per-write, new events only, per-ticket; existing standard/deep events remain honored; validators stay depth-agnostic |
| SC9 coverage result | `plugins/dso/docs/contracts/coverage-harness-output.md` | 1e71-3886 | COVERAGE_RESULT signal; ≥100/818 prevention threshold; dry-run harness output format |

---

## Guide Documents

| Guide | Description |
|-------|-------------|
| [schema-reference.md](schema-reference.md) | Full schema field reference for all depth tiers; field shapes, schema_version evolution policy, forward-compat contract |
| [validator-guide.md](validator-guide.md) | How to add a stage-boundary validator; depth-agnostic contract; entry/exit hook library usage; zero-user-interaction invariant |
| [consumer-guide.md](consumer-guide.md) | How to read PRECONDITIONS events; `_read_latest_preconditions()` API; snapshot format; LWW policy; consumer integration points |
| [ops-runbook.md](ops-runbook.md) | FP auto-fallback monitoring; SC9 coverage gate; SC13 restart analysis; troubleshooting guides for common failure modes |

---

## Pinned Contracts Summary

These six invariants are the load-bearing contracts of the system. Violating any of them
constitutes a breaking change and requires a `schema_version` bump or deprecation notice.

1. **Latest-selection + LWW** (Story a96b-7ba8): composite key = `(gate_name, session_id, worktree_id)`; latest timestamp wins.
2. **Depth-agnostic validator** (Story a497-ee7c): all validators accept all depth tiers without modification.
3. **Self-verification semantics** (Story a497-ee7c): validators dogfood their own PRECONDITIONS events.
4. **schema_version forward-compat** (Story 86ad-f5e7): unknown versions → minimal interpretation, never rejection.
5. **Compaction ordering** (Story 0263-62ba): validator before compaction; atomic snapshot write.
6. **FP auto-fallback scope** (Story 1e71-3886): per-ticket, per-write, new events only.
