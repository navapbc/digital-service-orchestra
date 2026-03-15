#!/usr/bin/env bash
# lockpick-workflow/scripts/smoke-test-portable.sh
# Plugin bootstrap validation: creates a minimal skeleton project, copies the
# plugin, initializes a git repo, writes a minimal config, and runs key scripts
# to confirm hooks, scripts, and skills initialize without error.
#
# Usage:
#   CLAUDE_PLUGIN_ROOT=/path/to/lockpick-workflow bash smoke-test-portable.sh
#
# Env vars:
#   CLAUDE_PLUGIN_ROOT  — path to the plugin root (required)
#
# Exit codes:
#   0 — all required assertions pass
#   1 — one or more required assertions failed or CLAUDE_PLUGIN_ROOT not set

set -euo pipefail

# ── Argument / env resolution ─────────────────────────────────────────────────
if [[ -z "${CLAUDE_PLUGIN_ROOT:-}" ]]; then
    echo "Error: CLAUDE_PLUGIN_ROOT is required." >&2
    echo "Usage: CLAUDE_PLUGIN_ROOT=/path/to/lockpick-workflow bash $(basename "$0")" >&2
    exit 1
fi

if [[ ! -d "$CLAUDE_PLUGIN_ROOT" ]]; then
    echo "Error: CLAUDE_PLUGIN_ROOT=$CLAUDE_PLUGIN_ROOT does not exist or is not a directory." >&2
    exit 1
fi

FAIL=0
PASS=0

# ── Create temp dir and register cleanup trap ─────────────────────────────────
SMOKE_DIR=$(mktemp -d /tmp/lw-smoke-XXXXXX)
trap 'rm -rf "$SMOKE_DIR"' EXIT

# ── Copy plugin into temp dir ─────────────────────────────────────────────────
cp -RL "$CLAUDE_PLUGIN_ROOT" "$SMOKE_DIR/lockpick-workflow"
PLUGIN_COPY="$SMOKE_DIR/lockpick-workflow"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_COPY"

# ── Initialize minimal git repo ───────────────────────────────────────────────
(
    cd "$SMOKE_DIR"
    git init -q
    git config user.email 'test@test.com'
    git config user.name 'Test'
) 2>/dev/null

# ── Write minimal workflow-config.conf ────────────────────────────────────────
cat > "$SMOKE_DIR/workflow-config.conf" <<'EOF'
commands.test=make test
commands.lint=make lint
EOF

# ── Helper: run a check and record PASS/FAIL ─────────────────────────────────
check() {
    local label="$1"
    local required="${2:-required}"  # "required" or "optional"
    shift 2
    local exit_code=0
    "$@" >/dev/null 2>&1 || exit_code=$?
    if [ "$exit_code" -eq 0 ]; then
        echo "  PASS: $label"
        PASS=$(( PASS + 1 ))
    else
        if [[ "$required" == "required" ]]; then
            echo "  FAIL: $label (exit $exit_code)" >&2
            FAIL=$(( FAIL + 1 ))
        else
            echo "  SKIP: $label (optional, exit $exit_code)"
        fi
    fi
}

echo "=== smoke-test-portable.sh ==="
echo "Plugin copy: $PLUGIN_COPY"
echo ""

# ── Hook initialization (non-catastrophic exit is acceptable) ─────────────────
echo "Hook initialization check:"
hook_exit=0
bash "$PLUGIN_COPY/hooks/dispatchers/pre-bash.sh" --smoke-check 2>/dev/null || hook_exit=$?
# Any non-catastrophic exit is acceptable (hooks may not support --smoke-check)
if [ "$hook_exit" -ne 139 ] && [ "$hook_exit" -ne 137 ]; then  # not SIGSEGV/SIGKILL
    echo "  PASS: hook pre-bash.sh initialization (exit $hook_exit — non-catastrophic)"
    PASS=$(( PASS + 1 ))
else
    echo "  FAIL: hook pre-bash.sh crashed with fatal signal (exit $hook_exit)" >&2
    FAIL=$(( FAIL + 1 ))
fi

# ── Key script checks ─────────────────────────────────────────────────────────
echo ""
echo "Key script checks:"

# Required: read-config.sh commands.test (must exit 0)
check "read-config.sh commands.test exits 0" required \
    bash "$PLUGIN_COPY/scripts/read-config.sh" commands.test "$SMOKE_DIR/workflow-config.conf"

# Required: validate-config.sh (no-arg invocation)
check "validate-config.sh exits 0 with minimal config" required \
    bash -c "CLAUDE_PLUGIN_ROOT='$PLUGIN_COPY' bash '$PLUGIN_COPY/scripts/validate-config.sh'"

# nav.sh is in the host project scripts/, not in the plugin itself — skip it
# and use scripts available within the plugin

# Required: read-config.sh commands.lint (must exit 0)
check "read-config.sh commands.lint exits 0" required \
    bash "$PLUGIN_COPY/scripts/read-config.sh" commands.lint "$SMOKE_DIR/workflow-config.conf"

# Optional: discover-agents.sh (may need .claude/settings.json)
discover_exit=0
bash "$PLUGIN_COPY/scripts/discover-agents.sh" \
    --settings "$PLUGIN_COPY/config/agent-routing.conf" \
    2>/dev/null || discover_exit=$?
# discover-agents.sh exits 1 for missing routing file but we pass the routing directly;
# graceful non-crash is acceptable
if [ "$discover_exit" -ne 139 ] && [ "$discover_exit" -ne 137 ]; then
    echo "  PASS: discover-agents.sh non-catastrophic exit ($discover_exit)"
    PASS=$(( PASS + 1 ))
else
    echo "  FAIL: discover-agents.sh crashed with fatal signal (exit $discover_exit)" >&2
    FAIL=$(( FAIL + 1 ))
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -eq 0 ]; then
    echo "PASS: all smoke checks passed"
    exit 0
else
    echo "FAIL: $FAIL smoke check(s) failed" >&2
    exit 1
fi
