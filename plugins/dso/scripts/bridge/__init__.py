"""bridge — inbound event handler modules for bridge-inbound.py.

Each module handles one logical section of per-issue processing
in process_inbound():

    _handle_destructive_guard  check_destructive_guard()
    _handle_status             handle_status()
    _handle_edit               handle_edit()
    _handle_type               handle_type_check()
    _handle_links              handle_links()
"""

from bridge._handle_destructive_guard import check_destructive_guard
from bridge._handle_edit import handle_edit
from bridge._handle_links import handle_links
from bridge._handle_status import handle_status
from bridge._handle_type import handle_type_check

__all__ = [
    "check_destructive_guard",
    "handle_edit",
    "handle_links",
    "handle_status",
    "handle_type_check",
]
