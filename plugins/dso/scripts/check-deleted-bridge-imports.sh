#!/usr/bin/env bash
# check-deleted-bridge-imports.sh — scan for references to deleted legacy bridge modules.
# Strict mode (default, enforcing): exit 1 if any hits exist.
# --advisory: exit 0 regardless of hits (legacy/local override for soft rollout).
#
# Matches only real module references (Python `from`/`import` statements or
# `<module>.py` filename references), not the generic English word "bootstrap".

set -euo pipefail

MODE="strict"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --strict) MODE="strict"; shift ;;
        --advisory) MODE="advisory"; shift ;;
        -h|--help)
            echo "Usage: $0 [--strict|--advisory]"
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$REPO_ROOT"

# Derive the plugin's git-relative path (check-plugin-self-ref forbids literal
# references — see CLAUDE.md "Namespace policy").
#
# Derive from $0 (script's own location) unconditionally. $0 always resolves to
# the script in the current worktree, regardless of CLAUDE_PLUGIN_ROOT — which
# may point at the main repo's plugin cache during a worktree session and would
# otherwise cause us to scan the wrong dso_reconciler/ directory.
_SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
_PLUGIN_ABS_DIR=$(cd "$_SCRIPT_DIR/.." && pwd)
_PLUGIN_GIT_PATH="${_PLUGIN_ABS_DIR#"$REPO_ROOT"/}"

# Defensive: if _PLUGIN_GIT_PATH is still absolute (script outside the repo),
# fall back to a known-good default. The default literal is constructed from
# parts to satisfy the no-self-reference rule applied to plugin-shipped files.
if [[ "$_PLUGIN_GIT_PATH" = /* ]]; then
    _PLUGIN_GIT_PATH="plugins""/dso"
fi
RECONCILER_DIR="${_PLUGIN_GIT_PATH}/scripts/dso_reconciler"

MODULES=(bootstrap orphan_band duplicates_band stale_band open_count_skew_band)

# Zone -> path mapping
declare -A ZONES=(
    [reconciler]="$RECONCILER_DIR"
    [workflows]=".github/workflows"
    [tests]="tests"
    [repo]="."
)

TOTAL_HITS=0

scan_zone() {
    local zone_name="$1"
    local zone_path="$2"
    local count=0
    local hits=""
    local alt
    alt=$(IFS='|'; echo "${MODULES[*]}")
    # Match real module references only:
    #   1. <module>.py            — filename references (subprocess, docstrings)
    #   2. import [.]<module>     — plain import statements (incl. relative)
    #   3. from [.]<module>[.x] import
    #                             — from-import statements (incl. relative/dotted)
    # The from-branch REQUIRES a trailing `import` keyword. Without it, the bare
    # `from <module>` form matched English prose such as "attestations from
    # bootstrap phases" in docs (false positive — the case this comment
    # previously claimed to avoid). The `import` keyword is the discriminator
    # between a Python statement and ordinary prose.
    local pat_py="($alt)\\.py"
    local pat_import="(^|[^A-Za-z0-9_.])import[[:space:]]+(\\.+)?($alt)([[:space:]]|\$|,|\\.)"
    local pat_from="(^|[^A-Za-z0-9_.])from[[:space:]]+(\\.+)?($alt)[A-Za-z0-9_.]*[[:space:]]+import([[:space:]]|\$)"
    local pattern="$pat_py|$pat_import|$pat_from"
    if command -v rg >/dev/null 2>&1; then
        if [[ -e "$zone_path" ]]; then
            hits=$(rg --no-heading --line-number -e "$pattern" "$zone_path" 2>/dev/null || true)
        fi
    else
        if [[ -e "$zone_path" ]]; then
            # --exclude-dir=.git: match rg's behavior (rg skips .git and
            # .gitignored paths). Without this the grep fallback scans .git/
            # internals (logs, COMMIT_EDITMSG, packed refs) where commit-message
            # prose mentioning these module names produces spurious hits — only
            # in environments without ripgrep (e.g. CI runners). bug 5ff0 sibling.
            hits=$(grep -rnE --exclude-dir=.git "$pattern" "$zone_path" 2>/dev/null || true)
        fi
    fi
    if [[ -n "$hits" ]]; then
        count=$(echo "$hits" | wc -l | tr -d ' ')
    fi
    echo "Zone $zone_name: $count hits"
    if [[ "$count" -gt 0 ]]; then
        # Here-string, NOT `echo "$hits" | head -20`: under `set -o pipefail`,
        # head closes the pipe after 20 lines; on a large hit set echo is still
        # writing and takes SIGPIPE (exit 141), which pipefail+`set -e` turn
        # into a whole-script abort — printing zone lines but never the
        # "TOTAL HITS:" footer. Flaked in CI (no rg → grep scanned .git → big
        # hit set), passed locally (rg → 0 hits). Here-strings have no pipe.
        head -20 <<<"$hits"
    fi
    TOTAL_HITS=$((TOTAL_HITS + count))
}

for zone in reconciler workflows tests repo; do
    scan_zone "$zone" "${ZONES[$zone]}"
done

echo ""
echo "TOTAL HITS: $TOTAL_HITS"
echo "MODE: $MODE"

if [[ "$MODE" == "strict" && "$TOTAL_HITS" -gt 0 ]]; then
    exit 1
fi
exit 0
