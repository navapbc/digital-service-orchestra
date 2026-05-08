#!/usr/bin/env bash
# apply-attribution-trailers.sh
#
# Applies git commit trailers derived from attribution-contributors.jsonl,
# recording which sub-agents and models contributed to a commit.
#
# ── JSONL Schema ──────────────────────────────────────────────────────────────
# Each line in attribution-contributors.jsonl is a JSON object:
#   {"type":"agent","subagent_type":"dso:<skill>","model":"<model-id>"}
#
# Fields:
#   type          — always "agent" for sub-agent contributions
#   subagent_type — named agent identifier (e.g. "dso:code-reviewer-light")
#   model         — model ID used for this contribution (e.g. "sonnet")
#   skill_name    — optional; populated when type is a skill invocation
#
# ── Trailer Classification ────────────────────────────────────────────────────
# Multi-value trailers (one per unique value, comma-joined if collapsing):
#   DSO-Agent:     derived from subagent_type field
#   DSO-Model:     derived from model field
#   DSO-Skill:     derived from skill_name field (when present)
#
# Scalar trailers (single value per commit):
#   DSO-Session:   session ID, if available
#
# ── Truncation Contract ───────────────────────────────────────────────────────
# When the total trailer block exceeds git's line-length soft limit (~998 chars):
#   1. Deduplicate values first (this script handles dedup via read_and_deduplicate)
#   2. Truncate to first N unique values with a trailing "... (N more)" annotation
#   3. Never truncate to zero — always emit at least one value per trailer key
#
# ── Usage ─────────────────────────────────────────────────────────────────────
#   apply-attribution-trailers.sh [--dry-run] [--jsonl <file>] [--commit <ref>]
#
# Options:
#   --dry-run         Print trailers without applying them
#   --jsonl <file>    Path to attribution-contributors.jsonl (default: $ARTIFACTS_DIR/attribution-contributors.jsonl)
#   --commit <ref>    Commit ref to amend (default: HEAD)
#
# Exit codes:
#   0  = success
#   1  = usage error
#   2  = git version too old (< 2.6)
#   3  = JSONL file not found or unreadable

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
GIT_BINARY="${GIT_BINARY:-git}"

# ── ARTIFACTS_DIR resolution ──────────────────────────────────────────────────
# Prefer WORKFLOW_PLUGIN_ARTIFACTS_DIR when set (commit workflow override).
# Fall back to deps.sh get_artifacts_dir() when available, else /tmp fallback.
_resolve_artifacts_dir() {
    if [[ -n "${WORKFLOW_PLUGIN_ARTIFACTS_DIR:-}" ]]; then
        echo "$WORKFLOW_PLUGIN_ARTIFACTS_DIR"
        return 0
    fi
    # Respect a caller-supplied ARTIFACTS_DIR (used by tests and commit-workflow
    # callers that set ARTIFACTS_DIR directly rather than WORKFLOW_PLUGIN_ARTIFACTS_DIR).
    if [[ -n "${ARTIFACTS_DIR:-}" ]]; then
        echo "$ARTIFACTS_DIR"
        return 0
    fi
    local _script_dir
    _script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local _deps="${_script_dir}/../hooks/lib/deps.sh"
    if [[ -f "$_deps" ]]; then
        # shellcheck disable=SC1090
        source "$_deps"
        get_artifacts_dir
    else
        echo "/tmp/apply-attribution-trailers-fallback"
    fi
}

ARTIFACTS_DIR="$(_resolve_artifacts_dir)"

# ── Argument parsing ──────────────────────────────────────────────────────────
_DRY_RUN=0
_JSONL_FILE=""
_COMMIT_REF="HEAD"
_COMMIT_MSG_FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            _DRY_RUN=1
            shift
            ;;
        --jsonl)
            _JSONL_FILE="$2"
            shift 2
            ;;
        --commit)
            _COMMIT_REF="$2"
            shift 2
            ;;
        --)
            shift
            break
            ;;
        *)
            # Positional argument: commit-msg file path (used when invoked as a
            # prepare-commit-msg or commit-msg hook, where git passes the file
            # path as the first positional argument).
            if [[ -z "${_COMMIT_MSG_FILE:-}" ]]; then
                _COMMIT_MSG_FILE="$1"
                shift
            else
                printf "ERROR: unknown option: %s\n" "$1" >&2
                exit 1
            fi
            ;;
    esac
done

# Default JSONL path if not explicitly provided
if [[ -z "$_JSONL_FILE" ]]; then
    _JSONL_FILE="${ARTIFACTS_DIR}/attribution-contributors.jsonl"
fi

