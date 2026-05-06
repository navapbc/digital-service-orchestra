# Contract: phase1-gate-attestation

- Signal Name: completeness_attestation
- Status: accepted
- Scope: brainstorm Phase 1 Gate — completeness attestation field preventing self-attestation bypass
- Date: 2026-05-06

## Purpose

This document defines the `completeness_attestation` field emitted by the brainstorm Phase 1 Gate sub-step. The attestation field blocks self-attestation bypass — the failure mode where an LLM declares the Phase 1 Gate passed without exhausting all gap questions. By requiring an explicit `exhausted` or `open` value, the gate cannot silently pass when unresolved blocking questions remain.

---

## Signal Name

`completeness_attestation`

---

## Status

accepted

---

## Scope

brainstorm Phase 1 Gate — completeness attestation field preventing self-attestation bypass

---

## Date

2026-05-06

---

## Allowed Values

- `exhausted` — all META_QUESTION gap questions are answered; no outstanding blocking_for fields remain; gate may proceed
- `open` — one or more META_QUESTION gap questions are unresolved; the blocking_for field identifies which phase/inference is blocked; gate CANNOT proceed

---

## Blocking Semantics

The Phase 1 Gate CANNOT return `passed` without a `completeness_attestation` value of `exhausted`. Any gate result with `completeness_attestation: open` is a blocking state regardless of other fields. Parsers MUST reject a `passed` gate result that carries `completeness_attestation: open` as a contract violation.

---

## Emitter

brainstorm Phase 1 Gate sub-step — the sub-step that evaluates whether all gap questions surfaced during the Phase 1 dialogue have been resolved before the gate may advance to Phase 2.

---

## Parser

completion-verifier and preplanning gate checks consume this field. The preplanning entry gate reads `completeness_attestation` from the stored Phase 1 Gate output and blocks preplanning dispatch when the value is `open`.

### Canonical parsing prefix

The parser MUST match against:

- `completeness_attestation: exhausted` — exact field match (key: value format). Gate may proceed.
- `completeness_attestation: open` — exact field match. Gate is blocked; `blocking_for` field identifies which phase or inference is blocked.

Parsers must not treat a missing `completeness_attestation` field as `exhausted`. A missing field is treated as `open` (fail-safe default).
