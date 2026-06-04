#!/usr/bin/env bash
# bypass-actor-set.sh — resolve the designated ruleset bypass-actor SET and test
# membership (ADR-0022, identity-based admin exemption).
#
# A SHA is admin-exempt (reviewed-equivalent) iff its covering merged PR's
# server-set `merged_by.id` is in this set. This replaces the HMAC-signed
# admin-exemption ledger: there is no signing key — the merge actor's identity,
# which GitHub sets server-side, IS the evidence. Forge-proof by construction:
# the agent runs current_user_can_bypass:never, so it cannot merge a check-failing
# PR and cannot appear as `merged_by` on a bypass.
#
# SOURCE (precedence high→low):
#   1. DSO_RULESET_BYPASS_USER_IDS   env, comma/space-separated (tests + CI)
#   2. ruleset.bypass_user_ids       config, comma/space-separated (the SET)
#   3. DSO_RULESET_BYPASS_USER_ID    env scalar (back-compat)
#   4. ruleset.bypass_user_id        config scalar (back-compat)
#
# Each element MUST match ^[0-9]+$; malformed/empty tokens are DISCARDED (never
# widen membership). An empty resolved set => not a bypass actor (FAIL CLOSED) for
# every id — the same inert/safe behavior as "no exemption configured".

# Locate read-config.sh (sibling of this lib's parent: scripts/read-config.sh).
_bas_read_config() {
    local key="$1"
    local _dir _rc
    _dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    _rc="$_dir/../read-config.sh"
    [[ -f "$_rc" ]] || return 1
    # DSO_BYPASS_CONFIG_FILE: test seam to point the read at a specific config file
    # (e.g. an empty file to simulate "no bypass-actor configured").
    if [[ -n "${DSO_BYPASS_CONFIG_FILE:-}" ]]; then
        bash "$_rc" "$key" "$DSO_BYPASS_CONFIG_FILE" 2>/dev/null
    else
        bash "$_rc" "$key" 2>/dev/null
    fi
}

# bas_bypass_actor_ids [config_file_unused]
#   Echoes the validated, space-separated set of numeric IDs (may be empty).
bas_bypass_actor_ids() {
    local raw=""
    if [[ -n "${DSO_RULESET_BYPASS_USER_IDS:-}" ]]; then
        raw="$DSO_RULESET_BYPASS_USER_IDS"
    else
        raw="$(_bas_read_config ruleset.bypass_user_ids || true)"
        if [[ -z "$raw" ]]; then
            if [[ -n "${DSO_RULESET_BYPASS_USER_ID:-}" ]]; then
                raw="$DSO_RULESET_BYPASS_USER_ID"
            else
                raw="$(_bas_read_config ruleset.bypass_user_id || true)"
            fi
        fi
    fi
    # Split on comma/space; keep only well-formed numeric tokens (per-element
    # validation — a trailing comma, blank, or typo must NOT widen membership).
    local out=() tok _toks
    IFS=', ' read -ra _toks <<< "$raw"
    for tok in "${_toks[@]}"; do
        [[ "$tok" =~ ^[0-9]+$ ]] && out+=("$tok")
    done
    printf '%s' "${out[*]:-}"
}

# bas_is_bypass_actor <merged_by_id> [config_file_unused]
#   Exit 0 iff <merged_by_id> is a valid numeric id present in the resolved set.
#   A null/empty/non-numeric id (e.g. merged_by==null, or an app/queue actor whose
#   id is absent) => return 1 (FAIL CLOSED), never exempt.
bas_is_bypass_actor() {
    local id="${1:-}"
    [[ "$id" =~ ^[0-9]+$ ]] || return 1
    local set_ids x
    set_ids="$(bas_bypass_actor_ids)"
    [[ -z "$set_ids" ]] && return 1
    for x in $set_ids; do
        [[ "$x" == "$id" ]] && return 0
    done
    return 1
}