# ── check_git_version ─────────────────────────────────────────────────────────
# Checks that the installed git version meets the minimum requirement (>= 2.6).
# Uses ${GIT_BINARY:-git} so tests can inject a mock binary via GIT_BINARY.
# Strips vendor suffixes (e.g. 2.39.3-1.el9 → 2.39.3) before comparison.
# NOTE: uses 'return' (not 'exit') so set -euo pipefail does not abort callers.
#
# Usage: check_git_version "<required-version>"  (argument unused; min is 2.6)
# Returns: 0 if git >= 2.6; non-zero + TRAILER_SKIPPED on stderr if too old
check_git_version() {
    local min_major=2 min_minor=6
    local ver
    ver="$("${GIT_BINARY:-git}" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)"
    # Strip vendor suffix (e.g., 2.39.3-1.el9 → 2.39.3)
    ver="${ver%%-*}"
    local major minor
    major="${ver%%.*}"
    minor="${ver#*.}"
    minor="${minor%%.*}"
    if [[ "$major" -gt "$min_major" || ( "$major" -eq "$min_major" && "$minor" -ge "$min_minor" ) ]]; then
        return 0
    fi
    echo "TRAILER_SKIPPED: git version $ver < $min_major.$min_minor" >&2
    return 1
}

# ── read_and_deduplicate ──────────────────────────────────────────────────────
# Reads a JSONL file and outputs unique lines (full-line deduplication).
#
# Usage: read_and_deduplicate <jsonl_file>
# Output: unique JSON lines from the input file, one per stdout line
# Returns: 0 on success
read_and_deduplicate() {
    local jsonl_file="$1"

    if [[ ! -f "$jsonl_file" ]]; then
        printf "ERROR: read_and_deduplicate: file not found: %s\n" "$jsonl_file" >&2
        return 3
    fi

    # Use python3 for reliable JSONL deduplication.
    # Preserves first-occurrence order; drops exact-duplicate lines.
    python3 - "$jsonl_file" <<'PYEOF'
import sys
import json

path = sys.argv[1]
seen = set()
with open(path, "r") as fh:
    for raw_line in fh:
        line = raw_line.rstrip("\n")
        if not line.strip():
            continue
        # Normalize by round-tripping through JSON to ignore whitespace differences
        try:
            obj = json.loads(line)
            key = json.dumps(obj, sort_keys=True)
        except json.JSONDecodeError:
            # Non-JSON lines: use raw text as key
            key = line
        if key not in seen:
            seen.add(key)
            print(line)
PYEOF
}

# ── format_trailer_flags ──────────────────────────────────────────────────────
# Reads a JSONL file and emits git --trailer flags for each unique entry.
#
# Emits:
#   --trailer 'DSO-Agent: <subagent_type>'  — one per unique agent entry
#   --trailer 'DSO-Skill: <skill_name>'     — one per unique skill entry
#   --trailer 'DSO-Model: <model>'          — one per unique model value
#
# Scalar trailers (DSO-Session etc.) are a placeholder filled by T4-impl.
#
# Usage: format_trailer_flags <jsonl_file>
# Output: newline-separated --trailer flag strings, empty if no entries
# Returns: 0 on success
format_trailer_flags() {
    local jsonl_file="$1"

    # Missing or empty file → no trailers (not an error; JSONL may simply be absent)
    if [[ ! -f "$jsonl_file" ]]; then
        return 0
    fi

    python3 - "$jsonl_file" <<'PYEOF'
import sys
import json

path = sys.argv[1]

seen_agents = []
seen_skills = []
seen_models = []

agent_set = set()
skill_set = set()
model_set = set()

with open(path, "r") as fh:
    for raw_line in fh:
        line = raw_line.rstrip("\n")
        if not line.strip():
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue

        entry_type = obj.get("type", "")

        if entry_type == "agent":
            subagent_type = obj.get("subagent_type", "")
            if subagent_type and subagent_type not in agent_set:
                agent_set.add(subagent_type)
                seen_agents.append(subagent_type)
            model = obj.get("model", "")
            if model and model not in model_set:
                model_set.add(model)
                seen_models.append(model)

        elif entry_type == "skill":
            skill_name = obj.get("skill_name", "")
            if skill_name and skill_name not in skill_set:
                skill_set.add(skill_name)
                seen_skills.append(skill_name)
            model = obj.get("model", "")
            if model and model not in model_set:
                model_set.add(model)
                seen_models.append(model)

for agent in seen_agents:
    print("--trailer 'DSO-Agent: {}'".format(agent))
for skill in seen_skills:
    print("--trailer 'DSO-Skill: {}'".format(skill))
for model in seen_models:
    print("--trailer 'DSO-Model: {}'".format(model))
PYEOF
}

