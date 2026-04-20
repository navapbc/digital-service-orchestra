#!/usr/bin/env bash
# sprint-pause-state.sh — state file manager for sprint manual-pause SIGURG recovery.
#
# Subcommands:
#   init <epic-id>                  create state file if not already fresh
#   write <epic-id> <story-id> <v>  update story_answers[story-id]=v
#   read <epic-id>                  print state JSON; exit 1 if absent
#   is-fresh <epic-id>              exit 0 if file exists and mtime < 240 min
#   cleanup <epic-id>               remove state file; always exit 0
#   stale-cleanup                   remove all state files older than TTL
#   resume-context <epic-id>        print first unanswered story ID; exit 1 if none
#
# When sourced, defines _spause_file_path and _spause_sigurg_handler for SIGURG traps.
# Flag gate: SPRINT_PAUSE_ENABLED=false or planning.external_dependency_block_enabled=false → no-op.

set -uo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PLUGIN_ROOT="$(cd "$_SCRIPT_DIR/.." && pwd)"

_STATE_DIR="${SPRINT_PAUSE_STATE_DIR:-/tmp}"
_TTL_MINUTES=240

# ── helpers (always defined — available when sourced) ──────────────────────

_spause_file_path() {
    local _id
    _id=$(echo "${1}" | tr '/ \t' '---')
    echo "${_STATE_DIR}/sprint-pause-state-${_id}.json"
}

_spause_sigurg_handler() {
    local _epic_id="${1:-}"
    [[ -z "$_epic_id" ]] && return 0
    local _f
    _f=$(_spause_file_path "$_epic_id")
    [[ -f "$_f" ]] || return 0
    python3 - "$_f" <<'PYEOF' 2>/dev/null || true
import json, sys, os
path = sys.argv[1]
with open(path) as fh:
    data = json.load(fh)
data['in_progress_marker'] = False
tmp = path + '.tmp'
with open(tmp, 'w') as fh:
    json.dump(data, fh, indent=2)
os.replace(tmp, path)
PYEOF
    return 0
}

_spause_is_enabled() {
    local _env="${SPRINT_PAUSE_ENABLED:-}"
    if [[ "$_env" == "false" ]]; then return 1; fi
    local _cfg
    _cfg=$(bash "$_PLUGIN_ROOT/scripts/read-config.sh" \
           planning.external_dependency_block_enabled 2>/dev/null || echo "true")
    [[ "${_cfg:-true}" == "false" ]] && return 1
    return 0
}

# ── main dispatch (only when executed, not sourced) ────────────────────────

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    if ! _spause_is_enabled; then
        exit 0
    fi

    _cmd="${1:-}"
    shift || true

    case "$_cmd" in

        init)
            _eid="${1:?init requires <epic-id>}"
            _f=$(_spause_file_path "$_eid")
            # no-op if already fresh
            bash "${BASH_SOURCE[0]}" is-fresh "$_eid" 2>/dev/null && exit 0
            python3 - "$_f" "$_eid" <<'PYEOF' 2>/dev/null || true
import json, sys, os, time
path, eid = sys.argv[1], sys.argv[2]
data = {
    "epic_id": eid,
    "stories": [],
    "story_answers": {},
    "in_progress_marker": False,
    "created_at": time.time()
}
tmp = path + '.tmp'
with open(tmp, 'w') as fh:
    json.dump(data, fh, indent=2)
os.replace(tmp, path)
PYEOF
            ;;

        write)
            _eid="${1:?write requires <epic-id>}"
            _sid="${2:?write requires <story-id>}"
            _val="${3:?write requires <value>}"
            _f=$(_spause_file_path "$_eid")
            python3 - "$_f" "$_sid" "$_val" <<'PYEOF' 2>/dev/null || true
import json, sys, os
path, sid, val = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as fh:
    data = json.load(fh)
data['story_answers'][sid] = val
tmp = path + '.tmp'
with open(tmp, 'w') as fh:
    json.dump(data, fh, indent=2)
os.replace(tmp, path)
PYEOF
            ;;

        read)
            _eid="${1:?read requires <epic-id>}"
            _f=$(_spause_file_path "$_eid")
            if [[ ! -f "$_f" ]]; then
                echo "ERROR: state file not found: $_f" >&2
                exit 1
            fi
            cat "$_f"
            ;;

        is-fresh)
            _eid="${1:?is-fresh requires <epic-id>}"
            _f=$(_spause_file_path "$_eid")
            [[ -f "$_f" ]] || exit 1
            # exit 0 = fresh (age < TTL); exit 1 = stale or python3 unavailable
            python3 - "$_f" "$_TTL_MINUTES" 2>/dev/null <<'PYEOF'
import sys, os, time
path, ttl = sys.argv[1], int(sys.argv[2])
mtime = os.path.getmtime(path)
age_minutes = (time.time() - mtime) / 60
sys.exit(0 if age_minutes < ttl else 1)
PYEOF
            _py=$?
            exit $_py
            ;;

        cleanup)
            _eid="${1:?cleanup requires <epic-id>}"
            _f=$(_spause_file_path "$_eid")
            rm -f "$_f" 2>/dev/null || true
            exit 0
            ;;

        stale-cleanup)
            while IFS= read -r _sf; do
                _is_stale=$(python3 -c "
import os, time, sys
f, ttl = sys.argv[1], int(sys.argv[2])
try:
    age = (time.time() - os.path.getmtime(f)) / 60
    print('yes' if age >= ttl else 'no')
except Exception:
    print('yes')
" "$_sf" "$_TTL_MINUTES" 2>/dev/null) || _is_stale="yes"
                [[ "$_is_stale" == "yes" ]] && rm -f "$_sf" 2>/dev/null || true
            done < <(find "$_STATE_DIR" -maxdepth 1 -name 'sprint-pause-state-*.json' 2>/dev/null)
            ;;

        resume-context)
            _eid="${1:?resume-context requires <epic-id>}"
            _f=$(_spause_file_path "$_eid")
            [[ -f "$_f" ]] || exit 1
            python3 - "$_f" <<'PYEOF' 2>/dev/null
import json, sys
with open(sys.argv[1]) as fh:
    data = json.load(fh)
answered = set(data.get('story_answers', {}).keys())
for s in data.get('stories', []):
    if s not in answered:
        print(s)
        sys.exit(0)
sys.exit(1)
PYEOF
            ;;

        *)
            echo "Usage: sprint-pause-state.sh <init|write|read|is-fresh|cleanup|stale-cleanup|resume-context> [args...]" >&2
            exit 1
            ;;
    esac
fi
