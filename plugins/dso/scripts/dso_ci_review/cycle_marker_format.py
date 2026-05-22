"""Single source of truth for DSO-Review-Cycle and DSO-Arbiter-Ruling marker grammar.

Contract: ${CLAUDE_PLUGIN_ROOT}/docs/contracts/cycle-ledger.md
Bug:      9788-09e1-68f7-4cbe (cycle marker writer/parser format mismatch)

Background
----------
Before this module, the writer (runner.py) emitted `DSO-Review-Cycle: cycle=K ...`
while the parsers (cycle_ledger.py, write-cycle-ledger.sh) expected a bare integer
after the colon. The writer test pinned the broken `cycle=K` format, so the writer
test passed while every real cycle marker silently failed to round-trip. Ledger
reconstruction returned empty -> cycle_num pinned at 1 -> STABLE_HALT and
`cycle_num >= max_cycles` both unreachable -> DISPATCH_ARBITER was unreachable from
any live PR.

This module centralizes the grammar so writer, parser, and dedup logic all share
one source of truth. All callers (runner.py writer + dedup, cycle_ledger.py
parsers, write-cycle-ledger.sh after rewire-to-Python) MUST use these functions.

Format precedence (read path)
-----------------------------
v1.2.0 -> v1.1.0 -> v1.0.0 legacy. Writer emits v1.2.0 only.

v1.2.0 cycle marker grammar
---------------------------
    DSO-Review-Cycle: <cycle_num> pr_number=<N> commit_sha=<sha> findings_hash=<hash> tuples=<json>

Optional continuation field for chunked emission (parser support only in this
version; writer wire-up deferred to a follow-up bug):

    DSO-Review-Cycle: <cycle_num> pr_number=<N> commit_sha=<sha> findings_hash=<hash> continuation=<i>/<M> tuples=<json>

v1.2.0 arbiter ruling marker grammar
------------------------------------
    DSO-Arbiter-Ruling: <cycle_num> commit_sha=<sha>

(pr_number is NOT included in the arbiter marker today; the dedup is on
(cycle_num, commit_sha) only and the arbiter never executes a rebroadcast.)
"""

from __future__ import annotations

import json
import re
from typing import NamedTuple, Sequence

CYCLE_MARKER_PREFIX = "DSO-Review-Cycle:"
ARBITER_MARKER_PREFIX = "DSO-Arbiter-Ruling:"

# Per cycle-ledger.md:121 — beyond MAX_TUPLES_PER_MARKER tuples the producer MUST
# emit continuation markers. Writer wire-up is a follow-up; parser support is here.
MAX_TUPLES_PER_MARKER = 50

# Sentinel used by v1.1.0 reads (markers lacking pr_number). NEVER write this.
SENTINEL_PR_NUMBER = 0


# ---------------------------------------------------------------------------
# Compiled regexes (single source of truth — re-exported to cycle_ledger.py)
# ---------------------------------------------------------------------------

# v1.2.0 with optional continuation=i/M segment
_CYCLE_RE_V12 = re.compile(
    r"^" + re.escape(CYCLE_MARKER_PREFIX) + r"\s+(\d+)"
    r"\s+pr_number=(\d+)"
    r"\s+commit_sha=(\S+)"
    r"\s+findings_hash=(\S+)"
    r"(?:\s+continuation=(\d+)/(\d+))?"
    r"\s+tuples=(\[.*\])\s*$"
)

# v1.1.0 (no pr_number)
_CYCLE_RE_V11 = re.compile(
    r"^" + re.escape(CYCLE_MARKER_PREFIX) + r"\s+(\d+)"
    r"\s+commit_sha=(\S+)"
    r"\s+findings_hash=(\S+)"
    r"\s+tuples=(\[.*\])\s*$"
)

# v1.0.0 legacy (optional findings-hash with hyphen, no tuples)
_CYCLE_RE_LEGACY = re.compile(
    r"^" + re.escape(CYCLE_MARKER_PREFIX) + r"\s+(\d+)(?:\s+findings-hash=(\S+))?\s*$"
)

# Arbiter marker — bare integer for cycle_num (post-rewire)
_ARBITER_RE = re.compile(
    r"^" + re.escape(ARBITER_MARKER_PREFIX) + r"\s+(\d+)\s+commit_sha=(\S+)\s*$"
)


