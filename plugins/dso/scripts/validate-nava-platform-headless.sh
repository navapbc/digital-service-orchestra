#!/usr/bin/env bash
# plugins/dso/scripts/validate-nava-platform-headless.sh
# Headless validation of nava-platform templates.
#
# Usage:
#   validate-nava-platform-headless.sh [OPTIONS] [template ...]
#
# Options:
#   --help                 Show this usage message and exit 0
#   --list-flags <tmpl>    Print required --data flags for a template and exit 0
#   --copier-yml <path>    Path to copier.yml (used by --list-flags; default: copier.yml)
#   --data KEY=VALUE       Pass a --data flag to nava-platform (repeatable)
#
# Environment:
#   NAVA_TIMEOUT   Seconds before subprocess calls time out (default: 120)
#
# Templates (positional args):
#   Default: nextjs flask rails
#
# Exit codes:
#   0   All templates validated successfully
#   1   Dependency missing, install error, or one or more templates failed
#   124 A subprocess timed out
#
# Examples:
#   validate-nava-platform-headless.sh
#   validate-nava-platform-headless.sh nextjs
#   validate-nava-platform-headless.sh --list-flags nextjs --copier-yml path/to/copier.yml

set -euo pipefail

# ── Constants ──────────────────────────────────────────────────────────────────
NAVA_TIMEOUT="${NAVA_TIMEOUT:-120}"
NAVA_GITHUB_REPO="navapbc/platform-cli"
DEFAULT_TEMPLATES=(nextjs flask rails)

# ── Timeout helper ─────────────────────────────────────────────────────────────
# run_with_timeout <seconds> <cmd> [args...]
# Runs <cmd> with a timeout. Exits 124 if the command times out.
# Works on macOS (no GNU timeout) and Linux by using python3.
# python3 is available at /usr/bin/python3 on macOS and most Linux distros.
run_with_timeout() {
    local secs="$1"
    shift
    # Use GNU timeout if available on PATH, otherwise fall back to python3.
    if command -v timeout &>/dev/null; then
        timeout "$secs" "$@"
        return $?
    elif command -v gtimeout &>/dev/null; then
        gtimeout "$secs" "$@"
        return $?
    else
        # python3 fallback — available at /usr/bin/python3 on macOS
        /usr/bin/python3 - "$secs" "$@" <<'PYEOF'
import sys, subprocess, os, signal

secs = int(sys.argv[1])
cmd  = sys.argv[2:]

try:
    proc = subprocess.run(cmd, timeout=secs, stdin=open(os.devnull))
    sys.exit(proc.returncode)
except subprocess.TimeoutExpired:
    sys.exit(124)
except FileNotFoundError:
    sys.exit(127)
PYEOF
        return $?
    fi
}

# ── Helpers ────────────────────────────────────────────────────────────────────

usage() {
    cat <<EOF
Usage: validate-nava-platform-headless.sh [OPTIONS] [template ...]

Headless validation of nava-platform templates.

Options:
  --help                 Show this usage message and exit 0
  --list-flags <tmpl>    Print required --data flags for a template and exit 0
  --copier-yml <path>    Path to copier.yml (used by --list-flags)
  --data KEY=VALUE       Pass a --data flag to nava-platform (repeatable)

Environment:
  NAVA_TIMEOUT   Seconds before subprocess calls time out (default: 120)

Templates (positional args):
  Default: nextjs flask rails
EOF
}

# list_flags_from_copier_yml <copier_yml_path>
# Parses _questions keys from a copier.yml and prints --data KEY lines.
list_flags_from_copier_yml() {
    local copier_yml="$1"
    if [[ ! -f "$copier_yml" ]]; then
        echo "Error: copier.yml not found: $copier_yml" >&2
        return 1
    fi
    /usr/bin/python3 - "$copier_yml" <<'PYEOF'
import sys
import re

path = sys.argv[1]
with open(path) as f:
    lines = f.readlines()

in_questions = False
for line in lines:
    stripped = line.rstrip()
    # Detect _questions: block
    if re.match(r'^_questions\s*:', stripped):
        in_questions = True
        continue
    if in_questions:
        # Top-level keys under _questions are indented by 2 spaces
        m = re.match(r'^  ([a-zA-Z_][a-zA-Z0-9_]*):', stripped)
        if m:
            key = m.group(1)
            print(f"--data {key}")
        elif stripped and not stripped.startswith(' ') and not stripped.startswith('#'):
            # Another top-level key — end of _questions block
            in_questions = False
PYEOF
}

