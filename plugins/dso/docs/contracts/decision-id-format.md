# Contract: decision-id-format

- Signal Name: decision-id-format
- Status: accepted
- Scope: inference challenge tracking — decision identity across sessions
- Date: 2026-05-05

## Purpose

Defines the canonical format for decision IDs used to uniquely identify inference decisions across sessions. Decision IDs enable deduplication in the inference incident corpus, challenge tracking in the inference envelope, and corpus entry linkage. This contract must be agreed upon before any emitter or parser is implemented.

## Signal Name

`decision-id-format`

---

## Status

accepted

---

## Scope

Identifies individual inference decisions across sessions for deduplication, challenge tracking, and corpus entry linkage.

---

## Date

2026-05-05

---

## Format

```
<session_id>:<content_hash>
```

Where:
- `session_id` — resolved via the following chain: harness file → `DSO_SESSION_ID` env → `pv-session-<timestamp_ms>`
- `content_hash` — SHA-256 of the decision text (first 16 hex characters)

### session_id sourcing chain

1. Harness file (e.g., `.claude/session-id` written at session start)
2. `DSO_SESSION_ID` environment variable
3. `pv-session-<timestamp_ms>` generated at decision time

### content_hash

SHA-256 hash of the decision text (the full inference claim or assertion text), truncated to the first 16 hexadecimal characters.

Example: `sha256("The cache will be warm") = "a3f7...` → content_hash = `a3f70b2c14e8d931`

### Full example

```
pv-session-1746500000000:a3f70b2c14e8d931
```

---

## Emitter

The inference envelope emitter constructs decision IDs at the time each inference decision is recorded. The emitter resolves the session_id via the sourcing chain above and computes the SHA-256 hash of the decision text.

---

## Parser

The inference incident curator agent and corpus harness parse decision IDs by splitting on `:` to extract session_id and content_hash separately. Parsers must tolerate `pv-session-<timestamp_ms>` format session IDs and must not reject IDs with unfamiliar session_id prefixes.

### Canonical parsing prefix

The parser MUST split the decision ID string on the first `:` character to separate `session_id` from `content_hash`. The `session_id` portion may contain further colons if the environment variable contains them — only the LAST segment (16 hex chars) is the `content_hash`. Parsers MUST accept any `session_id` prefix and MUST NOT reject IDs with unrecognized prefix formats.

---

## Examples

```
pv-session-1746500000000:a3f70b2c14e8d931
my-session-abc123:deadbeef01234567
DSO_SESSION_ID_value:0011223344556677
```

---

## Consumers

| Component | Role |
|-----------|------|
| Inference envelope emitter | Generates decision IDs |
| Inference incident curator | Indexes incidents by decision ID |
| Corpus harness | Deduplicates entries by decision ID |