# ---------------------------------------------------------------------------
# Public dataclasses
# ---------------------------------------------------------------------------


class ParsedCycleMarker(NamedTuple):
    cycle_num: int
    pr_number: int  # SENTINEL_PR_NUMBER (0) when parsed from v1.1.0 or legacy
    commit_sha: str
    findings_hash: str
    tuples: list
    schema_version: str  # "1.2.0" | "1.1.0" | "1.0.0"
    continuation_index: int | None = None  # 1-based per cycle-ledger.md:121
    continuation_total: int | None = None


class ParsedArbiterMarker(NamedTuple):
    cycle_num: int
    commit_sha: str


# ---------------------------------------------------------------------------
# Format (write) functions
# ---------------------------------------------------------------------------


def format_cycle_marker(
    *,
    cycle_num: int,
    pr_number: int,
    commit_sha: str,
    findings_hash: str,
    tuples: list,
    continuation_index: int | None = None,
    continuation_total: int | None = None,
) -> str:
    """Emit a v1.2.0-compliant DSO-Review-Cycle marker body.

    pr_number MUST be > 0 (SENTINEL_PR_NUMBER is reserved for v1.1.0 reads).
    cycle_num MUST be >= 1.

    Pre-condition: callers must guard against pr_number <= 0 BEFORE calling
    (see runner.py:_post_cycle_marker_comment). This function raises rather
    than silently writing a non-compliant marker.

    Continuation fields (when set) MUST both be present and satisfy
    1 <= continuation_index <= continuation_total.

    Format guarantee for dedup_key compatibility: the emitted body contains
    `" {cycle_num} "` and `"commit_sha={commit_sha}"` as exact substrings.
    """
    if pr_number is None or pr_number <= 0:
        raise ValueError(
            f"pr_number must be > 0 (got {pr_number!r}); "
            "SENTINEL_PR_NUMBER (0) is reserved for v1.1.0 reads "
            "(see cycle-ledger.md:67 — writers MUST emit pr_number > 0)"
        )
    if cycle_num < 1:
        raise ValueError(f"cycle_num must be >= 1 (got {cycle_num!r})")
    if not commit_sha or not isinstance(commit_sha, str):
        raise ValueError(f"commit_sha must be a non-empty string (got {commit_sha!r})")
    if not findings_hash or not isinstance(findings_hash, str):
        raise ValueError(
            f"findings_hash must be a non-empty string (got {findings_hash!r})"
        )

    if (continuation_index is None) != (continuation_total is None):
        raise ValueError(
            "continuation_index and continuation_total must both be set or both None"
        )
    if continuation_index is not None:
        if continuation_index < 1 or continuation_total < 1:
            raise ValueError(
                "continuation_index and continuation_total must be >= 1 "
                f"(got {continuation_index}/{continuation_total})"
            )
        if continuation_index > continuation_total:
            raise ValueError(
                "continuation_index must be <= continuation_total "
                f"(got {continuation_index}/{continuation_total})"
            )

    parts = [
        CYCLE_MARKER_PREFIX,
        f" {cycle_num}",
        f" pr_number={pr_number}",
        f" commit_sha={commit_sha}",
        f" findings_hash={findings_hash}",
    ]
    if continuation_index is not None:
        parts.append(f" continuation={continuation_index}/{continuation_total}")
    parts.append(f" tuples={json.dumps(tuples)}")
    return "".join(parts)


def format_arbiter_marker(*, cycle_num: int, commit_sha: str) -> str:
    """Emit a DSO-Arbiter-Ruling marker body (bare integer cycle_num).

    The arbiter marker is used as a substring-dedup key in the existing emit
    path; this function ensures all three call sites (runner.py:_post_arbiter_comment
    and the inline emit at runner.py:2411) generate the same canonical form.
    """
    if cycle_num < 1:
        raise ValueError(f"cycle_num must be >= 1 (got {cycle_num!r})")
    return f"{ARBITER_MARKER_PREFIX} {cycle_num} commit_sha={commit_sha}"


# ---------------------------------------------------------------------------
# Parse (read) functions
# ---------------------------------------------------------------------------


