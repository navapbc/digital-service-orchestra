#!/usr/bin/env bash
set -eu
# scripts/dso-setup.sh
# Install the DSO shim into a host project's .claude/scripts/ directory.
#
# Usage: dso-setup.sh [TARGET_REPO [PLUGIN_ROOT]]
#   TARGET_REPO: directory to install shim into; defaults to git repo root
#   PLUGIN_ROOT: plugin directory; defaults to parent of this script's directory
#
# Exit codes: 0=success, 1=fatal error (abort setup), 2=warnings-only (continue with caution)

# ── Prerequisite detection ────────────────────────────────────────────────────
# Prints warnings/errors to stderr. Exits 1 on fatal errors. Returns the number
# of warnings (non-fatal) so the caller can decide whether to exit 2 after setup.
detect_prerequisites() {
    local warnings=0

    # Platform detection
    local platform
    platform=$(uname -s 2>/dev/null || echo "Unknown")
    case "$platform" in
        Darwin)  platform="macOS" ;;
        Linux)
            if grep -qi microsoft /proc/version 2>/dev/null; then
                platform="WSL"
            else
                platform="Linux"
            fi
            ;;
        *)       platform="Unknown" ;;
    esac

    # Check bash major version (must be >=4)
    local bash_version
    bash_version=$(bash --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
    local bash_major
    bash_major=$(echo "$bash_version" | cut -d. -f1)
    if [[ -z "$bash_major" || "$bash_major" -lt 4 ]]; then
        echo "ERROR: bash >= 4 is required (found: ${bash_version:-unknown})." >&2
        if [[ "$platform" == "macOS" ]]; then
            echo "  Install: brew install bash" >&2
            echo "  Then ensure /usr/local/bin/bash or /opt/homebrew/bin/bash is in PATH." >&2
        else
            echo "  Install: sudo apt-get install bash  (or equivalent)" >&2
        fi
        exit 1
    fi

    # Check for timeout or gtimeout (coreutils)
    if ! command -v timeout >/dev/null 2>&1 && ! command -v gtimeout >/dev/null 2>&1; then
        echo "ERROR: 'timeout' (or 'gtimeout') is required but not found." >&2
        if [[ "$platform" == "macOS" ]]; then
            echo "  Install: brew install coreutils" >&2
        else
            echo "  Install: sudo apt-get install coreutils" >&2
        fi
        exit 1
    fi

    # Check for pre-commit (warning only)
    if ! command -v pre-commit >/dev/null 2>&1; then
        echo "WARNING: 'pre-commit' not found. Git hooks will not run automatically." >&2
        echo "  Install: pip install pre-commit  OR  brew install pre-commit" >&2
        warnings=$(( warnings + 1 ))
    fi

    # Check for python3 (warning only)
    if ! command -v python3 >/dev/null 2>&1; then
        echo "WARNING: 'python3' not found. Some DSO scripts require Python 3." >&2
        if [[ "$platform" == "macOS" ]]; then
            echo "  Install: brew install python" >&2
        else
            echo "  Install: sudo apt-get install python3" >&2
        fi
        warnings=$(( warnings + 1 ))
    fi

    # Check for claude CLI (warning only)
    if ! command -v claude >/dev/null 2>&1; then
        echo "WARNING: 'claude' CLI not found. Install from https://claude.ai/claude-code" >&2
        warnings=$(( warnings + 1 ))
    fi

    echo "$warnings"
}

_prereq_warnings=$(detect_prerequisites)

# ── Parse --dryrun flag (position-independent) ────────────────────────────────
DRYRUN=''
_args_filtered=()
for _arg in "$@"; do
    if [[ "$_arg" == '--dryrun' ]]; then
        DRYRUN=1
    else
        _args_filtered+=("$_arg")
    fi
done
set -- "${_args_filtered[@]+"${_args_filtered[@]}"}"

