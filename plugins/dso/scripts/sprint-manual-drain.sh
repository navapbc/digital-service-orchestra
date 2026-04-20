#!/usr/bin/env bash
# sprint-manual-drain.sh — Manual-pause handshake for sprint.
#
# Presents blocking prompts for each manual:awaiting_user story after the
# autonomous drain batch. Records sentinel / audit-token / verification-result
# comments via the ticket CLI.
#
# Usage:
#   sprint-manual-drain.sh <stories.json>
#
# Arguments:
#   $1  Path to JSON file: [{"id":..., "title":..., "instructions":...,
#       "verification_command":... or null, "deps":[...]}, ...]
#
# Environment:
#   DSO_MANUAL_INPUT       Newline-separated input (mock seam; overrides stdin).
#   TICKET_STORE           Ticket-store path (tests use this as cwd anchor).
#   MANUAL_CMD_TIMEOUT     Verification command timeout in seconds (default 30,
#                          or planning.verification_command_timeout_seconds from config).
#   MANUAL_CMD_MAX_LEN     Max verification_command length (default 500).
#   MOCK_DSO_FAIL          (tests) When 1, dso mock fails on comment writes.
#
# Exit codes:
#   0  All stories handled (continue sprint)
#   1  One or more stories skipped (skip propagation applied)
#   2  Re-prompt required (verification failed, timeout, dangerous pattern, oversize)

set -uo pipefail

_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# ── Arguments ────────────────────────────────────────────────────────────────
STORIES_FILE="${1:-}"
if [[ -z "$STORIES_FILE" || ! -f "$STORIES_FILE" ]]; then
    echo "ERROR: stories JSON file required as argument 1" >&2
    exit 2
fi

# ── Config: timeout ──────────────────────────────────────────────────────────
_default_timeout=30
if [[ -f .claude/dso-config.conf ]]; then
    _cfg_timeout=$(grep '^planning.verification_command_timeout_seconds=' .claude/dso-config.conf 2>/dev/null | head -1 | cut -d= -f2)
    if [[ -n "${_cfg_timeout:-}" ]]; then
        _default_timeout="$_cfg_timeout"
    fi
fi
TIMEOUT="${MANUAL_CMD_TIMEOUT:-$_default_timeout}"
MAX_LEN="${MANUAL_CMD_MAX_LEN:-500}"

# ── Ticket CLI resolution ────────────────────────────────────────────────────
# Prefer `dso` on PATH (allows tests to inject mock via PATH prepend).
# Fall back to .claude/scripts/dso host-project shim when dso is not on PATH.
_ticket_cli() {
    if command -v dso >/dev/null 2>&1; then
        dso "$@"
    elif [[ -x .claude/scripts/dso ]]; then
        .claude/scripts/dso "$@"
    else
        echo "ERROR: no dso CLI found (dso on PATH or .claude/scripts/dso)" >&2
        return 127
    fi
}

# ── Load stories via python (robust JSON parse) ──────────────────────────────
_parse_stories() {
    python3 - "$STORIES_FILE" <<'PY'
import json, sys
with open(sys.argv[1]) as fh:
    data = json.load(fh)
for s in data:
    # Emit TSV: id \t title \t instructions \t verification_command \t deps_csv
    vc = s.get("verification_command")
    vc_s = "__NONE__" if vc is None else vc
    deps = ",".join(s.get("deps", []) or [])
    # Replace tabs/newlines in free-text fields to keep 1-line-per-story
    title = (s.get("title") or "").replace("\t", " ").replace("\n", " ")
    inst  = (s.get("instructions") or "").replace("\t", " ").replace("\n", " ")
    vc_s  = vc_s.replace("\t", " ").replace("\n", " ")
    print(f"{s['id']}\t{title}\t{inst}\t{vc_s}\t{deps}")
PY
}

