#!/usr/bin/env bash
# apply-attribution-trailers.sh
#
# Applies git commit trailers derived from attribution-contributors.jsonl,
# recording which sub-agents and models contributed to a commit.
#
# ---------------------------------------------------------------------------
# Attribution JSONL Schema
# File: $ARTIFACTS_DIR/attribution-contributors.jsonl
#
# Each line is a JSON object describing one contributor:
#   Agent:  {"type":"agent","subagent_type":"dso:sprint","model":"claude-sonnet-4-6"}
#   Skill:  {"type":"skill","skill_name":"sprint"}
#
# Multi-value trailers (one per unique entry):
#   DSO-Agent:  <subagent_type> — one trailer per unique agent entry
#   DSO-Skill:  <skill_name>   — one trailer per unique skill entry
#   DSO-Model:  <model>        — one trailer per unique model value
#
# Scalar trailers (from DSO_TASK_ID ticket context + reviewer-findings.json):
#   DSO-Task:           <task title>
#   DSO-Story:          <parent story title>
#   DSO-Epic:           <grandparent epic title>
#   Jira-Ticket:        <jira ticket key if bridged>
#   DSO-Review-Score:   <average score, 1 decimal>
#
# Truncation contract: attribution-contributors.jsonl is cleared to 0 bytes
# after each successful git commit via the --truncate flag.
# ---------------------------------------------------------------------------
#
# ── Usage ─────────────────────────────────────────────────────────────────────
#   apply-attribution-trailers.sh [--dry-run] [--jsonl <file>] [--truncate] <commit-msg-file>
#
# Operates on a commit message file via `git interpret-trailers --in-place`.
# Typically invoked as the orchestrator's pre-commit step (with the commit
# message file path) or as a post-commit truncate step (with `--truncate`).
#
# Options:
#   --dry-run         Print trailers without applying them
#   --jsonl <file>    Path to attribution-contributors.jsonl
#                     (default: $ARTIFACTS_DIR/attribution-contributors.jsonl)
#   --truncate        Clear the JSONL file to 0 bytes (post-commit cleanup)
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
    local _script_dir _plugin_root
    _script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    _plugin_root="${CLAUDE_PLUGIN_ROOT:-${_script_dir}/..}"
    local _deps="${_plugin_root}/hooks/lib/deps.sh"
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
_COMMIT_MSG_FILE=""
_TRUNCATE_MODE=0

