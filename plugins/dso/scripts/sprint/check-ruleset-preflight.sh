#!/usr/bin/env bash
set -euo pipefail
# check-ruleset-preflight.sh
# Validates the GitHub Rulesets the sprint ci-pr promotion relies on. TRANSITION-
# TOLERANT (dual-mode, MQ-5 / ADR-0019): the live ruleset is re-provisioned in a
# single gated cutover (MQ-6), so this preflight — which runs at sprint Phase A —
# must pass against BOTH promotion models and select which to assert from live
# state. The discriminator is FAIL-CLOSED: MQ mode iff the MAIN ruleset carries a
# merge_queue rule; otherwise the two-tier assertions run (the closed default).
#
# Usage:
#   check-ruleset-preflight.sh [--repo <owner/repo>] [--config <path-to-dso-config.conf>]
#
# Environment:
#   DSO_CONFIG_FILE — path to dso-config.conf (overrides default discovery)
#
# Exit codes:
#   0 = all Ruleset conditions satisfied (for the active model)
#   1 = validation failure or dependency missing
#
# TWO-TIER model (no merge_queue rule on main — pre-cutover):
#   1. A Ruleset matching staged-* requires the sub-PR review check (default
#      review-sub-pr) and has no required_linear_history (PR1 session→staged gate).
#   2. A Ruleset matching main requires check-staged-head + llm-review, does NOT
#      require the sub-PR check (it never runs on staged-*→main; would deadlock
#      PR2), and has no required_linear_history (PR2 staged→main gate).
#
# MERGE-QUEUE model (merge_queue rule on main — post-cutover):
#   1. The main Ruleset has a merge_queue rule, still requires llm-review, no
#      longer requires check-staged-head, and has no required_linear_history.
#   2. Some Ruleset still requires the sub-PR review check (every commit reviewed
#      at sub-PR time). The enforcing ruleset's ref include is not asserted here
#      (staged-* vs session-* is finalized by MQ-4/MQ-6).
#
# Reads dso.review.check_name from dso-config.conf for the sub-PR check; falls back to 'review-sub-pr'.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Dependency checks ─────────────────────────────────────────────────────────
if ! command -v gh >/dev/null 2>&1; then
    echo "ERROR: gh CLI is required but not found in PATH." >&2
    echo "  Install: https://cli.github.com/" >&2
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 is required but not found in PATH." >&2
    exit 1
fi

# ── Argument parsing ──────────────────────────────────────────────────────────
REPO_ARG=""
CONFIG_FILE_ARG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo)
            REPO_ARG="$2"
            shift 2
            ;;
        --config)
            CONFIG_FILE_ARG="$2"
            shift 2
            ;;
        *)
            echo "ERROR: Unknown argument: $1" >&2
            echo "Usage: check-ruleset-preflight.sh [--repo <owner/repo>] [--config <path>]" >&2
            exit 1
            ;;
    esac
done

# ── Resolve dso-config.conf path ──────────────────────────────────────────────
# Priority: DSO_CONFIG_FILE env var > --config arg > default discovery
_resolve_config_file() {
    if [[ -n "${DSO_CONFIG_FILE:-}" ]]; then
        echo "$DSO_CONFIG_FILE"
        return
    fi
    if [[ -n "$CONFIG_FILE_ARG" ]]; then
        echo "$CONFIG_FILE_ARG"
        return
    fi
    # Default: look for .claude/dso-config.conf relative to repo root (walk up from script)
    local dir="$SCRIPT_DIR"
    while [[ "$dir" != "/" ]]; do
        if [[ -f "$dir/.claude/dso-config.conf" ]]; then
            echo "$dir/.claude/dso-config.conf"
            return
        fi
        dir="$(dirname "$dir")"
    done
    echo ""
}

# ── Read check_name from config ───────────────────────────────────────────────
_read_check_name() {
    local config_file="$1"
    local default_name="review-sub-pr"

    if [[ -z "$config_file" ]] || [[ ! -f "$config_file" ]]; then
        echo "$default_name"
        return
    fi

    local value
    value="$(grep -E '^dso\.review\.check_name=' "$config_file" 2>/dev/null | tail -1 | cut -d= -f2-)" || true
    if [[ -n "$value" ]]; then
        echo "$value"
    else
        echo "$default_name"
    fi
}

