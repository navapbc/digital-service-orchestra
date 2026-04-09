# Contract: ReducerStrategy Interface for ticket-reducer.py

- Status: accepted
- Scope: ticket-system-v3 (epic w21-ablv), sync-events story (w21-6k7v)
- Date: 2026-03-21

## Purpose

This document defines the `ReducerStrategy` protocol interface exposed by `ticket-reducer.py` for pluggable conflict resolution in multi-environment event merging.

The `ReducerStrategy` interface allows downstream consumers (e.g., `w21-05z9 MostStatusEventsWinsStrategy`) to implement custom merge logic without importing from `ticket-reducer.py` — structural subtyping via `typing.Protocol` means any class with a matching `resolve` method satisfies the protocol.

---

## Signal Name

`ReducerStrategy`

---

## Emitter

`plugins/dso/scripts/ticket-reducer.py` # shim-exempt: internal implementation path reference

---

## Consumer

`w21-05z9` — `MostStatusEventsWinsStrategy` (implements `ReducerStrategy` to prefer the event stream with more status transitions when merging events from multiple environments).

---

## Interface Definition

```python
from typing import Protocol, runtime_checkable

@runtime_checkable
class ReducerStrategy(Protocol):
    def resolve(self, events: list[dict]) -> list[dict]:
        """Merge and/or deduplicate a flat list of events from multiple sources.

        Args:
            events: A flat list of event dicts, each containing at minimum:
                    - "uuid" (str): unique event identifier
                    - "timestamp" (int): UTC epoch seconds

        Returns:
            A list[dict] of resolved events, ready for reduction by
            reduce_ticket(). Order and deduplication semantics are
            strategy-specific.
        """
        ...
```

### Method Signature

```
resolve(events: list[dict]) -> list[dict]
```

| Parameter | Type        | Description                                                       |
|-----------|-------------|-------------------------------------------------------------------|
| `events`  | `list[dict]`| Flat list of event dicts from one or more environments            |
| returns   | `list[dict]`| Resolved (deduped and/or sorted) list ready for `reduce_ticket()` |

### Canonical parsing prefix

The parser MUST match against:

- `ReducerStrategy` — this contract defines a Python `typing.Protocol` interface, not a line-based signal. Callers detect conformance via structural subtyping: any object whose class provides a `resolve(self, events: list[dict]) -> list[dict]` method satisfies the protocol. No text prefix matching applies; conformance is checked via `isinstance(obj, ReducerStrategy)` when `@runtime_checkable` is active.

---

## Default Strategy: `LastTimestampWinsStrategy`

`LastTimestampWinsStrategy` is the default implementation shipped in `ticket-reducer.py`. It is used when no explicit strategy is passed to `reduce_ticket()`.

### Behavior

1. **Deduplication by UUID**: If two events share the same `uuid` value, only the first occurrence (in iteration order) is kept. UUID uniqueness is the authoritative identity for events — a UUID appearing in two event streams represents the same event, not two separate events.
2. **Ascending sort by timestamp**: After deduplication, events are sorted in ascending order by their `timestamp` field (UTC epoch seconds). This is equivalent to chronological order.

### Signature

```python
class LastTimestampWinsStrategy:
    def resolve(self, events: list[dict]) -> list[dict]:
        ...
```

### Example

```python
events = [
    {"uuid": "aaa", "timestamp": 100, "event_type": "CREATE"},
    {"uuid": "bbb", "timestamp": 200, "event_type": "STATUS"},
    {"uuid": "aaa", "timestamp": 100, "event_type": "CREATE"},  # duplicate UUID — dropped
    {"uuid": "ccc", "timestamp": 150, "event_type": "COMMENT"},
]

strategy = LastTimestampWinsStrategy()
result = strategy.resolve(events)
# result:
# [
#   {"uuid": "aaa", "timestamp": 100, "event_type": "CREATE"},
#   {"uuid": "ccc", "timestamp": 150, "event_type": "COMMENT"},
#   {"uuid": "bbb", "timestamp": 200, "event_type": "STATUS"},
# ]
```

---

## Integration with `reduce_ticket()`

`reduce_ticket()` accepts an optional `strategy` parameter:

```python
def reduce_ticket(
    ticket_dir_path: str | os.PathLike[str],
    strategy: ReducerStrategy | None = None,
) -> dict | None:
    ...
```

- When `strategy` is `None` (the default), `LastTimestampWinsStrategy()` is used.
- The `strategy` parameter is available for callers on the **sync-events merge path** — it is not invoked during single-directory reduction of a local ticket.
- **Backward compatible**: all existing `reduce_ticket(path)` call sites continue to work without modification.

---

## typing.Protocol Note

`ReducerStrategy` uses `typing.Protocol` (Python 3.8+) with `@runtime_checkable`. This means:

- Any class that defines a `resolve(self, events: list[dict]) -> list[dict]` method satisfies the protocol **structurally** — no inheritance or import from `ticket-reducer.py` is required.
- `isinstance(obj, ReducerStrategy)` returns `True` for any object whose class provides the `resolve` method (runtime check via `@runtime_checkable`).
- `w21-05z9` can implement `MostStatusEventsWinsStrategy` in its own module without coupling to `ticket-reducer.py`.

```python
# Downstream consumer (w21-05z9) — no import from ticket-reducer needed:
class MostStatusEventsWinsStrategy:
    def resolve(self, events: list[dict]) -> list[dict]:
        # custom merge logic here
        ...
```

---

## Python Version Compatibility

All type annotations use **Python 3.9+ built-in generics** (`list[dict]`, not `List[Dict]`). The `from __future__ import annotations` import at the top of `ticket-reducer.py` enables these annotations in Python 3.8 as well.

---

## Downstream Story Obligations

| Story    | Obligation |
|----------|------------|
| `w20-c38q` | Add `ReducerStrategy` Protocol and `LastTimestampWinsStrategy` class to `ticket-reducer.py`; update `reduce_ticket()` signature |
| `w20-jdwg` | Write RED tests for `ReducerStrategy` and `LastTimestampWinsStrategy` before T2 implementation |
| `w21-05z9` | Implement `MostStatusEventsWinsStrategy` satisfying `ReducerStrategy`; no import from `ticket-reducer.py` required |