_usage_error() {
    printf "ERROR: %s\n" "$1" >&2
    printf "Usage: apply-attribution-trailers.sh [--dry-run] [--jsonl <file>] [--truncate] <commit-msg-file>\n" >&2
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --truncate)
            _TRUNCATE_MODE=1
            shift
            ;;
        --dry-run)
            _DRY_RUN=1
            shift
            ;;
        --jsonl)
            [[ $# -ge 2 ]] || _usage_error "--jsonl requires a <file> argument"
            _JSONL_FILE="$2"
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
                _usage_error "unknown option or extra positional: $1"
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

# ── _resolve_read_config_script ───────────────────────────────────────────────
# Resolves the absolute path to read-config.sh. Tries, in order:
#   1. ${SCRIPTS_DIR}/read-config.sh (set by some hook dispatchers)
#   2. read-config.sh on $PATH (test harnesses often prepend a mock dir)
#   3. ${CLAUDE_PLUGIN_ROOT}/scripts/read-config.sh (real plugin runtime)
# Echoes the resolved path or empty string. Never fails.
_resolve_read_config_script() {
    if [[ -n "${SCRIPTS_DIR:-}" && -f "${SCRIPTS_DIR}/read-config.sh" ]]; then
        echo "${SCRIPTS_DIR}/read-config.sh"
        return 0
    fi
    local _on_path
    _on_path="$(command -v read-config.sh 2>/dev/null || true)"
    if [[ -n "$_on_path" ]]; then
        echo "$_on_path"
        return 0
    fi
    if [[ -n "${CLAUDE_PLUGIN_ROOT:-}" && -f "${CLAUDE_PLUGIN_ROOT}/scripts/read-config.sh" ]]; then
        echo "${CLAUDE_PLUGIN_ROOT}/scripts/read-config.sh"
        return 0
    fi
    echo ""
}

# ── _build_trailer_argv ───────────────────────────────────────────────────────
# Builds an argv array of `--trailer KEY: VALUE` token pairs from the script's
# JSONL + scalar-context inputs. Caller must declare `_argv` as a local array.
# Uses python3 to emit NUL-delimited tokens so values with spaces, single
# quotes, or shell metacharacters are passed safely.
_build_trailer_argv() {
    local _jsonl_file="$1"
    local _scalar_flags="$2"  # newline-separated --trailer 'K: V' lines

    # Multi-value trailers from JSONL (NUL-delimited K: V tokens).
    if [[ -f "$_jsonl_file" ]]; then
        while IFS= read -r -d '' _token; do
            _argv+=("--trailer" "$_token")
        done < <(python3 - "$_jsonl_file" <<'PYEOF'
import sys, json
path = sys.argv[1]
seen_a, seen_s, seen_m = [], [], []
sa, ss, sm = set(), set(), set()
with open(path) as fh:
    for raw in fh:
        line = raw.rstrip("\n")
        if not line.strip():
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        t = obj.get("type", "")
        if t == "agent":
            v = obj.get("subagent_type", "")
            if v and v not in sa:
                sa.add(v); seen_a.append(v)
            m = obj.get("model", "")
            if m and m not in sm:
                sm.add(m); seen_m.append(m)
        elif t == "skill":
            v = obj.get("skill_name", "")
            if v and v not in ss:
                ss.add(v); seen_s.append(v)
            m = obj.get("model", "")
            if m and m not in sm:
                sm.add(m); seen_m.append(m)
out = []
for v in seen_a: out.append("DSO-Agent: " + v)
for v in seen_s: out.append("DSO-Skill: " + v)
for v in seen_m: out.append("DSO-Model: " + v)
sys.stdout.write("\0".join(out))
if out:
    sys.stdout.write("\0")
PYEOF
)
    fi

    # Scalar trailers come pre-formatted as "--trailer 'K: V'" lines from
    # resolve_scalar_trailers — strip the wrapper to recover the K: V token.
    if [[ -n "$_scalar_flags" ]]; then
        local _line _tok
        while IFS= read -r _line; do
            [[ -z "$_line" ]] && continue
            _tok="${_line#--trailer }"
            _tok="${_tok#\'}"
            _tok="${_tok%\'}"
            _argv+=("--trailer" "$_tok")
        done <<< "$_scalar_flags"
    fi
}

# ── Main (only runs when script is executed directly, not sourced) ────────────
# Guard: skip main block when sourced by tests
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # ── SC-6: --truncate mode ─────────────────────────────────────────────────
    # Clear the JSONL file after successful injection so that the next commit
    # starts with a clean slate.  Never fails /dso:commit (always exits 0).
    if [[ "$_TRUNCATE_MODE" -eq 1 ]]; then
        if [[ -f "$_JSONL_FILE" ]]; then
            if ! : > "$_JSONL_FILE" 2>/dev/null; then
                printf 'WARNING: apply-attribution-trailers: failed to truncate %s\n' "$_JSONL_FILE" >&2
            fi
        fi
        exit 0
    fi

    # ── SC-2: attribution.enabled config guard ────────────────────────────────
    # Exit 0 (no-op) if attribution is disabled in config.
    _read_config_path="$(_resolve_read_config_script)"
    if [[ -n "$_read_config_path" ]]; then
        _attribution_enabled=$(bash "$_read_config_path" attribution.enabled 2>/dev/null || echo "false")
    else
        _attribution_enabled="false"
    fi
    if [[ "$_attribution_enabled" != "true" ]]; then
        exit 0
    fi

    # ── SC-4: JSONL file presence guard ───────────────────────────────────────
    # Exit 0 (no-op) if the attribution JSONL file is absent or empty.
    if [[ ! -f "$_JSONL_FILE" ]] || [[ ! -s "$_JSONL_FILE" ]]; then
        exit 0
    fi

    # ── SC-7: git version guard ───────────────────────────────────────────────
    # Exit 0 (graceful skip) if git is too old to support interpret-trailers.
    check_git_version || { printf 'TRAILER_SKIPPED: git < 2.6\n' >&2; exit 0; }

    # Read unique contributions
    _unique_lines="$(read_and_deduplicate "$_JSONL_FILE")"

    if [[ "$_DRY_RUN" -eq 1 ]]; then
        printf "DRY-RUN: would apply trailers from %s to %s\n" "$_JSONL_FILE" "${_COMMIT_MSG_FILE:-<stdout>}"
        printf "%s\n" "$_unique_lines"
        exit 0
    fi

    # ── Commit-message-file presence check (L5) ───────────────────────────────
    if [[ -z "$_COMMIT_MSG_FILE" ]]; then
        _usage_error "missing <commit-msg-file> argument; required when not in --dry-run or --truncate mode"
    fi
    if [[ ! -f "$_COMMIT_MSG_FILE" ]]; then
        printf "ERROR: commit message file not found: %s\n" "$_COMMIT_MSG_FILE" >&2
        exit 1
    fi

    # ── Trailer injection via git interpret-trailers --in-place ───────────────
    # Build argv array safely (no eval) so trailer values with shell
    # metacharacters cannot trigger command substitution / injection.
    _argv=()
    _scalar_flags="$(resolve_scalar_trailers)"
    _build_trailer_argv "$_JSONL_FILE" "$_scalar_flags"

    if [[ "${#_argv[@]}" -gt 0 ]]; then
        # ── Idempotency guard ─────────────────────────────────────────────────
        # Skip injection if every would-be trailer (KEY: VALUE) already appears
        # in the commit message file. Match case-insensitively because git
        # interpret-trailers itself treats trailer keys case-insensitively, so a
        # pre-existing "dso-agent: foo" line is semantically the same trailer.
        _all_present=1
        local_i=0
        while [[ $local_i -lt ${#_argv[@]} ]]; do
            # _argv pairs are (--trailer, "KEY: VALUE", --trailer, "KEY: VALUE", ...)
            _trailer_token="${_argv[$((local_i + 1))]}"
            if ! grep -qiF "$_trailer_token" "$_COMMIT_MSG_FILE" 2>/dev/null; then
                _all_present=0
                break
            fi
            local_i=$((local_i + 2))
        done

        if [[ "$_all_present" -eq 1 ]]; then
            exit 0
        fi

        "${GIT_BINARY:-git}" interpret-trailers --in-place "${_argv[@]}" -- "$_COMMIT_MSG_FILE"
    fi

    # ── SC-5: Post-injection placement scan ───────────────────────────────────
    # Detect DSO-* or Jira-Ticket: lines that appear before the final blank-line
    # separator (i.e., in the message body rather than the trailer section).
    # Non-blocking: emits a warning to stderr and continues (exit 0).
    _last_blank_line=0
    _line_no=0
    while IFS= read -r _line; do
        (( ++_line_no ))
        [[ -z "$_line" ]] && _last_blank_line=$_line_no
    done < "$_COMMIT_MSG_FILE"

    _misplaced=0
    _line_no=0
    while IFS= read -r _line; do
        (( ++_line_no ))
        if [[ $_line_no -lt $_last_blank_line ]]; then
            if [[ "$_line" =~ ^(Jira-Ticket|DSO-[A-Za-z-]+): ]]; then
                _misplaced=1
                break
            fi
        fi
    done < "$_COMMIT_MSG_FILE"

    if [[ $_misplaced -eq 1 ]]; then
        printf 'WARNING: apply-attribution-trailers: DSO-* trailer found in message body (before blank separator)\n' >&2
    fi

    exit 0
fi