CONFIG_FILE="$(_resolve_config_file)"
CHECK_NAME="$(_read_check_name "$CONFIG_FILE")"

# ── Fetch rulesets ────────────────────────────────────────────────────────────
_fetch_rulesets() {
    local repo_slug base_path
    if [[ -n "$REPO_ARG" ]]; then
        repo_slug="$REPO_ARG"
    else
        repo_slug="$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null)" || true
    fi
    if [[ -z "$repo_slug" ]]; then
        echo "ERROR: could not resolve owner/repo for ruleset lookup" >&2
        return 1
    fi
    base_path="/repos/$repo_slug/rulesets"

    local list_raw
    list_raw="$(gh api "$base_path" 2>&1)" || { printf '%s\n' "$list_raw"; return 1; }

    # The GitHub `/rulesets` LIST endpoint returns ruleset SUMMARIES WITHOUT
    # conditions/rules — those require a per-id GET /rulesets/{id}. (The original
    # script validated conditions/rules straight off the list, so it always failed
    # against live.) If the response already embeds conditions (test stubs, or a
    # future API), use it verbatim; otherwise fetch each ruleset's full object by id.
    if printf '%s' "$list_raw" | grep -q '"conditions"'; then
        printf '%s\n' "$list_raw"
        return 0
    fi

    local ids id obj sep="" out="["
    ids="$(printf '%s' "$list_raw" | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = []
items = d.get("rulesets", d) if isinstance(d, dict) else d
items = items if isinstance(items, list) else []
print("\n".join(str(r["id"]) for r in items if isinstance(r, dict) and r.get("id") is not None))' 2>/dev/null)" || ids=""
    for id in $ids; do
        obj="$(gh api "$base_path/$id" 2>/dev/null)" || continue
        [[ -z "$obj" ]] && continue
        out+="${sep}${obj}"; sep=","
    done
    out+="]"
    printf '{"rulesets":%s}\n' "$out"
}

TMPFILE="$(mktemp /tmp/check-ruleset-preflight.XXXXXX)"
trap 'rm -f "$TMPFILE"' EXIT

if ! _fetch_rulesets > "$TMPFILE" 2>&1; then
    echo "ERROR: Failed to fetch rulesets from GitHub API." >&2
    cat "$TMPFILE" >&2
    exit 1
fi

RULESETS_JSON="$(cat "$TMPFILE")"

# ── Validation (two-tier promotion model) ─────────────────────────────────────
# Validates the two GitHub Rulesets the sprint two-tier flow relies on, in a
# single jq-free python3 invocation. Emits one result token (see case below):
#   Sub-PR ruleset (ref include matches `staged-*`): requires the sub-PR review
#     check (default `review-sub-pr`, gating PR1 session→staged); no linear_history.
#   Main ruleset (ref include matches `main`): requires `check-staged-head` +
#     `llm-review`; must NOT require the sub-PR check (it never runs on a
#     staged-*→main PR and would deadlock PR2); no linear_history.
_PRELIGHT_RESULT="$(DSO_SUBPR_CHECK="$CHECK_NAME" python3 - "$TMPFILE" <<'PYEOF'
import json, os, sys

with open(sys.argv[1]) as f:
    try:
        data = json.load(f)
    except Exception:
        print("FETCH_PARSE_ERROR"); sys.exit(0)

# data may be {"rulesets": [...]} or a bare array
rulesets = data.get("rulesets") if isinstance(data, dict) and "rulesets" in data else data
if not isinstance(rulesets, list):
    print("FETCH_PARSE_ERROR"); sys.exit(0)

subpr_check = os.environ.get("DSO_SUBPR_CHECK") or "review-sub-pr"


def _includes(rs):
    return ((rs.get("conditions") or {}).get("ref_name") or {}).get("include") or []


def _required_contexts(rs):
    out = []
    for r in (rs.get("rules") or []):
        if isinstance(r, dict) and r.get("type") == "required_status_checks":
            for c in ((r.get("parameters") or {}).get("required_status_checks") or []):
                if isinstance(c, dict):
                    out.append(c.get("context"))
    return out


def _has_linear(rs):
    return any(
        isinstance(r, dict) and r.get("type") in ("linear_history", "required_linear_history")
        for r in (rs.get("rules") or [])
    )