mapfile -t _STORY_LINES < <(_parse_stories)
if [[ ${#_STORY_LINES[@]} -eq 0 ]]; then
    # Nothing to do
    exit 0
fi

# Parse into parallel arrays
declare -a STORY_IDS STORY_TITLES STORY_INSTR STORY_VC STORY_DEPS
for line in "${_STORY_LINES[@]}"; do
    IFS=$'\t' read -r _id _title _inst _vc _deps <<<"$line"
    STORY_IDS+=("$_id")
    STORY_TITLES+=("$_title")
    STORY_INSTR+=("$_inst")
    STORY_VC+=("$_vc")
    STORY_DEPS+=("$_deps")
done

# ── Cycle detection: mutual dep ──────────────────────────────────────────────
# Build dep map (id -> list of deps-ids that are also in the input set)
_n=${#STORY_IDS[@]}
for ((i=0; i<_n; i++)); do
    id_i="${STORY_IDS[$i]}"
    deps_i="${STORY_DEPS[$i]}"
    IFS=',' read -ra _di <<<"$deps_i"
    for d in "${_di[@]}"; do
        [[ -z "$d" ]] && continue
        # Is d in the input set?
        for ((j=0; j<_n; j++)); do
            id_j="${STORY_IDS[$j]}"
            [[ "$id_j" != "$d" ]] && continue
            # Check if id_j also depends on id_i (mutual)
            deps_j="${STORY_DEPS[$j]}"
            IFS=',' read -ra _dj <<<"$deps_j"
            for d2 in "${_dj[@]}"; do
                [[ -z "$d2" ]] && continue
                if [[ "$d2" == "$id_i" ]]; then
                    echo "CYCLE_DETECTED: stories $id_i and $id_j have a mutual dependency" >&2
                    exit 3
                fi
            done
        done
    done
done

# ── Input source: DSO_MANUAL_INPUT (newline-separated) or stdin ──────────────
_INPUT_LINES=()
_INPUT_IDX=0
if [[ -n "${DSO_MANUAL_INPUT+x}" ]]; then
    # Split on newline into array
    while IFS= read -r ln; do
        _INPUT_LINES+=("$ln")
    done <<<"$DSO_MANUAL_INPUT"
fi

_read_input() {
    # Reads one line. Sets REPLY.
    if [[ ${#_INPUT_LINES[@]} -gt 0 ]]; then
        if (( _INPUT_IDX < ${#_INPUT_LINES[@]} )); then
            REPLY="${_INPUT_LINES[$_INPUT_IDX]}"
            (( _INPUT_IDX++ ))
            return 0
        else
            REPLY=""
            return 1
        fi
    else
        IFS= read -r REPLY
        return $?
    fi
}

# ── Dangerous pattern detection ──────────────────────────────────────────────
_is_dangerous() {
    local cmd="$1"
    local patterns=(
        'rm -rf'
        'eval '
        'sudo '
        'curl | bash'
        'curl|bash'
        'curl | sh'
        'curl|sh'
        'wget | bash'
        'wget|bash'
        'wget | sh'
        'wget|sh'
        '| sh'
        '| bash'
    )
    for p in "${patterns[@]}"; do
        if [[ "$cmd" == *"$p"* ]]; then
            return 0
        fi
    done
    return 1
}

# ── Sentinel / audit token generation ────────────────────────────────────────
_make_audit_token() {
    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local hash
    if command -v sha256sum >/dev/null 2>&1; then
        hash=$(date +%s | sha256sum | cut -c1-8)
    else
        hash=$(printf '%s' "$(date +%s)" | openssl dgst -sha256 2>/dev/null | awk '{print $NF}' | cut -c1-8 || echo "00000000")
    fi
    printf '%s:%s' "$ts" "$hash"
}

_sentinel_json() {
    # $1=story_id  $2=handshake_outcome  $3=exit_code_or_empty  $4=user_input_or_empty
    local sid="$1" outcome="$2" ec="$3" ui="$4"
    python3 - "$sid" "$outcome" "$ec" "$ui" "$(_make_audit_token)" <<'PY'
import json, sys
sid, outcome, ec, ui, tok = sys.argv[1:6]
obj = {
    "audit_token": tok,
    "verification_command_exit_code": int(ec) if ec else None,
    "user_input": ui if ui else None,
    "story_id": sid,
    "handshake_outcome": outcome,
}
print(json.dumps(obj))
PY
}

_write_sentinel() {
    # $1=story_id $2=outcome $3=exit_code_or_empty $4=user_input_or_empty
    local sid="$1" outcome="$2" ec="$3" ui="$4"
    local json; json=$(_sentinel_json "$sid" "$outcome" "$ec" "$ui")
    if ! _ticket_cli ticket comment "$sid" "MANUAL_PAUSE_SENTINEL: $json"; then
        echo "ERROR: failed to write sentinel comment for story $sid" >&2
        return 1
    fi
    return 0
}

# ── Per-story processing ─────────────────────────────────────────────────────
_process_story() {
    # $1=index into arrays. Returns 0 on done-success, 1 on skip, 2 on re-prompt.
    local idx="$1"
    local sid="${STORY_IDS[$idx]}"
    local title="${STORY_TITLES[$idx]}"
    local instr="${STORY_INSTR[$idx]}"
    local vc="${STORY_VC[$idx]}"

    local verify_display
    if [[ "$vc" == "__NONE__" ]]; then
        verify_display="(none — confirmation token required)"
    else
        verify_display="$vc"
    fi

    # Present prompt
    cat <<EOF
--- Manual Step Required ---
Story: $title ($sid)
Instructions: $instr
Verification: $verify_display
Enter: done | done <story-id> | skip
---
EOF

    _read_input || true
    local cmd_input="${REPLY:-}"
    local action="" target_id=""
    case "$cmd_input" in
        skip)
            action="skip"
            ;;
        "done "*)
            action="done_with_story_id"
            target_id="${cmd_input#done }"
            ;;
        done)
            action="done"
            ;;
        *)
            echo "ERROR: unrecognized input: '$cmd_input' (expected done | done <id> | skip)" >&2
            return 2
            ;;
    esac

    # Resolve which story to process
    local process_id="$sid"
    local process_vc="$vc"
    local outcome="done"
    if [[ "$action" == "skip" ]]; then
        # Write skip sentinel
        if ! _write_sentinel "$sid" "skip" "" ""; then
            return 2
        fi
        return 1
    elif [[ "$action" == "done_with_story_id" ]]; then
        # Find target in list
        local found_idx=-1
        for ((k=0; k<_n; k++)); do
            if [[ "${STORY_IDS[$k]}" == "$target_id" ]]; then
                found_idx=$k
                break
            fi
        done
        if [[ "$found_idx" -lt 0 ]]; then
            echo "ERROR: targeted story-id '$target_id' not in input list" >&2
            return 2
        fi
        process_id="${STORY_IDS[$found_idx]}"
        process_vc="${STORY_VC[$found_idx]}"
        outcome="done_with_story_id"
    fi

    # Handle verification_command vs confirmation token
    if [[ "$process_vc" == "__NONE__" ]]; then
        # Confirmation token path
        echo "Enter confirmation token (any text to confirm completion):"
        _read_input || true
        local token="${REPLY:-}"
        if ! _ticket_cli ticket comment "$process_id" "MANUAL_CONFIRMATION_TOKEN: $token"; then
            echo "ERROR: failed to write confirmation token comment for $process_id" >&2
            return 2
        fi
        if ! _write_sentinel "$process_id" "$outcome" "" "$token"; then
            return 2
        fi
        return 0
    fi

    # Verification command path: dangerous pattern check
    if _is_dangerous "$process_vc"; then
        echo "ERROR: verification_command rejected — dangerous pattern detected in: $process_vc" >&2
        return 2
    fi

    # Length check
    if [[ ${#process_vc} -gt $MAX_LEN ]]; then
        echo "ERROR: verification_command rejected — length ${#process_vc} exceeds length limit of $MAX_LEN characters" >&2
        return 2
    fi

    # Log pre-exec
    if ! _ticket_cli ticket comment "$process_id" "MANUAL_VERIFICATION_PRE_EXEC: $process_vc"; then
        echo "ERROR: failed to log MANUAL_VERIFICATION_PRE_EXEC for $process_id" >&2
        return 2
    fi

    # Run in constrained subshell with timeout
    local run_output rc
    run_output=$(timeout "$TIMEOUT" bash --norc --noprofile -c "$process_vc" 2>&1)
    rc=$?

    if [[ $rc -eq 124 ]]; then
        echo "Re-prompt: verification failed: timeout after ${TIMEOUT}s" >&2
        return 2
    elif [[ $rc -ne 0 ]]; then
        echo "Re-prompt: verification failed: $run_output" >&2
        return 2
    fi

    # Success: write sentinel
    if ! _write_sentinel "$process_id" "$outcome" "0" ""; then
        return 2
    fi
    return 0
}

# ── Main loop ────────────────────────────────────────────────────────────────
_had_skip=0
_had_reprompt=0
for ((i=0; i<_n; i++)); do
    _process_story "$i"
    _rc=$?
    case "$_rc" in
        0) : ;;
        1) _had_skip=1 ;;
        2) _had_reprompt=1 ;;
    esac
    # For targeted done <id>, one iteration handles it; continue with next story
done

if [[ $_had_reprompt -eq 1 ]]; then
    exit 2
fi
if [[ $_had_skip -eq 1 ]]; then
    exit 1
fi
exit 0
