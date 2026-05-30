# shellcheck shell=bash
# reviewer-meta.sh — metadata for the "reviewer" namespace consumed by build-composed-agents.sh.
# Output filenames take the form code-reviewer-<variant>.md.

_meta_output_prefix="code-reviewer-"

_meta_model_for() {
    case "$1" in
        light)              echo "haiku" ;;
        standard)           echo "sonnet" ;;
        deep-correctness)   echo "sonnet" ;;
        deep-verification)  echo "sonnet" ;;
        deep-hygiene)       echo "sonnet" ;;
        deep-arch)          echo "opus" ;;
        security-red-team)  echo "opus" ;;
        security-blue-team) echo "opus" ;;
        performance)        echo "opus" ;;
        test-quality)       echo "opus" ;;
        *) echo "ERROR: unknown variant: $1" >&2; return 1 ;;
    esac
}

_meta_color_for() {
    case "$1" in
        security-blue-team) echo "blue" ;;
        *)                  echo "red" ;;
    esac
}

# Map a variant to the canonical review tier accepted by write-reviewer-findings.sh.
# Tier values: light, standard, deep. All deep-*, overlay, and specialty tiers map to "deep".
_canonical_tier_for_variant() {
    case "$1" in
        light)    echo "light" ;;
        standard) echo "standard" ;;
        *)        echo "deep" ;;
    esac
}

_meta_description_for() {
    case "$1" in
        light)              echo "Light-tier code reviewer: single-pass, highest-signal checklist for fast feedback on low-to-medium-risk changes." ;;
        standard)           echo "Standard-tier code reviewer: comprehensive review across all five scoring dimensions for moderate-to-high-risk changes." ;;
        deep-correctness)   echo "Deep-tier correctness specialist (Sonnet A): focused exclusively on correctness — edge cases, error handling, security, efficiency." ;;
        deep-verification)  echo "Deep-tier verification specialist (Sonnet B): focused exclusively on verification — test presence, quality, edge case coverage, mock correctness." ;;
        deep-hygiene)       echo "Deep-tier hygiene/design specialist (Sonnet C): focused on hygiene, design, and maintainability." ;;
        deep-arch)          echo "Deep-tier architectural reviewer (Opus): synthesizes specialist findings, assesses systemic risk, produces unified verdict across all dimensions." ;;
        security-red-team)  echo "Security red team reviewer (Opus): aggressive security detection without ticket context for AI-advantaged security concerns." ;;
        security-blue-team) echo "Security blue team reviewer (Opus): context-aware triage of red team findings with dismiss/downgrade/sustain authority." ;;
        performance)        echo "Performance reviewer (Opus): calibrated performance analysis with bright-line severity rules for scaling failures and resource exhaustion." ;;
        test-quality)       echo "Test quality reviewer (Opus): detects test bloat patterns including change-detector tests, implementation-coupled assertions, tautological tests, source-file-grepping, and existence-only assertions." ;;
        *) echo "ERROR: unknown variant: $1" >&2; return 1 ;;
    esac
}

# Strip DISPATCH-marked sections from base content based on the DISPATCH_VARIANT env var.
# Keeps blocks matching DISPATCH_VARIANT, removes the opposite. When DISPATCH_VARIANT is
# unset (legacy callers / tests), keeps both blocks — backward compatible.
# Markers in the source: <!-- DISPATCH:orchestrator --> ... <!-- /DISPATCH:orchestrator -->
#                       <!-- DISPATCH:ci -->          ... <!-- /DISPATCH:ci -->
_meta_dispatch_strip() {
    local strip_variant="$1"  # e.g., "ci" or "orchestrator"
    python3 -c '
import sys, re
strip = sys.argv[1]
content = sys.stdin.read()
pattern = r"<!-- DISPATCH:" + re.escape(strip) + r" -->.*?<!-- /DISPATCH:" + re.escape(strip) + r" -->\n?"
content = re.sub(pattern, "", content, flags=re.DOTALL)
sys.stdout.write(content)
' "$strip_variant"
}

# Substitute {{CANONICAL_TIER}}, strip DISPATCH-opposite blocks based on DISPATCH_VARIANT
# env var, and for the light tier also remove the "Context-Request Protocol" section
# (bug 57b9-1f14 — the light-tier delta supplies the correct "NOT available for light
# tier" notice).
#
# DISPATCH_VARIANT semantics:
#   DISPATCH_VARIANT=orchestrator  → strip <!-- DISPATCH:ci --> blocks
#   DISPATCH_VARIANT=ci            → strip <!-- DISPATCH:orchestrator --> blocks
#   DISPATCH_VARIANT unset/other   → no DISPATCH stripping (backward compat)
_meta_substitute_base() {
    local variant="$1"
    local canonical
    canonical="$(_canonical_tier_for_variant "$variant")"

    local _dispatch_filter
    case "${DISPATCH_VARIANT:-}" in
        orchestrator) _dispatch_filter="_meta_dispatch_strip ci" ;;
        ci)           _dispatch_filter="_meta_dispatch_strip orchestrator" ;;
        *)            _dispatch_filter="cat" ;;
    esac

    if [[ "$variant" == "light" ]]; then
        # Replace {{CANONICAL_TIER}}, apply DISPATCH filter, then strip the full
        # context-request protocol section. The section spans from "### Context-Request
        # Protocol (standard / deep / overlay tiers only)" through the line before the
        # closing "---" separator preceding Step 2.
        local _py_script
        _py_script='
import sys, re
content = sys.stdin.read()
content = re.sub(
    r"### Context-Request Protocol \(standard / deep / overlay tiers only\)\n"
    r".*?"
    r"(?=\n---\n)",
    "",
    content,
    flags=re.DOTALL
)
sys.stdout.write(content)
'
        sed "s|{{CANONICAL_TIER}}|${canonical}|g" | eval "$_dispatch_filter" | python3 -c "$_py_script"
    else
        sed "s|{{CANONICAL_TIER}}|${canonical}|g" | eval "$_dispatch_filter"
    fi
}