def _has_merge_queue(rs):
    return any(
        isinstance(r, dict) and r.get("type") == "merge_queue"
        for r in (rs.get("rules") or [])
    )


def _find(pred):
    for rs in rulesets:
        if isinstance(rs, dict) and pred(_includes(rs)):
            return rs
    return None


# Main tier: the ruleset whose ref include references the default branch (main) and NOT staged-*.
def _is_main_include(p):
    return isinstance(p, str) and (
        p in ("refs/heads/main", "main", "~DEFAULT_BRANCH") or p.endswith("/main")
    )


# main_rs may be None in malformed/partial states; that is handled per-mode
# below so the two-tier error ordering (sub-PR errors before NO_MAIN_RULESET)
# is preserved.
main_rs = _find(
    lambda incs: any(_is_main_include(p) for p in incs)
    and not any(isinstance(p, str) and "staged-" in p for p in incs)
)


def _any_ruleset_requires(ctx):
    return any(isinstance(rs, dict) and ctx in _required_contexts(rs) for rs in rulesets)


# Dual-mode discriminator (MQ-5, ADR-0019): MQ mode iff a MAIN ruleset EXISTS and
# carries a merge_queue rule (what MQ-6 provisions live). Anything else — no main
# ruleset, or a main ruleset without a merge_queue rule — falls through to the
# two-tier assertions: the FAIL-CLOSED default. A two-tier regression (e.g.
# check-staged-head wrongly dropped) cannot masquerade as MQ because it lacks the
# merge_queue rule. Mirrors tests/scripts/test-ruleset-design-invariants.sh.
if main_rs is not None and _has_merge_queue(main_rs):
    # ── MERGE-QUEUE model (post-cutover) ──
    main_checks = _required_contexts(main_rs)
    if "check-staged-head" in main_checks:
        print("MQ_MAIN_HAS_STAGED_HEAD"); sys.exit(0)
    if "llm-review" not in main_checks:
        print("MQ_MAIN_MISSING_LLM_REVIEW"); sys.exit(0)
    if _has_linear(main_rs):
        print("MQ_MAIN_HAS_LINEAR"); sys.exit(0)
    # The per-story sub-PR LLM review must survive (every commit reviewed at
    # sub-PR time). Tolerant on the enforcing ruleset's ref include (staged-* vs
    # session-* is finalized by MQ-4/MQ-6) — require only that SOME ruleset gates
    # the sub-PR check.
    if not _any_ruleset_requires(subpr_check):
        print("MQ_NO_SUBPR_REVIEW"); sys.exit(0)
    print("OK_MQ"); sys.exit(0)

# ── TWO-TIER model (pre-cutover; fail-closed default) ──
# Sub-PR tier: the ruleset whose ref include references staged-* (gates PR1 session→staged).
subpr = _find(lambda incs: any(isinstance(p, str) and "staged-" in p for p in incs))
if subpr is None:
    print("NO_SUBPR_RULESET"); sys.exit(0)
if subpr_check not in _required_contexts(subpr):
    print("SUBPR_MISSING_CHECK"); sys.exit(0)
if _has_linear(subpr):
    print("SUBPR_HAS_LINEAR"); sys.exit(0)
if main_rs is None:
    print("NO_MAIN_RULESET"); sys.exit(0)
main_checks = _required_contexts(main_rs)
if "check-staged-head" not in main_checks:
    print("MAIN_MISSING_STAGED_HEAD"); sys.exit(0)
if "llm-review" not in main_checks:
    print("MAIN_MISSING_LLM_REVIEW"); sys.exit(0)
# review-sub-pr triggers on base != main, so it never runs on a staged-*→main PR;
# requiring it on the main ruleset would leave PR2 permanently pending (deadlock).
if subpr_check in main_checks:
    print("MAIN_HAS_SUBPR"); sys.exit(0)
if _has_linear(main_rs):
    print("MAIN_HAS_LINEAR"); sys.exit(0)

print("OK")
PYEOF
)"