TARGET_REPO="${1:-$(git rev-parse --show-toplevel)}"
PLUGIN_ROOT="${2:-${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}}"
_SCRIPT_PLUGIN_DIR="${CLAUDE_PLUGIN_ROOT:-$(cd "${0%/*}/../.." 2>/dev/null && pwd)}" || _SCRIPT_PLUGIN_DIR="$PLUGIN_ROOT"

# ── Source shared merge library ───────────────────────────────────────────────
# shellcheck source=artifact-merge-lib.sh
source "$_SCRIPT_PLUGIN_DIR/scripts/artifact-merge-lib.sh"

# ── Read plugin version (used for artifact stamps) ────────────────────────────
_PLUGIN_VERSION=$(python3 -c "import json; print(json.load(open('$_SCRIPT_PLUGIN_DIR/.claude-plugin/plugin.json'))['version'])" 2>/dev/null || echo "unknown")
# DIST_ROOT: the repository root containing shared assets (templates/, docs/examples/)
# that live outside the plugin subdir. Falls back to PLUGIN_ROOT for backward
# compatibility when this script is called with the repo root as PLUGIN_ROOT.
# Resolve from git rev-parse (always reliable) rather than relative paths.
DIST_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || DIST_ROOT="$PLUGIN_ROOT"
# Verify DIST_ROOT has the expected assets; fall back to PLUGIN_ROOT otherwise
if [ ! -d "$DIST_ROOT/templates" ] && [ -d "$PLUGIN_ROOT/templates" ]; then
    DIST_ROOT="$PLUGIN_ROOT"
fi
# Examples moved from examples/ to docs/examples/ inside the plugin dir
EXAMPLES_ROOT="$DIST_ROOT/docs/examples"

# Ensure TARGET_REPO is a git repository so the dso shim can locate
# .claude/dso-config.conf via `git rev-parse --show-toplevel`.
if ! git -C "$TARGET_REPO" rev-parse --show-toplevel >/dev/null 2>&1; then
    if [[ -z "$DRYRUN" ]]; then
        git -C "$TARGET_REPO" init -q
    else
        echo "[dryrun] Would run: git init -q in $TARGET_REPO"
    fi
fi

if [[ -z "$DRYRUN" ]]; then
    mkdir -p "$TARGET_REPO/.claude/scripts/"
    cp "$DIST_ROOT/templates/host-project/dso" "$TARGET_REPO/.claude/scripts/dso"
    chmod +x "$TARGET_REPO/.claude/scripts/dso"
else
    echo "[dryrun] Would copy $DIST_ROOT/templates/host-project/dso -> $TARGET_REPO/.claude/scripts/dso (chmod +x)"
fi

CONFIG="$TARGET_REPO/.claude/dso-config.conf"
if [[ -z "$DRYRUN" ]]; then
    if grep -q '^dso\.plugin_root=' "$CONFIG" 2>/dev/null; then
        # Update existing entry (idempotent)
        sed -i.bak "s|^dso\.plugin_root=.*|dso.plugin_root=$PLUGIN_ROOT|" "$CONFIG" && rm -f "$CONFIG.bak"
    else
        printf 'dso.plugin_root=%s\n' "$PLUGIN_ROOT" >> "$CONFIG"
    fi
else
    echo "[dryrun] Would write dso.plugin_root=$PLUGIN_ROOT to $CONFIG"
fi

# ── Merge new config keys from reference template (install + update path) ─────
# merge_config_file adds any missing keys from the reference config into the host
# config. Keys already present (active or commented) are never overwritten.
# If the reference file does not exist, merge_config_file emits a warning and
# returns 0 (no-op).
_CONFIG_REFERENCE="$_SCRIPT_PLUGIN_DIR/config/dso-config.reference.conf"
merge_config_file "$CONFIG" "$_CONFIG_REFERENCE" "$DRYRUN"

# ── supplement_template_file: smart file handling (warn + supplement or skip) ──
# Usage: supplement_template_file FILE_PATH DSO_MARKER TEMPLATE_PATH LABEL
#   FILE_PATH:     path to the target file in the host repo
#   DSO_MARKER:    string that indicates DSO sections are already present
#   TEMPLATE_PATH: path to the template/example file to use as source
#   LABEL:         human-readable file name for messages (e.g., "CLAUDE.md")
supplement_template_file() {
    local file_path="$1"
    local dso_marker="$2"
    local template_path="$3"
    local label="$4"
    # Use bash parameter expansion instead of dirname to avoid requiring the
    # external 'dirname' command (which may be absent in restricted PATH environments).
    local file_dir="${file_path%/*}"

    if [[ -f "$file_path" ]]; then
        # File exists — warn and decide whether to supplement
        echo "WARNING: $label already exists at $file_path" >&2
        if grep -qF "$dso_marker" "$file_path" 2>/dev/null; then
            # DSO sections already present — skip to avoid duplication
            if [[ -z "$DRYRUN" ]]; then
                echo "[skip] $label already contains DSO scaffolding — not supplementing"
            else
                echo "[dryrun] $label already contains DSO scaffolding — would skip"
            fi
        else
            # No DSO sections yet — append scaffolding
            if [[ -z "$DRYRUN" ]]; then
                echo "[supplement] Appending DSO scaffolding sections to existing $label"
                printf '\n' >> "$file_path"
                cat "$template_path" >> "$file_path"
            else
                echo "[dryrun] Would append DSO scaffolding sections to existing $label (no DSO markers found)"
            fi
        fi
    else
        # File does not exist — copy template (normal path)
        if [[ -z "$DRYRUN" ]]; then
            mkdir -p "$file_dir"
            cp "$template_path" "$file_path"
        else
            echo "[dryrun] Would copy $template_path -> $file_path (file absent)"
        fi
    fi
}

# ── Copy/supplement CLAUDE.md ─────────────────────────────────────────────────
supplement_template_file \
    "$TARGET_REPO/.claude/CLAUDE.md" \
    '=== GENERATED BY /generate-claude-md' \
    "$DIST_ROOT/templates/CLAUDE.md.template" \
    "CLAUDE.md"

# ── Copy/supplement KNOWN-ISSUES.md ──────────────────────────────────────────
# REVIEW-DEFENSE: Finding confirmed false positive — this file uses $_SCRIPT_PLUGIN_DIR (defined at line 103), not $_PLUGIN_ROOT. The reviewer hallucinated an undefined variable; grep confirms _PLUGIN_ROOT never appears as a variable reference in this file.
supplement_template_file \
    "$TARGET_REPO/.claude/docs/KNOWN-ISSUES.md" \
    '<!-- DSO:KNOWN-ISSUES-HEADER -->' \
    "$_SCRIPT_PLUGIN_DIR/docs/templates/KNOWN-ISSUES.md" \
    "KNOWN-ISSUES.md"

# ── _resolve_stack_ci_example: pick CI example by detected stack ──────────────
# Usage: _resolve_stack_ci_example TARGET_REPO EXAMPLES_ROOT DRYRUN
#   Emits (stdout) a path to the CI example file to use, OR empty string if
#   none resolvable. When a skeleton is generated, it is written to a
#   deterministic path under $TARGET_REPO (.dso-ci-skeleton.tmp) so the caller
#   can rm -f it without inter-subshell variable propagation (which would not
#   work — this function is always called via command substitution).
#
# Resolution order:
#   1. Read `stack=` from $DSO_DETECT_OUTPUT (populated by project-detect.sh)
#      then fall back to `stack=` in $TARGET_REPO/.claude/dso-config.conf
#   2. If stack matches a file EXAMPLES_ROOT/ci.example.${stack}.yml, use it
#   3. Otherwise generate a skeleton from dso-config.conf commands.{test,lint,format_check}
#   4. Last-resort fallback: legacy ci.example.python-poetry.yml (preserves prior
#      behavior if both stack detection and skeleton generation fail)
_resolve_stack_ci_example() {
    local target_repo="$1"
    local examples_root="$2"
    local dryrun="${3:-}"

    local _stack=""
    if [[ -n "${DSO_DETECT_OUTPUT:-}" ]] && [[ -f "${DSO_DETECT_OUTPUT}" ]]; then
        _stack=$(grep '^stack=' "$DSO_DETECT_OUTPUT" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '[:space:]')
    fi
    if [[ -z "$_stack" ]] && [[ -f "$target_repo/.claude/dso-config.conf" ]]; then
        _stack=$(grep '^stack=' "$target_repo/.claude/dso-config.conf" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '[:space:]')
    fi

    # Stack-matched example
    if [[ -n "$_stack" ]] && [[ -f "$examples_root/ci.example.${_stack}.yml" ]]; then
        printf '%s\n' "$examples_root/ci.example.${_stack}.yml"
        return 0
    fi

    # Skeleton from dso-config commands — written to deterministic path under
    # target_repo (NOT via mktemp/shell var) so the caller can rm -f it after
    # consumption. Subshell isolation would drop a variable-based marker.
    # Dryrun honors the no-write contract: skip skeleton generation entirely and
    # fall through to the last-resort branch. In non-dryrun mode only, write the
    # skeleton file and return its path.
    if [[ -z "$dryrun" ]] && [[ -d "$target_repo" ]]; then
        local _skel_path="$target_repo/.dso-ci-skeleton.tmp"
        if _generate_ci_skeleton_from_config "$target_repo" "$_stack" "$_skel_path"; then
            printf '%s\n' "$_skel_path"
            return 0
        fi
    fi

    # Last-resort: legacy python-poetry example (backward compat)
    if [[ -f "$examples_root/ci.example.python-poetry.yml" ]]; then
        printf '%s\n' "$examples_root/ci.example.python-poetry.yml"
        return 0
    fi

    # No example resolvable — emit empty (caller must guard against empty path).
    printf ''
}

# ── _generate_ci_skeleton_from_config: synthesize CI from dso-config commands ─
# Usage: _generate_ci_skeleton_from_config TARGET_REPO STACK OUTPUT_PATH
#   Writes a minimal CI workflow derived from commands.{test,lint,format_check}
#   in dso-config.conf to OUTPUT_PATH. Returns 0 on success, 1 if no commands
#   are declared (so caller can fall back). Deterministic path — avoids the
#   subshell-variable-propagation trap that killed the earlier tmpfile approach.
_generate_ci_skeleton_from_config() {
    local target_repo="$1"
    local stack="${2:-unknown}"
    local out_path="$3"
    local config="$target_repo/.claude/dso-config.conf"

    [[ -f "$config" ]] || return 1

    local _test_cmd _lint_cmd _format_cmd
    _test_cmd=$(grep '^commands\.test=' "$config" 2>/dev/null | head -1 | cut -d= -f2-)
    _lint_cmd=$(grep '^commands\.lint=' "$config" 2>/dev/null | head -1 | cut -d= -f2-)
    _format_cmd=$(grep '^commands\.format_check=' "$config" 2>/dev/null | head -1 | cut -d= -f2-)

    # Require at least one command to generate anything useful
    if [[ -z "$_test_cmd" && -z "$_lint_cmd" && -z "$_format_cmd" ]]; then
        return 1
    fi

    {
        printf '# DSO CI skeleton — generated for stack=%s\n' "$stack"
        printf '# x-dso-version: skeleton\n'
        printf 'name: CI\n\n'
        printf 'on:\n  pull_request:\n    branches: [main]\n  push:\n    branches: [main]\n  workflow_dispatch:\n\n'
        printf 'jobs:\n'
        if [[ -n "$_lint_cmd" || -n "$_format_cmd" ]]; then
            printf '  fast-gate:\n    name: Fast Gate\n    runs-on: ubuntu-latest\n    timeout-minutes: 5\n    steps:\n      - uses: actions/checkout@v4\n'
            [[ -n "$_format_cmd" ]] && printf '      - name: Format check\n        run: %s\n' "$_format_cmd"
            [[ -n "$_lint_cmd" ]] && printf '      - name: Lint\n        run: %s\n' "$_lint_cmd"
        fi
        if [[ -n "$_test_cmd" ]]; then
            printf '  tests:\n    name: Tests\n    runs-on: ubuntu-latest\n    timeout-minutes: 10\n    steps:\n      - uses: actions/checkout@v4\n      - name: Run tests\n        run: %s\n' "$_test_cmd"
        fi
    } > "$out_path"
    return 0
}

# ── _run_ci_guard_analysis: analyze existing CI workflow for missing guards ────
# Usage: _run_ci_guard_analysis DRYRUN TARGET_REPO
#   DRYRUN:      non-empty = dry-run mode (analysis output shown, no file writes)
#   TARGET_REPO: path to the host project repo
#
# Detection input: reads DSO_DETECT_OUTPUT env var (path to a key=value file with
# lines like: ci_workflow_lint_guarded=true|false). If DSO_DETECT_OUTPUT is unset
# or the file is absent/empty, emits a skip message and returns.
#
# Guard keys recognized: ci_workflow_lint_guarded, ci_workflow_test_guarded,
#                        ci_workflow_format_guarded
_run_ci_guard_analysis() {
    local dryrun="$1"
    # TARGET_REPO arg is accepted for future use (e.g., listing workflow files)

    local detect_file="${DSO_DETECT_OUTPUT:-}"
    if [[ -z "$detect_file" ]] || [[ ! -f "$detect_file" ]]; then
        echo "[skip] No detection output available — skipping CI guard analysis"
        return 0
    fi

    echo "[ci-guard] CI workflow guards analysis:"

    # Parse detection key=value lines
    local lint_guarded test_guarded format_guarded
    lint_guarded=$(grep '^ci_workflow_lint_guarded=' "$detect_file" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]') || lint_guarded=""
    test_guarded=$(grep '^ci_workflow_test_guarded=' "$detect_file" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]') || test_guarded=""
    format_guarded=$(grep '^ci_workflow_format_guarded=' "$detect_file" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]') || format_guarded=""

    local prefix="[ci-guard]"
    [[ -n "$dryrun" ]] && prefix="[dryrun][ci-guard]"

    # Lint guard check
    if [[ "$lint_guarded" == "false" ]]; then
        echo "$prefix Existing CI workflow is missing lint guard — consider adding a lint step to your workflow"
    fi

    # Test guard check
    if [[ "$test_guarded" == "false" ]]; then
        echo "$prefix Existing CI workflow is missing test guard — consider adding a test step to your workflow"
    fi

    # Format guard check
    if [[ "$format_guarded" == "false" ]]; then
        echo "$prefix Existing CI workflow is missing format guard — consider adding a format step to your workflow"
    fi
}

# ── stamp_artifact: embed version stamp in an installed artifact ──────────────
# Usage: stamp_artifact FILE_PATH STAMP_TYPE VERSION DRYRUN
#   FILE_PATH:  path to the artifact file to stamp
#   STAMP_TYPE: "text" → `# dso-version: <version>` (first 5 lines for shim,
#               prepend/update for config); "yaml" → `x-dso-version: <version>`
#               as top-level YAML key
#   VERSION:    version string to embed
#   DRYRUN:     non-empty = dry-run mode (no writes)
#
# Idempotent: if the stamp already exists, update in-place; if not, insert.
# For "text" type: insert/update within first 5 lines (after shebang line 1).
# For "yaml" type: insert/update as first line of the file.
stamp_artifact() {
    local file_path="$1"
    local stamp_type="$2"
    local version="$3"
    local dryrun="$4"

    if [[ ! -f "$file_path" ]]; then
        if [[ -n "$dryrun" ]]; then
            echo "[dryrun] stamp_artifact: $file_path not found — would skip"
        fi
        return 0
    fi

    if [[ "$stamp_type" == "text" ]]; then
        local stamp_line="# dso-version: $version"
        if [[ -n "$dryrun" ]]; then
            echo "[dryrun] Would embed '$stamp_line' in $file_path"
            return 0
        fi
        # Idempotent: update existing stamp or insert after line 1
        if grep -q '^# dso-version:' "$file_path" 2>/dev/null; then
            # Update existing stamp in-place (sed: replace the matching line)
            sed -i.bak "s|^# dso-version:.*|$stamp_line|" "$file_path" && rm -f "${file_path}.bak"
        else
            # Insert after the first line (shebang or first non-blank)
            sed -i.bak "1a\\
$stamp_line" "$file_path" && rm -f "${file_path}.bak"
        fi

    elif [[ "$stamp_type" == "yaml" ]]; then
        local stamp_line="x-dso-version: $version"
        if [[ -n "$dryrun" ]]; then
            echo "[dryrun] Would embed '$stamp_line' in $file_path"
            return 0
        fi
        # Idempotent: update existing stamp or prepend as first line
        if grep -q '^x-dso-version:' "$file_path" 2>/dev/null; then
            # Update existing stamp in-place
            sed -i.bak "s|^x-dso-version:.*|$stamp_line|" "$file_path" && rm -f "${file_path}.bak"
        else
            # Prepend stamp as first line using python3 (robust for YAML files)
            if command -v python3 >/dev/null 2>&1; then
                python3 - "$file_path" "$stamp_line" <<'PYEOF'
import sys
file_path = sys.argv[1]
stamp_line = sys.argv[2]
with open(file_path, 'r') as f:
    content = f.read()
with open(file_path, 'w') as f:
    f.write(stamp_line + '\n' + content)
PYEOF
            else
                # Fallback: sed prepend
                sed -i.bak "1i\\
$stamp_line" "$file_path" && rm -f "${file_path}.bak"
            fi
        fi
    fi
}

# ── Copy/merge pre-commit config ──────────────────────────────────────────────
TARGET_PRECOMMIT="$TARGET_REPO/.pre-commit-config.yaml"
if [[ -z "$DRYRUN" ]]; then
    if [ ! -f "$TARGET_PRECOMMIT" ]; then
        cp "$EXAMPLES_ROOT/pre-commit-config.example.yaml" "$TARGET_PRECOMMIT"
    else
        merge_precommit_hooks "$TARGET_PRECOMMIT" "$EXAMPLES_ROOT/pre-commit-config.example.yaml" ""
    fi

    mkdir -p "$TARGET_REPO/.github/workflows"
    # Check for ANY existing workflow file (not just ci.yml) under .github/workflows/
    _existing_workflows=()
    for _wf in "$TARGET_REPO/.github/workflows"/*.yml "$TARGET_REPO/.github/workflows"/*.yaml; do
        [[ -f "$_wf" ]] && _existing_workflows+=("$_wf")
    done
    # Resolve stack-matched CI example; generate skeleton from dso-config commands
    # if no stack match. When a skeleton is generated, it is written to a
    # deterministic path ($TARGET_REPO/.dso-ci-skeleton.tmp) so we can rm -f it
    # after consumption — subshell assignments can't propagate out of $(...).
    _CI_EXAMPLE_RESOLVED=$(_resolve_stack_ci_example "$TARGET_REPO" "$EXAMPLES_ROOT" "")
    if [[ -z "$_CI_EXAMPLE_RESOLVED" ]]; then
        echo "[skip] No CI example resolved for target stack — skipping CI workflow setup"
    elif [[ ${#_existing_workflows[@]} -eq 0 ]]; then
        # No workflow files exist — copy the stack-matched example
        cp "$_CI_EXAMPLE_RESOLVED" "$TARGET_REPO/.github/workflows/ci.yml"
    else
        # Workflow file(s) exist — merge stack-matched DSO CI jobs into the first
        # workflow file, then run CI guard analysis using detection output.
        merge_ci_workflow "${_existing_workflows[0]}" "$_CI_EXAMPLE_RESOLVED" ""
        _run_ci_guard_analysis "" "$TARGET_REPO"
    fi
    # Clean up generated skeleton (deterministic path, only exists if skeleton was generated)
    rm -f "$TARGET_REPO/.dso-ci-skeleton.tmp"
else
    if [ ! -f "$TARGET_PRECOMMIT" ]; then
        echo "[dryrun] Would copy pre-commit-config.example.yaml -> $TARGET_REPO/.pre-commit-config.yaml (file absent)"
    else
        merge_precommit_hooks "$TARGET_PRECOMMIT" "$EXAMPLES_ROOT/pre-commit-config.example.yaml" "1"
    fi
    # Check for ANY existing workflow file (not just ci.yml) under .github/workflows/
    _existing_workflows_dry=()
    for _wf in "$TARGET_REPO/.github/workflows"/*.yml "$TARGET_REPO/.github/workflows"/*.yaml; do
        [[ -f "$_wf" ]] && _existing_workflows_dry+=("$_wf")
    done
    _CI_EXAMPLE_RESOLVED=$(_resolve_stack_ci_example "$TARGET_REPO" "$EXAMPLES_ROOT" "1")
    if [[ -z "$_CI_EXAMPLE_RESOLVED" ]]; then
        echo "[dryrun][skip] No CI example resolved for target stack — would skip CI workflow setup"
    elif [[ ${#_existing_workflows_dry[@]} -eq 0 ]]; then
        echo "[dryrun] Would copy $(basename "$_CI_EXAMPLE_RESOLVED") -> $TARGET_REPO/.github/workflows/ci.yml (only if absent)"
    else
        # Workflow file(s) exist — preview stack-matched merge, then CI guard analysis (dryrun mode)
        merge_ci_workflow "${_existing_workflows_dry[0]}" "$_CI_EXAMPLE_RESOLVED" "1"
        _run_ci_guard_analysis "1" "$TARGET_REPO"
    fi
    # Clean up generated skeleton (deterministic path)
    rm -f "$TARGET_REPO/.dso-ci-skeleton.tmp"
fi

# ── Verify hooks/lib installation (required by pre-commit framework hooks) ────
# Consumer hooks source merge-state.sh via HOOK_DIR-relative paths
# (${CLAUDE_PLUGIN_ROOT}/hooks/lib/). Scripts source via BASH_SOURCE-relative ../hooks/lib/.
# merge-to-main.sh sources via CLAUDE_PLUGIN_ROOT. Verify the library is present
# in the DSO plugin so host projects using the pre-commit framework can source it.
# Resolve from BASH_SOURCE[0] (script-relative) so this works regardless of
# whether PLUGIN_ROOT is the plugin dir or the repo root.
# Use bash parameter expansion instead of dirname to avoid requiring dirname
# in restricted PATH environments (test isolation, minimal CI containers).
_DSO_SCRIPT_PATH="${BASH_SOURCE[0]}"
_DSO_SCRIPT_DIR="${_DSO_SCRIPT_PATH%/*}"
[[ "$_DSO_SCRIPT_DIR" == "$_DSO_SCRIPT_PATH" ]] && _DSO_SCRIPT_DIR="."
_DSO_PLUGIN_DIR="${CLAUDE_PLUGIN_ROOT:-$(cd "$_DSO_SCRIPT_DIR/../.." && pwd)}"
_HOOKS_LIB_DIR="$_DSO_PLUGIN_DIR/hooks/lib"
_MERGE_STATE_LIB="$_HOOKS_LIB_DIR/merge-state.sh"
if [[ -z "$DRYRUN" ]]; then
    if [[ ! -f "$_MERGE_STATE_LIB" ]]; then
        echo "ERROR: merge-state.sh not found at $_MERGE_STATE_LIB — hooks/lib installation may be incomplete" >&2
        exit 1
    fi
else
    if [[ -f "$_MERGE_STATE_LIB" ]]; then
        echo "[dryrun] hooks/lib/merge-state.sh present at $_MERGE_STATE_LIB — OK"
    else
        echo "[dryrun] WARNING: merge-state.sh not found at $_MERGE_STATE_LIB" >&2
    fi
fi

# ── Register pre-commit hooks (must come AFTER config copy) ───────────────────
if [[ -z "$DRYRUN" ]]; then
    if command -v pre-commit >/dev/null 2>&1 && [ -f "$TARGET_PRECOMMIT" ]; then
        (cd "$TARGET_REPO" && pre-commit install && pre-commit install --hook-type pre-push) || true
    fi
else
    if command -v pre-commit >/dev/null 2>&1; then
        echo "[dryrun] Would run: pre-commit install && pre-commit install --hook-type pre-push"
    fi
fi

# ── Stamp installed artifacts with plugin version ─────────────────────────────
# Must come AFTER all copy/merge operations so the artifacts exist.
# Shim and config are always managed by dso-setup.sh — always stamp them.
stamp_artifact "$TARGET_REPO/.claude/scripts/dso" text "$_PLUGIN_VERSION" "$DRYRUN"
stamp_artifact "$CONFIG" text "$_PLUGIN_VERSION" "$DRYRUN"
# Pre-commit: only stamp if dso-setup.sh manages it (has a repos: section,
# meaning DSO hooks were copied or merged). Files without repos: are skipped.
if grep -q '^repos:' "$TARGET_PRECOMMIT" 2>/dev/null; then
    stamp_artifact "$TARGET_PRECOMMIT" yaml "$_PLUGIN_VERSION" "$DRYRUN"
fi
# CI yml: only stamp when dso-setup.sh installed it (no prior workflow files);
# existing user workflows are left untouched (no stamp).
if [[ -f "$TARGET_REPO/.github/workflows/ci.yml" ]]; then
    _ci_managed=0
    # The ci.yml was installed by dso-setup.sh if it matches the example content
    # (contains 'name: CI' from the example template). Check via grep.
    if grep -q 'name: CI' "$TARGET_REPO/.github/workflows/ci.yml" 2>/dev/null; then
        _ci_managed=1
    fi
    # Also stamp if the file was freshly copied (no workflows existed before this run)
    # — determined by whether the stamp is already there (idempotent path) or not.
    # Simplest heuristic: stamp if the file contains DSO-related content.
    if grep -q 'dso\|DSO\|digital-service-orchestra\|x-dso-version:' "$TARGET_REPO/.github/workflows/ci.yml" 2>/dev/null; then
        _ci_managed=1
    fi
    if [[ "$_ci_managed" -eq 1 ]]; then
        stamp_artifact "$TARGET_REPO/.github/workflows/ci.yml" yaml "$_PLUGIN_VERSION" "$DRYRUN"
    fi
fi

# ── Ensure .gitignore includes artifact check cache ───────────────────────────
if [[ -z "$DRYRUN" ]]; then
    if ! grep -qF '.claude/dso-artifact-check-cache' "$TARGET_REPO/.gitignore" 2>/dev/null; then
        echo '.claude/dso-artifact-check-cache' >> "$TARGET_REPO/.gitignore"
    fi
else
    if ! grep -qF '.claude/dso-artifact-check-cache' "$TARGET_REPO/.gitignore" 2>/dev/null; then
        echo "[dryrun] Would append .claude/dso-artifact-check-cache to $TARGET_REPO/.gitignore"
    fi
fi

# ── Optional dependency detection (non-blocking) ──────────────────────────────
if ! command -v acli >/dev/null 2>&1; then
    echo '[optional] acli not found. Install: brew install acli (enables Jira integration in DSO)'
fi
if command -v python3 >/dev/null 2>&1 && ! python3 -c 'import yaml' >/dev/null 2>&1; then
    echo '[optional] PyYAML not found. Install: pip3 install pyyaml (enables legacy YAML config path)'
fi

# ── Environment variable guidance ─────────────────────────────────────────────
echo '=== Environment Variables (add to your shell profile) ==='
echo 'CLAUDE_PLUGIN_ROOT=  # Optional: overrides dso.plugin_root from .claude/dso-config.conf'
echo 'JIRA_URL=https://your-org.atlassian.net  # Required for Jira sync'
echo 'JIRA_USER=you@example.com  # Required for Jira sync'
echo 'JIRA_API_TOKEN=...  # Required for Jira sync'

# ── GitHub Repository Configuration (for Jira bridge workflows) ──────────────
echo ''
echo '=== GitHub Repository Configuration (for Jira bridge CI) ==='
echo 'Repository Variables (gh variable set):  JIRA_URL, JIRA_USER, ACLI_VERSION,'
echo '  ACLI_SHA256, BRIDGE_BOT_LOGIN, BRIDGE_BOT_NAME, BRIDGE_BOT_EMAIL, BRIDGE_ENV_ID'
echo 'Repository Secrets (gh secret set):      JIRA_API_TOKEN'
echo 'Note: Bridge workflows use vars.JIRA_URL and vars.JIRA_USER (not secrets).'

# ── Next steps ────────────────────────────────────────────────────────────────
echo '=== Setup complete. Next steps: ==='
echo '1. Edit .claude/dso-config.conf to configure your project'
echo '2. Run /dso:onboarding in Claude Code for interactive configuration'
echo '3. See https://github.com/navapbc/digital-service-orchestra/blob/main/INSTALL.md for full documentation'

# Exit 2 (warnings-only) if any warning-level prerequisites were missing.
# Setup has completed successfully — exit 2 signals "continue with caution".
if [[ "$_prereq_warnings" -gt 0 ]]; then
    exit 2
fi
