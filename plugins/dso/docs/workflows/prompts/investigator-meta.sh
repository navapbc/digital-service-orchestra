# shellcheck shell=bash
# investigator-meta.sh — metadata for the "investigator" namespace consumed by build-composed-agents.sh.
# Output filenames take the form investigator-<variant>.md.

_meta_output_prefix="investigator-"

_meta_model_for() {
    case "$1" in
        basic)                                echo "sonnet" ;;
        intermediate|intermediate-fallback)   echo "opus" ;;
        advanced-code-tracer|advanced-historical) echo "opus" ;;
        escalated-web|escalated-history|escalated-code-tracer|escalated-empirical) echo "opus" ;;
        *) echo "ERROR: unknown variant: $1" >&2; return 1 ;;
    esac
}

_meta_color_for() {
    echo "purple"
}

_meta_description_for() {
    case "$1" in
        basic)                  echo "Bug investigator (sonnet, BASIC tier): single-pass localization, five whys, single proposed fix for low-complexity bugs." ;;
        intermediate)           echo "Bug investigator (opus, INTERMEDIATE tier): dependency-ordered reading, intermediate variable tracking, hypothesis elimination, ≥2 ranked fixes with tradeoffs." ;;
        intermediate-fallback)  echo "Bug investigator (opus, INTERMEDIATE fallback persona): same investigation depth as intermediate when error-detective is unavailable." ;;
        advanced-code-tracer)   echo "Bug investigator (opus, ADVANCED Code Tracer lens): execution path tracing, intermediate variable tracking, code-evidence hypothesis set." ;;
        advanced-historical)    echo "Bug investigator (opus, ADVANCED Historical lens): timeline reconstruction, fault tree analysis, git bisect, change-history hypothesis set." ;;
        escalated-web)          echo "Bug investigator (opus, ESCALATED Web Researcher): error pattern analysis, dependency changelogs, upstream issue correlation; WebSearch/WebFetch authorized." ;;
        escalated-history)      echo "Bug investigator (opus, ESCALATED History Analyst): deep timeline reconstruction, fault tree, commit bisection beyond ADVANCED depth." ;;
        escalated-code-tracer)  echo "Bug investigator (opus, ESCALATED Code Tracer): deep execution-path tracing, dependency-ordered analysis, state and concurrency inspection." ;;
        escalated-empirical)    echo "Bug investigator (opus, ESCALATED Empirical Agent): authorized to add temporary logging/debugging; veto authority over theoretical consensus; must confirm artifact revert." ;;
        *) echo "ERROR: unknown variant: $1" >&2; return 1 ;;
    esac
}