case "$_PRELIGHT_RESULT" in
    OK)
        echo "GitHub Ruleset preflight check: success (two-tier promotion model)"
        echo "  - Sub-PR ruleset (staged-*) requires '$CHECK_NAME': found"
        echo "  - Main ruleset requires check-staged-head + llm-review: found"
        echo "  - Main ruleset does not require the sub-PR check (no PR2 deadlock): confirmed"
        echo "  - No linear_history constraint on either ruleset: confirmed"
        exit 0
        ;;
    OK_MQ)
        echo "GitHub Ruleset preflight check: success (merge queue promotion model)"
        echo "  - Main ruleset has a merge_queue rule: found"
        echo "  - Main ruleset no longer requires check-staged-head (retired): confirmed"
        echo "  - Main ruleset requires llm-review (session→main integration review): found"
        echo "  - A ruleset still requires the sub-PR check '$CHECK_NAME': found"
        echo "  - No linear_history constraint on the main ruleset: confirmed"
        exit 0
        ;;
    MQ_MAIN_HAS_STAGED_HEAD)
        echo "ERROR: Under the merge queue model the main Ruleset still requires 'check-staged-head'." >&2
        echo "  check-staged-head is retired at cutover; a required context nothing emits would block every queue entry." >&2
        echo "  Re-provision the main ruleset (provision-ruleset.sh) to drop check-staged-head." >&2
        exit 1
        ;;
    MQ_MAIN_MISSING_LLM_REVIEW)
        echo "ERROR: Under the merge queue model the main Ruleset does not require 'llm-review'." >&2
        echo "  The session→main PR's provenance-aware llm-review must still gate promotion." >&2
        exit 1
        ;;
    MQ_MAIN_HAS_LINEAR)
        echo "ERROR: The main Ruleset contains a 'required_linear_history' rule (incompatible with merge-queue merge commits)." >&2
        exit 1
        ;;
    MQ_NO_SUBPR_REVIEW)
        echo "ERROR: Under the merge queue model no Ruleset requires the sub-PR review check '$CHECK_NAME'." >&2
        echo "  Every commit must still be reviewed at sub-PR time; the sub-PR review enforcement must survive the cutover." >&2
        exit 1
        ;;
    FETCH_PARSE_ERROR)
        echo "ERROR: could not parse the GitHub rulesets API response." >&2
        exit 1
        ;;
    NO_SUBPR_RULESET)
        echo "ERROR: No GitHub Ruleset found matching 'staged-*' (the sub-PR review tier)." >&2
        echo "  Expected a Ruleset with conditions.ref_name.include containing 'refs/heads/staged-*'." >&2
        echo "  Provision it via provision-ruleset.sh. See: INSTALL.md (two-tier promotion rulesets)." >&2
        exit 1
        ;;
    SUBPR_MISSING_CHECK)
        echo "ERROR: The staged-* (sub-PR) Ruleset does not require '$CHECK_NAME'." >&2
        echo "  PR1 (session→staged) would not be gated by the sub-PR review." >&2
        exit 1
        ;;
    SUBPR_HAS_LINEAR)
        echo "ERROR: The staged-* Ruleset contains a 'required_linear_history' rule." >&2
        echo "  This blocks the merge-commit promotion strategy. Remove it." >&2
        exit 1
        ;;
    NO_MAIN_RULESET)
        echo "ERROR: No GitHub Ruleset found matching 'main'." >&2
        echo "  Expected a Ruleset with conditions.ref_name.include containing 'refs/heads/main'." >&2
        exit 1
        ;;
    MAIN_MISSING_STAGED_HEAD)
        echo "ERROR: The main Ruleset does not require 'check-staged-head'." >&2
        echo "  Without it, non-staged-* branches could merge directly to main, bypassing the two-tier flow." >&2
        exit 1
        ;;
    MAIN_MISSING_LLM_REVIEW)
        echo "ERROR: The main Ruleset does not require 'llm-review' (the staged→main integration review)." >&2
        exit 1
        ;;
    MAIN_HAS_SUBPR)
        echo "ERROR: The main Ruleset requires '$CHECK_NAME', which never runs on a staged-*→main PR." >&2
        echo "  This would leave PR2 permanently pending (deadlock). Remove the sub-PR check from the main ruleset." >&2
        exit 1
        ;;
    MAIN_HAS_LINEAR)
        echo "ERROR: The main Ruleset contains a 'required_linear_history' rule (blocks merge-commit promotion)." >&2
        exit 1
        ;;
    *)
        echo "ERROR: preflight check returned unexpected result: ${_PRELIGHT_RESULT}" >&2
        exit 1
        ;;
esac
