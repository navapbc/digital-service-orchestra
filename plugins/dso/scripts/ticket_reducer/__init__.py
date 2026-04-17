"""Ticket reducer processor package.

Provides event-type processors, state helpers, sort utilities, and cache
management extracted from ticket-reducer.py.

Public re-exports for use by ticket-reducer.py (the thin dispatcher):
    make_initial_state, make_error_dict  — from _state
    event_sort_key                        — from _sort
    compute_dir_hash, read_cache,
    write_cache                           — from _cache
    process_create, process_status,
    process_comment, process_link,
    process_unlink, process_bridge_alert,
    process_revert, process_edit,
    process_archived, process_snapshot,
    scan_for_latest_snapshot              — from _processors
"""

from ticket_reducer._state import make_error_dict, make_initial_state
from ticket_reducer._sort import event_sort_key
from ticket_reducer._cache import (
    compute_dir_hash,
    prepare_event_files,
    read_cache,
    write_cache,
)
from ticket_reducer._processors import (
    process_archived,
    process_bridge_alert,
    process_comment,
    process_create,
    process_edit,
    process_link,
    process_revert,
    process_snapshot,
    process_status,
    process_unlink,
    replay_events,
    scan_for_latest_snapshot,
)

__all__ = [
    "make_initial_state",
    "make_error_dict",
    "event_sort_key",
    "compute_dir_hash",
    "prepare_event_files",
    "read_cache",
    "write_cache",
    "process_create",
    "process_status",
    "process_comment",
    "process_link",
    "process_unlink",
    "process_bridge_alert",
    "process_revert",
    "process_edit",
    "process_archived",
    "process_snapshot",
    "scan_for_latest_snapshot",
    "replay_events",
]