def parse_cycle_marker(line: str) -> ParsedCycleMarker | None:
    """Parse a single line as a cycle marker; return None if no match.

    Tries v1.2.0 first, then v1.1.0, then legacy v1.0.0.

    The v1.1.0 branch returns pr_number=SENTINEL_PR_NUMBER (0) so the caller
    can apply the supersession rule per cycle-ledger.md:80 (a v1.2.0 marker
    for the same (cycle_num, commit_sha) replaces a v1.1.0 entry).
    """
    if not line:
        return None

    m = _CYCLE_RE_V12.match(line)
    if m:
        cycle_num = int(m.group(1))
        pr_number = int(m.group(2))
        commit_sha = m.group(3)
        findings_hash = m.group(4)
        cont_idx = int(m.group(5)) if m.group(5) else None
        cont_total = int(m.group(6)) if m.group(6) else None
        try:
            tuples = json.loads(m.group(7))
        except (ValueError, json.JSONDecodeError):
            return None
        return ParsedCycleMarker(
            cycle_num=cycle_num,
            pr_number=pr_number,
            commit_sha=commit_sha,
            findings_hash=findings_hash,
            tuples=tuples,
            schema_version="1.2.0",
            continuation_index=cont_idx,
            continuation_total=cont_total,
        )

    m = _CYCLE_RE_V11.match(line)
    if m:
        cycle_num = int(m.group(1))
        commit_sha = m.group(2)
        findings_hash = m.group(3)
        try:
            tuples = json.loads(m.group(4))
        except (ValueError, json.JSONDecodeError):
            return None
        return ParsedCycleMarker(
            cycle_num=cycle_num,
            pr_number=SENTINEL_PR_NUMBER,
            commit_sha=commit_sha,
            findings_hash=findings_hash,
            tuples=tuples,
            schema_version="1.1.0",
        )

    m = _CYCLE_RE_LEGACY.match(line)
    if m:
        return ParsedCycleMarker(
            cycle_num=int(m.group(1)),
            pr_number=SENTINEL_PR_NUMBER,
            commit_sha="",
            findings_hash=m.group(2) or "",
            tuples=[],
            schema_version="1.0.0",
        )

    return None


def parse_arbiter_marker(line: str) -> ParsedArbiterMarker | None:
    """Parse a single line as an arbiter marker; return None if no match."""
    if not line:
        return None
    m = _ARBITER_RE.match(line)
    if m:
        return ParsedArbiterMarker(cycle_num=int(m.group(1)), commit_sha=m.group(2))
    return None


# ---------------------------------------------------------------------------
# Dedup helper
# ---------------------------------------------------------------------------


def cycle_dedup_key(cycle_num: int, commit_sha: str) -> tuple[str, str]:
    """Return two substrings that MUST both appear in any well-formed
    v1.2.0 (or v1.1.0) cycle marker for this (cycle_num, commit_sha).

    Used by writer-side dedup to find an existing comment for the same
    (cycle_num, commit_sha) pair across cycle reruns.

    Format invariant: `format_cycle_marker` MUST emit `" {cycle_num} "`
    (cycle_num surrounded by spaces) and `"commit_sha={commit_sha}"`
    (unquoted decimal sha) — these substrings appear verbatim in the body.
    Changing format_cycle_marker's output requires updating this function.
    """
    return (f" {cycle_num} ", f"commit_sha={commit_sha}")


def arbiter_dedup_key(cycle_num: int, commit_sha: str) -> str:
    """Return a single substring uniquely identifying an arbiter marker for
    this (cycle_num, commit_sha)."""
    return format_arbiter_marker(cycle_num=cycle_num, commit_sha=commit_sha)


# ---------------------------------------------------------------------------
# Chunking helper (used by Bug D writer wire-up; parser already supports
# continuation= field)
# ---------------------------------------------------------------------------


def chunk_tuples(
    tuples: Sequence, max_per_chunk: int = MAX_TUPLES_PER_MARKER
) -> list[list]:
    """Split a flat tuple list into chunks of at most max_per_chunk items.

    Returns a single chunk if len(tuples) <= max_per_chunk. The writer for
    Bug D will iterate over the chunks and emit one continuation marker per
    chunk (continuation_index=i, continuation_total=len(chunks)).
    """
    if max_per_chunk < 1:
        raise ValueError(f"max_per_chunk must be >= 1 (got {max_per_chunk})")
    tuples_list = list(tuples)
    if not tuples_list:
        return [[]]
    return [
        tuples_list[i : i + max_per_chunk]
        for i in range(0, len(tuples_list), max_per_chunk)
    ]