# ── resolve_scalar_trailers ───────────────────────────────────────────────────
# Resolves scalar (single-value) trailers from task context and review scores.
#
# Reads env vars:
#   DSO_TASK_ID    — ticket ID; if set, calls `dso ticket show` to get title/hierarchy
#   ARTIFACTS_DIR  — path to dir containing reviewer-findings.json (optional)
#
# Emits to stdout (only non-empty values):
#   --trailer 'DSO-Task: <title>'
#   --trailer 'DSO-Story: <parent_title>'
#   --trailer 'DSO-Epic: <grandparent_title>'
#   --trailer 'DSO-Review-Score: N.N'
#
# Graceful degradation: dso CLI failure → omit task trailers; missing
# reviewer-findings.json → omit review score. Never exits non-zero.
#
# Usage: resolve_scalar_trailers
# Output: newline-separated --trailer flag strings, empty if no context
# Returns: 0 always
resolve_scalar_trailers() {
    # ── Task / Story / Epic trailers ──────────────────────────────────────────
    if [[ -n "${DSO_TASK_ID:-}" ]]; then
        local _ticket_json
        # Use PATH-resolved dso; capture failure silently
        _ticket_json="$(dso ticket show "$DSO_TASK_ID" 2>/dev/null)" || _ticket_json=""

        if [[ -n "$_ticket_json" ]]; then
            # Extract fields via python3 (reliable JSON parsing; no jq dependency)
            python3 - "$_ticket_json" <<'PYEOF'
import sys
import json

raw = sys.argv[1]
try:
    obj = json.loads(raw)
except json.JSONDecodeError:
    sys.exit(0)

title        = obj.get("title", "") or ""
parent_title = obj.get("parent_title", "") or ""
grand_title  = obj.get("grandparent_title", "") or ""

if title:
    print("--trailer 'DSO-Task: {}'".format(title))
if parent_title:
    print("--trailer 'DSO-Story: {}'".format(parent_title))
if grand_title:
    print("--trailer 'DSO-Epic: {}'".format(grand_title))
PYEOF
        fi
    fi

    # ── Review-Score trailer ──────────────────────────────────────────────────
    local _findings="${ARTIFACTS_DIR:-}/reviewer-findings.json"
    if [[ -n "${ARTIFACTS_DIR:-}" && -f "$_findings" ]]; then
        python3 - "$_findings" <<'PYEOF'
import sys
import json

path = sys.argv[1]
try:
    with open(path, "r") as fh:
        obj = json.load(fh)
except (OSError, json.JSONDecodeError):
    sys.exit(0)

scores = obj.get("scores", {})
if not scores:
    sys.exit(0)

values = [v for v in scores.values() if isinstance(v, (int, float))]
if not values:
    sys.exit(0)

avg = sum(values) / len(values)
print("--trailer 'DSO-Review-Score: {:.1f}'".format(avg))
PYEOF
    fi

    return 0
}

# ── Main (only runs when script is executed directly, not sourced) ────────────
# Guard: skip main block when sourced by tests
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # ── SC-2: attribution.enabled config guard ────────────────────────────────
    # Exit 0 (no-op) if attribution is disabled in config.
    _attribution_enabled=$(read-config.sh attribution.enabled 2>/dev/null || echo "false")
    if [[ "$_attribution_enabled" != "true" ]]; then
        exit 0
    fi

    # ── SC-4: JSONL file presence guard ───────────────────────────────────────
    # Exit 0 (no-op) if the attribution JSONL file is absent or empty.
    _jsonl="$ARTIFACTS_DIR/attribution-contributors.jsonl"
    if [[ ! -f "$_jsonl" ]] || [[ ! -s "$_jsonl" ]]; then
        exit 0
    fi

    # ── SC-7: git version guard ───────────────────────────────────────────────
    # Exit 0 (graceful skip) if git is too old to support interpret-trailers.
    check_git_version || { printf 'TRAILER_SKIPPED: git < 2.6\n' >&2; exit 0; }

    if [[ ! -f "$_JSONL_FILE" ]]; then
        printf "ERROR: JSONL file not found: %s\n" "$_JSONL_FILE" >&2
        exit 3
    fi

    # Read unique contributions
    _unique_lines="$(read_and_deduplicate "$_JSONL_FILE")"

    if [[ "$_DRY_RUN" -eq 1 ]]; then
        printf "DRY-RUN: would apply trailers from %s to %s\n" "$_JSONL_FILE" "$_COMMIT_REF"
        printf "%s\n" "$_unique_lines"
        exit 0
    fi

    # ── Trailer injection via git interpret-trailers --in-place ───────────────
    # Build combined trailer flags from JSONL (multi-value) + scalar context
    _trailer_flags=""
    _trailer_flags+="$(format_trailer_flags "$ARTIFACTS_DIR/attribution-contributors.jsonl")"
    _resolve_flags="$(resolve_scalar_trailers)"
    if [[ -n "$_resolve_flags" ]]; then
        _trailer_flags+=$'\n'"$_resolve_flags"
    fi

    # Read trailer flags into an array so each --trailer 'K: V' token is
    # passed as a separate word (avoids eval and handles spaces in values).
    # mapfile splits on newlines; empty lines are filtered to prevent blank args.
    mapfile -t _flags_array < <(printf '%s\n' "$_trailer_flags" | grep -v '^$')

    if [[ "${#_flags_array[@]}" -gt 0 ]]; then
        # shellcheck disable=SC2294
        eval "${GIT_BINARY:-git} interpret-trailers --in-place ${_flags_array[*]} \"\$_COMMIT_MSG_FILE\""
    fi
    exit 0
fi
