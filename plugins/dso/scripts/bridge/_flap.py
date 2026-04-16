"""Status flap detection for bridge-outbound."""

from __future__ import annotations

from pathlib import Path

from bridge._outbound_api import read_event_file


def detect_status_flap(
    ticket_dir: Path,
    *,
    flap_threshold: int = 3,
    window_seconds: int = 3600,
) -> bool:
    """Detect if a ticket is oscillating between statuses.

    Globs STATUS event files in ticket_dir, filters to those within
    window_seconds of now, extracts status values, and counts direction
    reversals (returning to a previously-seen status). Returns True if the
    reversal count >= flap_threshold.
    """
    all_status_events: list[tuple[int, str]] = []
    for path in ticket_dir.glob("*-STATUS.json"):
        data = read_event_file(path)
        if data is None:
            continue
        ts = data.get("timestamp", 0)
        if not isinstance(ts, (int, float)):
            continue
        status = data.get("data", {}).get("status") or data.get("status")
        if status:
            all_status_events.append((int(ts), status))

    if not all_status_events:
        return False

    # Normalize all timestamps to nanoseconds before comparison so that
    # mixed-precision events (seconds ~1.7e9 from old code, nanoseconds ~1.78e18
    # from new code) can be compared correctly during the migration window.
    # A threshold of 1e12 safely distinguishes nanoseconds from seconds because
    # the Unix epoch in seconds is ~1.7e9 (well below 1e12) while in nanoseconds
    # it is ~1.78e18 (well above 1e12).
    _NS_THRESHOLD = 1_000_000_000_000  # 1e12: values above this are nanoseconds
    _NS_PER_SEC = 1_000_000_000

    def _to_ns(ts: int) -> int:
        """Normalize a timestamp to nanoseconds regardless of original precision."""
        return ts if ts > _NS_THRESHOLD else ts * _NS_PER_SEC

    all_status_events_ns = [(_to_ns(ts), s) for ts, s in all_status_events]
    max_ts_ns = max(ts for ts, _ in all_status_events_ns)
    window_ns = window_seconds * _NS_PER_SEC
    cutoff = max_ts_ns - window_ns
    status_events = [(ts, s) for ts, s in all_status_events_ns if ts >= cutoff]

    status_events.sort(key=lambda x: x[0])

    if len(status_events) < 2:
        return False

    # Count reversals: only increment when the status returns to a
    # previously-seen value (actual oscillation), not on sequential
    # progression through distinct statuses (e.g. A->B->C).
    flap_count = 0
    seen_statuses: set[str] = set()
    prev_status: str | None = None
    for _, status in status_events:
        if prev_status is not None and status != prev_status:
            if status in seen_statuses:
                flap_count += 1
        seen_statuses.add(status)
        prev_status = status

    return flap_count >= flap_threshold
