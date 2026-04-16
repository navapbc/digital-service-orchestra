"""Constants for analyze-tool-use anti-pattern detection."""

from __future__ import annotations

from pathlib import Path

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

LOG_DIR = Path.home() / ".claude" / "logs"
DISPATCH_LOG_DIR = LOG_DIR  # dispatch-YYYY-MM-DD.jsonl lives alongside tool-use logs
ERROR_COUNTER_FILE = Path.home() / ".claude" / "tool-error-counter.json"
AGENT_PROFILES_DIR = Path(__file__).parent.parent / "agent-profiles"

# Tools that receive pattern analysis (patterns 1-4, 6)
BUILTIN_TOOLS = {
    "Read",
    "Write",
    "Edit",
    "Bash",
    "Glob",
    "Grep",
    "Task",
    "WebSearch",
    "WebFetch",
}

# File-op Bash commands that should use dedicated tools instead
FILE_OP_PATTERNS: list[tuple[str, str]] = [
    # (pattern_to_detect, recommended_tool)
    ("cat ", "Read tool"),
    ("head ", "Read tool (with limit/offset)"),
    ("tail ", "Read tool (with limit/offset)"),
    ("grep ", "Grep tool"),
    ("find ", "Glob tool"),
    ("sed ", "Edit tool"),
    ("awk ", "Edit/Read tool"),
]

# echo redirect patterns (echo "..." > file  or  echo "..." >> file)
ECHO_REDIRECT_RE_FRAGMENTS = [" > ", " >> "]

# Similarity threshold for same-error retry detection
SIMILARITY_THRESHOLD = 0.80

# Search sprawl window (ms) and minimum count
SEARCH_SPRAWL_WINDOW_MS = 120_000  # 2 minutes
SEARCH_SPRAWL_MIN_COUNT = 5

# Redundant call window (ms)
REDUNDANT_WINDOW_MS = 60_000  # 60 seconds

# Lookback windows for suboptimal ordering
ORDERING_LOOKBACK_WRITE_EDIT = 5  # last N calls before Write/Edit
ORDERING_LOOKBACK_COMMIT = 10  # last N calls before git commit
ORDERING_LOOKBACK_PUSH = 20  # last N calls before git push

# Domain mismatch: tools whose file_path reveals agent working domain
FILE_ACCESS_TOOLS = {"Read", "Write", "Edit"}
# Minimum file accesses in a session before mismatch detection applies
DOMAIN_MIN_FILE_ACCESSES = 3
# Fraction threshold: if top domain < this, session is "mixed"
DOMAIN_DOMINANCE_THRESHOLD = 0.60