# ── Argument parsing ───────────────────────────────────────────────────────────
LIST_FLAGS_TEMPLATE=""
COPIER_YML=""
TEMPLATES=()
EXTRA_DATA_FLAGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            usage
            exit 0
            ;;
        --list-flags)
            if [[ $# -lt 2 ]]; then
                echo "Error: --list-flags requires a template name" >&2
                exit 1
            fi
            LIST_FLAGS_TEMPLATE="$2"
            shift 2
            ;;
        --copier-yml)
            if [[ $# -lt 2 ]]; then
                echo "Error: --copier-yml requires a path argument" >&2
                exit 1
            fi
            COPIER_YML="$2"
            shift 2
            ;;
        --data)
            if [[ $# -lt 2 ]]; then
                echo "Error: --data requires a KEY=VALUE argument" >&2
                exit 1
            fi
            EXTRA_DATA_FLAGS+=("--data" "$2")
            shift 2
            ;;
        --data=*)
            EXTRA_DATA_FLAGS+=("--data" "${1#--data=}")
            shift
            ;;
        --*)
            echo "Error: unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
        *)
            TEMPLATES+=("$1")
            shift
            ;;
    esac
done

# ── --list-flags mode ──────────────────────────────────────────────────────────
if [[ -n "$LIST_FLAGS_TEMPLATE" ]]; then
    if [[ -n "$COPIER_YML" ]]; then
        list_flags_from_copier_yml "$COPIER_YML"
        exit $?
    else
        # Built-in registry fallback
        case "$LIST_FLAGS_TEMPLATE" in
            nextjs)
                echo "--data project_name"
                echo "--data project_description"
                echo "--data node_version"
                echo "--data use_typescript"
                echo "--data github_org"
                ;;
            flask)
                echo "--data project_name"
                echo "--data project_description"
                echo "--data python_version"
                echo "--data github_org"
                ;;
            rails)
                echo "--data project_name"
                echo "--data project_description"
                echo "--data ruby_version"
                echo "--data github_org"
                ;;
            *)
                echo "Error: unknown template: $LIST_FLAGS_TEMPLATE" >&2
                exit 1
                ;;
        esac
        exit 0
    fi
fi

