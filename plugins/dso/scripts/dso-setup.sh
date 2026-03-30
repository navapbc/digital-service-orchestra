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
PLUGIN_ROOT="${2:-$(cd "$(dirname "$0")/.." && pwd)}"
# DIST_ROOT: the repository root containing shared assets (templates/, examples/)
# that live outside the plugin subdir. Falls back to PLUGIN_ROOT for backward
# compatibility when this script is called with the repo root as PLUGIN_ROOT.
# Resolve from git rev-parse (always reliable) rather than relative paths.
DIST_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || DIST_ROOT="$PLUGIN_ROOT"
# Verify DIST_ROOT has the expected assets; fall back to PLUGIN_ROOT otherwise
if [ ! -d "$DIST_ROOT/templates" ] && [ -d "$PLUGIN_ROOT/templates" ]; then
    DIST_ROOT="$PLUGIN_ROOT"
fi

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
supplement_template_file \
    "$TARGET_REPO/.claude/docs/KNOWN-ISSUES.md" \
    '<!-- DSO:KNOWN-ISSUES-HEADER -->' \
    "$DIST_ROOT/plugins/dso/docs/templates/KNOWN-ISSUES.md" \
    "KNOWN-ISSUES.md"

# ── merge_precommit_hooks: merge DSO hooks into existing .pre-commit-config.yaml ──
# Usage: merge_precommit_hooks TARGET_FILE EXAMPLE_FILE DRYRUN
#   TARGET_FILE:  path to the host project's .pre-commit-config.yaml
#   EXAMPLE_FILE: path to DSO's example pre-commit config
#   DRYRUN:       non-empty = dry-run mode (no writes)
#
# Strategy: append-repos — add a new DSO 'local' repo block to the repos: list.
# The existing file's content (including other repo blocks) is fully preserved.
# Idempotent: if DSO hook ids are already present, they are not duplicated.
#
# Implementation: try python3+PyYAML first for robust YAML handling; fall back
# to awk-based block extraction and text append if PyYAML is unavailable.
merge_precommit_hooks() {
    local target_file="$1"
    local example_file="$2"
    local dryrun="$3"

    # Guard: only merge if the target file has a 'repos:' section (i.e., is a
    # recognizable pre-commit config). Files without 'repos:' are left untouched.
    if ! grep -q '^repos:' "$target_file" 2>/dev/null; then
        echo "WARNING: .pre-commit-config.yaml exists but has no 'repos:' section — skipping merge" >&2
        return 0
    fi

    # Extract DSO hook ids from the example file (hooks under the local repo block)
    local dso_hook_ids
    dso_hook_ids=$(python3 - "$example_file" 2>/dev/null <<'PYEOF'
import sys, yaml
try:
    with open(sys.argv[1]) as f:
        cfg = yaml.safe_load(f)
    ids = []
    for repo in cfg.get('repos', []):
        if repo.get('repo') == 'local':
            for hook in repo.get('hooks', []):
                ids.append(hook['id'])
    print('\n'.join(ids))
except Exception:
    sys.exit(1)
PYEOF
) || dso_hook_ids=""

    # Fallback: extract hook ids using grep if python3/PyYAML unavailable
    if [[ -z "$dso_hook_ids" ]]; then
        dso_hook_ids=$(grep -E '^\s+- id:' "$example_file" 2>/dev/null | sed 's/.*- id: *//' | tr -d ' ')
    fi

    if [[ -z "$dso_hook_ids" ]]; then
        echo "WARNING: Could not extract DSO hook ids from $example_file — skipping merge" >&2
        return 0
    fi

    # Check which DSO hook ids are already present in the target file
    local hooks_to_add=()
    while IFS= read -r hook_id; do
        [[ -z "$hook_id" ]] && continue
        if ! grep -qF "id: $hook_id" "$target_file" 2>/dev/null; then
            hooks_to_add+=("$hook_id")
        fi
    done <<< "$dso_hook_ids"

    if [[ ${#hooks_to_add[@]} -eq 0 ]]; then
        # All DSO hooks already present — nothing to do
        if [[ -n "$dryrun" ]]; then
            echo "[dryrun] .pre-commit-config.yaml: all DSO hooks already present — no merge needed"
        else
            echo "[skip] .pre-commit-config.yaml: all DSO hooks already present — not merging"
        fi
        return 0
    fi

    # Build the DSO hook block to append: extract the DSO 'local' repo block
    # from the example file containing only the hooks that need to be added.
    # Output format: a valid YAML repos: sequence entry with 2-space indent
    # (matching the existing repos: list indentation: '  - repo: local').
    local dso_block
    dso_block=$(python3 - "$example_file" "${hooks_to_add[@]}" 2>/dev/null <<'PYEOF'
import sys, yaml

example_file = sys.argv[1]
needed_ids = set(sys.argv[2:])

try:
    with open(example_file) as f:
        cfg = yaml.safe_load(f)
    hooks = []
    for repo in cfg.get('repos', []):
        if repo.get('repo') == 'local':
            for hook in repo.get('hooks', []):
                if hook['id'] in needed_ids:
                    hooks.append(hook)

    if not hooks:
        sys.exit(1)

    new_block = {'repo': 'local', 'hooks': hooks}
    # Dump just the block dict with 2-space indent
    block_yaml = yaml.dump(new_block, default_flow_style=False,
                           allow_unicode=True, sort_keys=False, indent=2)
    lines = block_yaml.rstrip('\n').splitlines()
    # Format as a repos: sequence entry with 2-space outer indent:
    # first line: '  - repo: local', subsequent lines: '    <content>'
    result_lines = []
    for i, line in enumerate(lines):
        if i == 0:
            result_lines.append('  - ' + line)
        else:
            result_lines.append('    ' + line)
    print('\n'.join(result_lines))
except Exception as e:
    sys.exit(1)
PYEOF
) || dso_block=""

    # Fallback: if python3/PyYAML unavailable, extract the 'local' repo block directly
    # from the example file using awk. The example uses '  - repo: local' (2-space indent).
    if [[ -z "$dso_block" ]]; then
        local full_block
        full_block=$(awk '
            /^  - repo: local/{found=1; print; next}
            found && /^  - repo:/{exit}
            found{print}
        ' "$example_file" 2>/dev/null)
        if [[ -n "$full_block" ]]; then
            dso_block="$full_block"
        fi
    fi

    if [[ -z "$dso_block" ]]; then
        echo "WARNING: Could not extract DSO hook block from $example_file — skipping merge" >&2
        return 0
    fi

    local hooks_list
    hooks_list=$(IFS=', '; echo "${hooks_to_add[*]}")

    if [[ -n "$dryrun" ]]; then
        echo "[dryrun] Would merge DSO hooks into .pre-commit-config.yaml: $hooks_list"
        echo "[dryrun] Would append a new DSO local repo block containing: $hooks_list"
        return 0
    fi

    # Append the DSO block to the repos: list in the target file.
    # The block is formatted as '  - repo: local' (2-space indent) to match the
    # standard pre-commit-config.yaml repos: sequence indentation.
    printf '\n  # DSO plugin hooks (added by dso-setup.sh — do not remove)\n' >> "$target_file"
    printf '%s\n' "$dso_block" >> "$target_file"
    echo "[merge] Appended DSO hooks to .pre-commit-config.yaml: $hooks_list"
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

# ── Copy/merge pre-commit config ──────────────────────────────────────────────
TARGET_PRECOMMIT="$TARGET_REPO/.pre-commit-config.yaml"
if [[ -z "$DRYRUN" ]]; then
    if [ ! -f "$TARGET_PRECOMMIT" ]; then
        cp "$DIST_ROOT/examples/pre-commit-config.example.yaml" "$TARGET_PRECOMMIT"
    else
        merge_precommit_hooks "$TARGET_PRECOMMIT" "$DIST_ROOT/examples/pre-commit-config.example.yaml" ""
    fi

    mkdir -p "$TARGET_REPO/.github/workflows"
    # Check for ANY existing workflow file (not just ci.yml) under .github/workflows/
    _existing_workflows=()
    for _wf in "$TARGET_REPO/.github/workflows"/*.yml "$TARGET_REPO/.github/workflows"/*.yaml; do
        [[ -f "$_wf" ]] && _existing_workflows+=("$_wf")
    done
    if [[ ${#_existing_workflows[@]} -eq 0 ]]; then
        # No workflow files exist — copy the example (original behavior)
        cp "$DIST_ROOT/examples/ci.example.yml" "$TARGET_REPO/.github/workflows/ci.yml"
    else
        # Workflow file(s) exist — run CI guard analysis using detection output
        _run_ci_guard_analysis "" "$TARGET_REPO"
    fi
else
    if [ ! -f "$TARGET_PRECOMMIT" ]; then
        echo "[dryrun] Would copy pre-commit-config.example.yaml -> $TARGET_REPO/.pre-commit-config.yaml (file absent)"
    else
        merge_precommit_hooks "$TARGET_PRECOMMIT" "$DIST_ROOT/examples/pre-commit-config.example.yaml" "1"
    fi
    # Check for ANY existing workflow file (not just ci.yml) under .github/workflows/
    _existing_workflows_dry=()
    for _wf in "$TARGET_REPO/.github/workflows"/*.yml "$TARGET_REPO/.github/workflows"/*.yaml; do
        [[ -f "$_wf" ]] && _existing_workflows_dry+=("$_wf")
    done
    if [[ ${#_existing_workflows_dry[@]} -eq 0 ]]; then
        echo "[dryrun] Would copy ci.example.yml -> $TARGET_REPO/.github/workflows/ci.yml (only if absent)"
    else
        # Workflow file(s) exist — run CI guard analysis (dryrun mode)
        _run_ci_guard_analysis "1" "$TARGET_REPO"
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
echo '2. Run /dso:init in Claude Code (dso project-setup interactive configuration)'
echo '3. See docs/INSTALL.md for full documentation'

# Exit 2 (warnings-only) if any warning-level prerequisites were missing.
# Setup has completed successfully — exit 2 signals "continue with caution".
if [[ "$_prereq_warnings" -gt 0 ]]; then
    exit 2
fi
