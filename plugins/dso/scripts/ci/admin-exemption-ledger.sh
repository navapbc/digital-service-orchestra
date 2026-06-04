#!/usr/bin/env bash
# admin-exemption-ledger.sh — HMAC-signed ledger of admin-bypassed SHAs (S-11 / A-2).
#
# WHY THIS EXISTS (option-a-pivot-plan §2.7/§2.10, A-2):
#   review-coverage-invariant proves coverage PER-SHA ("a covering merged PR has a
#   passing review check-run"). When a human admin BYPASSES the review gate to land
#   a SHA on main (hotfix / emergency), that SHA has NO covering passing review
#   check-run — so once the invariant is ENFORCED, that single bypass would wedge
#   EVERY future PR (the bypassed SHA is in origin/main..HEAD forever and never
#   becomes "reviewed"). This ledger records such SHAs as reviewed-EQUIVALENT,
#   with audit metadata, so the invariant has one additional allowed path to
#   "covered".
#
# ANTI-FABRICATION (the load-bearing requirement — §2.7/§2.10):
#   An exemption MUST NOT be a self-attested trailer or a plaintext line anyone can
#   append. It is HMAC-SIGNED evidence: each entry carries an HMAC-SHA256 over its
#   own fields, keyed by the environment-local secret. A forged or tampered entry
#   (wrong/missing HMAC, or modified metadata) does NOT verify and is treated as
#   ABSENT — the invariant then fails closed for that SHA exactly as before. This
#   mirrors the verdict-hash mechanism (compute-verdict-hash.sh): same key file
#   (.closure-key), same HMAC-SHA256 construction, same pipe-joined data layout.
#
# HMAC SCHEME (patterned on the sibling compute-verdict-hash.sh):
#   key  = contents of <tracker-dir>/.closure-key   (gitignored, per-environment)
#   data = "<sha>|<exempt_by>|<reason>|<timestamp>"
#   mac  = HMAC-SHA256(key, data) hex
#   The .closure-key is the SAME secret used to prove verifier verdicts, so an
#   exemption cannot be minted without the environment's signing key. We do NOT
#   invent a weaker scheme.
#
# LEDGER FILE FORMAT (one entry per line, tab-separated):
#   <sha>\t<exempt_by>\t<reason>\t<timestamp>\t<hmac>
#   exempt_by / reason are stored base64 (single-line, no tabs/newlines leak).
#
# USAGE:
#   admin-exemption-ledger.sh append <ledger> <sha> <exempt_by> <reason>
#       Signs and appends an exemption entry. <timestamp> is generated (epoch s).
#   admin-exemption-ledger.sh verify <ledger> <sha>
#       Exit 0 iff <sha> has at least one HMAC-VALID entry in <ledger>; else 1.
#       (Forged / tampered / absent all -> exit 1, i.e. NOT covered.)
#
# Env:
#   DSO_ADMIN_EXEMPTION_KEY_FILE  override key file path (tests). Default:
#                                 <repo>/.tickets-tracker/.closure-key  # tickets-boundary-ok: doc ref
#   PROJECT_ROOT                  repo root override (mirrors compute-verdict-hash.sh)
#
# This file is a LIBRARY-with-CLI: review-coverage-invariant.sh sources it to call
# ael_sha_is_exempt(); standalone invocation drives append/verify for operators.
set -uo pipefail

# ── Key resolution (identical secret to compute-verdict-hash.sh) ──────────────
ael_key_file() {
    if [[ -n "${DSO_ADMIN_EXEMPTION_KEY_FILE:-}" ]]; then
        printf '%s' "$DSO_ADMIN_EXEMPTION_KEY_FILE"
        return 0
    fi
    local root
    root="${PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null)}"
    [[ -z "$root" ]] && return 1
    printf '%s/.tickets-tracker/.closure-key' "$root"  # tickets-boundary-ok: reads .closure-key for HMAC, same as compute-verdict-hash.sh
}

# ael_compute_hmac <key_file> <sha> <exempt_by> <reason> <timestamp>
#   Echoes the HMAC-SHA256 hex. Patterned exactly on compute-verdict-hash.sh.
ael_compute_hmac() {
    local key_file="$1" sha="$2" exempt_by="$3" reason="$4" ts="$5"
    [[ -f "$key_file" ]] || return 1
    python3 -c "
import hmac, hashlib, sys
with open(sys.argv[1], 'r') as f:
    key = f.read().strip().encode()
data = f'{sys.argv[2]}|{sys.argv[3]}|{sys.argv[4]}|{sys.argv[5]}'.encode()
print(hmac.new(key, data, hashlib.sha256).hexdigest())
" "$key_file" "$sha" "$exempt_by" "$reason" "$ts"
}