# ── Default templates ─────────────────────────────────────────────────────────
if [[ ${#TEMPLATES[@]} -eq 0 ]]; then
    TEMPLATES=("${DEFAULT_TEMPLATES[@]}")
fi

# ── Resolve nava-platform command ─────────────────────────────────────────────
# Priority:
#   1. Already on PATH → use directly (no install needed)
#   2. uv available  → install via uv tool install
#   3. pipx available → install via pipx install
#   4. Neither       → exit 1 with install instructions

NAVA_CMD=""
NAVA_WAS_INSTALLED=false

if command -v nava-platform &>/dev/null; then
    NAVA_CMD="nava-platform"
else
    # Probe for installer
    INSTALLER=""
    if command -v uv &>/dev/null; then
        INSTALLER="uv"
    elif command -v pipx &>/dev/null; then
        INSTALLER="pipx"
    fi

    if [[ -z "$INSTALLER" ]]; then
        echo "nava-platform not found" >&2
        echo "" >&2
        echo "Neither 'uv' nor 'pipx' was found on PATH." >&2
        echo "Install one of them to proceed:" >&2
        echo "" >&2
        echo "  uv (recommended):" >&2
        echo "    curl -LsSf https://astral.sh/uv/install.sh | sh" >&2
        echo "" >&2
        echo "  pipx:" >&2
        echo "    pip install pipx" >&2
        echo "" >&2
        echo "Then install nava-platform:" >&2
        echo "    uv tool install git+https://github.com/${NAVA_GITHUB_REPO}" >&2
        echo "  or" >&2
        echo "    pipx install git+https://github.com/${NAVA_GITHUB_REPO}" >&2
        exit 1
    fi

    echo "Installing nava-platform via ${INSTALLER}..." >&2
    if [[ "$INSTALLER" == "uv" ]]; then
        if ! run_with_timeout "$NAVA_TIMEOUT" uv tool install "git+https://github.com/${NAVA_GITHUB_REPO}"; then
            echo "Error: failed to install nava-platform via uv" >&2
            exit 1
        fi
        # uv tool installs into PATH via uv tool bin dir; check PATH first,
        # then fall back to the per-tool bin directory inside uv tool dir.
        if command -v nava-platform &>/dev/null; then
            NAVA_CMD="nava-platform"
        else
            NAVA_CMD="$(uv tool dir)/nava-platform/bin/nava-platform"
        fi
    else
        if ! run_with_timeout "$NAVA_TIMEOUT" pipx install "git+https://github.com/${NAVA_GITHUB_REPO}"; then
            echo "Error: failed to install nava-platform via pipx" >&2
            exit 1
        fi
        NAVA_CMD="nava-platform"
    fi
    NAVA_WAS_INSTALLED=true
fi

# ── Verify installation (only after fresh install) ────────────────────────────
if [[ "$NAVA_WAS_INSTALLED" == "true" ]]; then
    if ! run_with_timeout "$NAVA_TIMEOUT" "$NAVA_CMD" --help &>/dev/null; then
        echo "Error: nava-platform --help exited non-zero; installation may be broken" >&2
        exit 1
    fi
fi

# Log version/commit (best-effort; timeout is non-fatal for version check)
echo "nava-platform version:" >&2
_ver_exit=0
run_with_timeout "$NAVA_TIMEOUT" "$NAVA_CMD" --version >&2 || _ver_exit=$?
if [[ "$_ver_exit" -eq 124 ]]; then
    echo "Warning: nava-platform --version timed out (NAVA_TIMEOUT=${NAVA_TIMEOUT}s); skipping version log" >&2
fi

# ── Per-template validation ────────────────────────────────────────────────────
OVERALL_EXIT=0

for TEMPLATE in "${TEMPLATES[@]}"; do
    echo ""
    echo "── Template: ${TEMPLATE} ──────────────────────────────────────────"

    # Build --data flags for this template
    DATA_FLAGS=()
    if [[ ${#EXTRA_DATA_FLAGS[@]} -gt 0 ]]; then
        DATA_FLAGS=("${EXTRA_DATA_FLAGS[@]}")
    else
        # Use built-in defaults
        case "$TEMPLATE" in
            nextjs)
                DATA_FLAGS=(
                    --data "project_name=test-${TEMPLATE}"
                    --data "project_description=test"
                    --data "node_version=20"
                    --data "use_typescript=true"
                    --data "github_org=test-org"
                )
                ;;
            flask)
                DATA_FLAGS=(
                    --data "project_name=test-${TEMPLATE}"
                    --data "project_description=test"
                    --data "python_version=3.12"
                    --data "github_org=test-org"
                )
                ;;
            rails)
                DATA_FLAGS=(
                    --data "project_name=test-${TEMPLATE}"
                    --data "project_description=test"
                    --data "ruby_version=3.2"
                    --data "github_org=test-org"
                )
                ;;
            *)
                DATA_FLAGS=(
                    --data "project_name=test-${TEMPLATE}"
                )
                ;;
        esac
    fi

    # Run nava-platform app install with timeout, stdin from /dev/null
    INSTALL_EXIT=0
    run_with_timeout "$NAVA_TIMEOUT" "$NAVA_CMD" app install "${DATA_FLAGS[@]}" \
        < /dev/null 2>&1 || INSTALL_EXIT=$?
    if [[ "$INSTALL_EXIT" -eq 124 ]]; then
        echo "RESULT: TIMEOUT  template=${TEMPLATE}  exit=124" >&2
        exit 124
    fi

    # Structured output
    DATA_FLAGS_STR="${DATA_FLAGS[*]:-}"
    if [[ "$INSTALL_EXIT" -eq 0 ]]; then
        echo "RESULT: PASS  template=${TEMPLATE}  exit=${INSTALL_EXIT}  flags=${DATA_FLAGS_STR}"
    else
        echo "RESULT: FAIL  template=${TEMPLATE}  exit=${INSTALL_EXIT}  flags=${DATA_FLAGS_STR}"
        OVERALL_EXIT=1
    fi

    # ── Negative test: omit --data flag but provide template → assert non-zero exit ──
    # Run with the template argument but without any --data flags; if the CLI
    # prompts for input it will hang → timeout → exit 124.
    NEGTEST_EXIT=0
    run_with_timeout "$NAVA_TIMEOUT" "$NAVA_CMD" app install "$TEMPLATE" \
        < /dev/null 2>&1 || NEGTEST_EXIT=$?

    if [[ "$NEGTEST_EXIT" -ne 0 ]]; then
        echo "RESULT: PASS  template=${TEMPLATE} (negative test: missing --data → exit ${NEGTEST_EXIT})"
    else
        echo "RESULT: FAIL  template=${TEMPLATE} (negative test: expected non-zero when --data omitted, got 0)"
        OVERALL_EXIT=1
    fi
done

exit "$OVERALL_EXIT"