_ael_b64enc() { printf '%s' "$1" | base64 | tr -d '\n'; }
_ael_b64dec() { printf '%s' "$1" | base64 --decode 2>/dev/null; }

# ael_append <ledger> <sha> <exempt_by> <reason> [timestamp]
#   Signs and appends. Fails (non-zero) if the signing key is unavailable — an
#   exemption MUST be signed; we never write an unsigned entry.
ael_append() {
    local ledger="$1" sha="$2" exempt_by="$3" reason="$4" ts="${5:-}"
    [[ -z "$ledger" || -z "$sha" || -z "$exempt_by" || -z "$reason" ]] && {
        echo "ael_append: usage: <ledger> <sha> <exempt_by> <reason> [ts]" >&2
        return 2
    }
    [[ -z "$ts" ]] && ts="$(date +%s)"
    local key_file mac
    key_file="$(ael_key_file)" || { echo "ael_append: cannot resolve key file" >&2; return 1; }
    mac="$(ael_compute_hmac "$key_file" "$sha" "$exempt_by" "$reason" "$ts")" || {
        echo "ael_append: signing failed (no key at $key_file?)" >&2
        return 1
    }
    mkdir -p "$(dirname "$ledger")" 2>/dev/null || true
    printf '%s\t%s\t%s\t%s\t%s\n' \
        "$sha" "$(_ael_b64enc "$exempt_by")" "$(_ael_b64enc "$reason")" "$ts" "$mac" >> "$ledger"
}

# ael_sha_is_exempt <ledger> <sha>
#   Returns 0 iff <sha> has >=1 entry whose stored HMAC matches a freshly computed
#   HMAC over its OWN fields (constant-time compare via python hmac.compare_digest).
#   A forged line (no key) or a tampered line (metadata changed but HMAC not, or
#   HMAC changed but metadata not) recomputes to a different MAC and is REJECTED.
#   Absent / empty / unreadable ledger -> 1 (NOT exempt: fail closed).
ael_sha_is_exempt() {
    local ledger="$1" sha="$2" by_filter="${3:-}"
    # by_filter (3ebb DD4 unit 5 / C2): when non-empty, ONLY an entry whose
    # (HMAC-authenticated) exempt_by equals by_filter counts. The provenance
    # consumer (verify-session-provenance) passes "fp-recovery" so it honors ONLY
    # admin FP-recovery exemptions, never an arbitrary signed entry of another
    # class. The coverage consumer may pass nothing (any valid entry). exempt_by
    # is part of the signed payload, so a tampered class fails the HMAC regardless;
    # the filter is additional narrowing on top of that.
    [[ -z "$ledger" || -z "$sha" ]] && return 1
    [[ -f "$ledger" ]] || return 1
    local key_file
    key_file="$(ael_key_file)" || return 1
    [[ -f "$key_file" ]] || return 1  # no key -> cannot verify any entry -> not exempt

    local line e_sha e_by_b64 e_reason_b64 e_ts e_mac calc
    while IFS=$'\t' read -r e_sha e_by_b64 e_reason_b64 e_ts e_mac; do
        [[ "$e_sha" == "$sha" ]] || continue
        # Any structurally-incomplete entry cannot be a valid exemption.
        [[ -n "$e_by_b64" && -n "$e_reason_b64" && -n "$e_ts" && -n "$e_mac" ]] || continue
        local e_by e_reason
        e_by="$(_ael_b64dec "$e_by_b64")"
        # C2 class filter: skip entries not of the requested exempt_by class.
        [[ -z "$by_filter" || "$e_by" == "$by_filter" ]] || continue
        e_reason="$(_ael_b64dec "$e_reason_b64")"
        calc="$(ael_compute_hmac "$key_file" "$e_sha" "$e_by" "$e_reason" "$e_ts")" || continue
        # Constant-time compare; equality => HMAC-valid => SHA is covered.
        if python3 -c "import hmac,sys; sys.exit(0 if hmac.compare_digest(sys.argv[1], sys.argv[2]) else 1)" \
            "$calc" "$e_mac"; then
            return 0
        fi
    done < "$ledger"
    return 1
}

# ── CLI dispatch (only when executed directly, not when sourced) ──────────────
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cmd="${1:-}"; shift || true
    case "$cmd" in
        append)
            ael_append "$@"
            ;;
        verify)
            ledger="${1:-}"; sha="${2:-}"; by_filter="${3:-}"  # optional exempt_by class (C2)
            if ael_sha_is_exempt "$ledger" "$sha" "$by_filter"; then
                echo "EXEMPT $sha"
                exit 0
            else
                echo "NOT_EXEMPT $sha" >&2
                exit 1
            fi
            ;;
        *)
            echo "usage: admin-exemption-ledger.sh {append|verify} ..." >&2
            exit 2
            ;;
    esac
fi
