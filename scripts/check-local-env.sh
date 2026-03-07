#!/usr/bin/env bash
# lockpick-workflow/scripts/check-local-env.sh
# Generic local environment verification script.
#
# Checks: Docker daemon, DB container detection (config-driven), port connectivity,
#         dev tool presence, and an optional project-specific callback.
#
# Usage:
#   check-local-env.sh              # Check default ports (3000/5432)
#   check-local-env.sh --quiet      # Exit code only, no output on success
#   APP_PORT=3037 DB_PORT=5469 check-local-env.sh  # Custom ports
#
# Config keys (workflow-config.yaml):
#   commands.env_check_app          — project-specific callback; absent = warn + skip
#   infrastructure.db_container     — DB container name (default: lockpick-postgres-dev)
#   infrastructure.db_container_patterns — list of DB container name patterns
#   infrastructure.required_tools   — list of required dev tools
#   infrastructure.optional_tools   — list of optional dev tools
#   infrastructure.db_port          — DB port (overrides DB_PORT env var)
#   infrastructure.app_port         — app port (overrides APP_PORT env var)
#   infrastructure.health_timeout   — health check timeout in seconds (default: 5)
#
# Environment variable overrides:
#   APP_PORT      — application port (default: 3000)
#   DB_PORT       — database port (default: 5432)
#   DB_CONTAINER  — DB container name override
#   WORKFLOW_CONFIG — path to workflow-config.yaml (for testing)
#
# Exit codes:
#   0 = all checks passed
#   1 = one or more checks failed

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source shared dependency library for try_start_docker, try_find_python, check_tool
# Support CLAUDE_PLUGIN_ROOT fallback pattern for plugin consumers
_HOOK_LIB=""
if [[ -n "${CLAUDE_PLUGIN_ROOT:-}" ]] && [[ -f "${CLAUDE_PLUGIN_ROOT}/hooks/lib/deps.sh" ]]; then
    _HOOK_LIB="${CLAUDE_PLUGIN_ROOT}/hooks/lib/deps.sh"
elif [[ -f "$SCRIPT_DIR/../hooks/lib/deps.sh" ]]; then
    _HOOK_LIB="$SCRIPT_DIR/../hooks/lib/deps.sh"
elif [[ -f "$REPO_ROOT/lockpick-workflow/hooks/lib/deps.sh" ]]; then
    _HOOK_LIB="$REPO_ROOT/lockpick-workflow/hooks/lib/deps.sh"
fi
if [[ -n "$_HOOK_LIB" ]]; then
    source "$_HOOK_LIB"
fi

# Resolve Python with pyyaml for read-config.sh.
# Probe candidates in order: plugin's own venv, repo root venv, system python3.
# Export as CLAUDE_PLUGIN_PYTHON so read-config.sh uses it even when CWD is a
# test skeleton that has no venv (avoids "no python3 with pyyaml" errors in tests).
if [[ -z "${CLAUDE_PLUGIN_PYTHON:-}" ]]; then
    for _py_candidate in \
        "$SCRIPT_DIR/../../app/.venv/bin/python3" \
        "$SCRIPT_DIR/../../../app/.venv/bin/python3" \
        "$REPO_ROOT/app/.venv/bin/python3" \
        "$REPO_ROOT/.venv/bin/python3" \
        "python3"; do
        [[ "$_py_candidate" != "python3" ]] && [[ ! -f "$_py_candidate" ]] && continue
        if "$_py_candidate" -c "import yaml" 2>/dev/null; then
            export CLAUDE_PLUGIN_PYTHON="$_py_candidate"
            break
        fi
    done
fi

# Config reader helper — respects WORKFLOW_CONFIG override (for tests)
_read_cfg() {
    local key="$1"
    if [[ -n "${WORKFLOW_CONFIG:-}" ]]; then
        bash "$SCRIPT_DIR/read-config.sh" "$WORKFLOW_CONFIG" "$key" 2>/dev/null || true
    else
        bash "$SCRIPT_DIR/read-config.sh" "$key" 2>/dev/null || true
    fi
}

# List config reader helper
_read_cfg_list() {
    local key="$1"
    if [[ -n "${WORKFLOW_CONFIG:-}" ]]; then
        bash "$SCRIPT_DIR/read-config.sh" --list "$WORKFLOW_CONFIG" "$key" 2>/dev/null || true
    else
        bash "$SCRIPT_DIR/read-config.sh" --list "$key" 2>/dev/null || true
    fi
}

# ── CLI flags ─────────────────────────────────────────────────────────────────
QUIET=false
[[ "${1:-}" == "--quiet" ]] && QUIET=true

# ── Config-driven overrides ───────────────────────────────────────────────────
_cfg_db_port=$(_read_cfg "infrastructure.db_port")
_cfg_app_port=$(_read_cfg "infrastructure.app_port")
_cfg_health_timeout=$(_read_cfg "infrastructure.health_timeout")
_cfg_db_container=$(_read_cfg "infrastructure.db_container")

APP_PORT="${APP_PORT:-${_cfg_app_port:-3000}}"
DB_PORT="${DB_PORT:-${_cfg_db_port:-5432}}"
HEALTH_TIMEOUT="${_cfg_health_timeout:-5}"
DB_CONTAINER="${DB_CONTAINER:-${_cfg_db_container:-lockpick-postgres-dev}}"

# ── Counters and helpers ──────────────────────────────────────────────────────
passed=0
failed=0
warnings=0

pass()   { passed=$((passed + 1)); $QUIET || printf "  ✓ %s\n" "$1"; }
fail()   { failed=$((failed + 1)); printf "  ✗ %s\n" "$1" >&2; }
warn()   { warnings=$((warnings + 1)); $QUIET || printf "  ⚠ WARN %s\n" "$1"; }
header() { $QUIET || printf "\n%s\n" "$1"; }

# ── 1. Docker daemon ──────────────────────────────────────────────────────────
header "Docker"

if ! command -v docker &>/dev/null; then
    fail "docker CLI not found in PATH"
elif ! docker info &>/dev/null; then
    if type try_start_docker &>/dev/null; then
        $QUIET || printf "  … Docker daemon not running, attempting auto-start…\n"
        if try_start_docker; then
            pass "Docker daemon started automatically"
        else
            fail "Docker daemon not running (auto-start failed — start Docker Desktop manually)"
        fi
    else
        fail "Docker daemon not running (is Docker Desktop started?)"
    fi
else
    pass "Docker daemon responding"
fi

# ── 2. Postgres container ─────────────────────────────────────────────────────
header "Postgres (port $DB_PORT)"

_db_found=false
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${DB_CONTAINER}$"; then
    _db_found=true
    health=$(docker inspect --format '{{.State.Health.Status}}' "$DB_CONTAINER" 2>/dev/null || echo "unknown")
    if [[ "$health" == "healthy" ]]; then
        pass "$DB_CONTAINER running (healthy)"
    elif [[ "$health" == "starting" ]]; then
        warn "$DB_CONTAINER running but still starting"
    else
        warn "$DB_CONTAINER running (health: $health)"
    fi
fi

# Also check config-driven pattern list (infrastructure.db_container_patterns)
if ! $_db_found; then
    while IFS= read -r pattern; do
        [[ -z "$pattern" ]] && continue
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "$pattern"; then
            _container_name=$(docker ps --format '{{.Names}}' 2>/dev/null | grep "$pattern" | head -1 || true)
            pass "$_container_name running (matches pattern: $pattern)"
            _db_found=true
            break
        fi
    done < <(_read_cfg_list "infrastructure.db_container_patterns")
fi

if ! $_db_found; then
    fail "No Postgres container found (run 'make db-start' or 'docker compose up')"
fi

# Verify Postgres is accepting connections on the expected port
if command -v pg_isready &>/dev/null; then
    if pg_isready -h localhost -p "$DB_PORT" -U app -q 2>/dev/null; then
        pass "Postgres accepting connections on localhost:$DB_PORT"
    else
        fail "Postgres not accepting connections on localhost:$DB_PORT"
    fi
else
    if (echo >/dev/tcp/localhost/"$DB_PORT") 2>/dev/null; then
        pass "Port $DB_PORT is open (pg_isready not available for deeper check)"
    else
        fail "Nothing listening on localhost:$DB_PORT"
    fi
fi

# ── 3. Application container ──────────────────────────────────────────────────
header "Application (port $APP_PORT)"

app_container=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -v "db" | grep -v "postgres" | head -1 || true)
if [[ -n "$app_container" ]]; then
    pass "App container running: $app_container"
else
    if (echo >/dev/tcp/localhost/"$APP_PORT") 2>/dev/null; then
        warn "No app container found, but port $APP_PORT is open (running natively?)"
    else
        warn "No app container found and nothing listening on port $APP_PORT"
    fi
fi

# ── 4. Health check ───────────────────────────────────────────────────────────
header "Health check (http://localhost:$APP_PORT/health)"

http_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout "$HEALTH_TIMEOUT" --max-time "$HEALTH_TIMEOUT" "http://localhost:$APP_PORT/health" 2>/dev/null || echo "000")

if [[ "$http_code" == "200" ]]; then
    pass "GET /health returned 200"
    db_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout "$HEALTH_TIMEOUT" --max-time "$HEALTH_TIMEOUT" "http://localhost:$APP_PORT/api/health/db" 2>/dev/null || echo "000")
    if [[ "$db_code" == "200" ]]; then
        db_body=$(curl -s --connect-timeout "$HEALTH_TIMEOUT" --max-time "$HEALTH_TIMEOUT" "http://localhost:$APP_PORT/api/health/db" 2>/dev/null || echo "{}")
        db_connected=$(echo "$db_body" | grep -o '"db_connected":[a-z]*' | cut -d: -f2 || echo "unknown")
        if [[ "$db_connected" == "true" ]]; then
            pass "GET /api/health/db returned 200 (db_connected: true)"
        else
            warn "GET /api/health/db returned 200 but db_connected=$db_connected"
        fi
    else
        warn "GET /api/health/db returned $db_code"
    fi
elif [[ "$http_code" == "503" ]]; then
    fail "GET /health returned 503 (service unavailable — DB connection issue?)"
elif [[ "$http_code" == "000" ]]; then
    warn "GET /health failed to connect (app not responding on port $APP_PORT)"
else
    warn "GET /health returned unexpected status $http_code"
fi

# ── 5. Dev tools ──────────────────────────────────────────────────────────────
header "Dev Tools"

# Config-driven required and optional tools; fall back to built-in defaults
_required_tools=()
_optional_tools=()

while IFS= read -r tool; do
    [[ -z "$tool" ]] && continue
    _required_tools+=("$tool")
done < <(_read_cfg_list "infrastructure.required_tools")

while IFS= read -r tool; do
    [[ -z "$tool" ]] && continue
    _optional_tools+=("$tool")
done < <(_read_cfg_list "infrastructure.optional_tools")

# Fall back to built-in defaults when not config-driven
if [[ ${#_required_tools[@]} -eq 0 ]]; then
    _required_tools=(jq git curl)
fi
if [[ ${#_optional_tools[@]} -eq 0 ]]; then
    _optional_tools=(shasum)
fi

for tool in "${_required_tools[@]}"; do
    if command -v "$tool" &>/dev/null; then
        pass "$tool available"
    else
        fail "$tool not found (required)"
    fi
done

for tool in "${_optional_tools[@]}"; do
    if command -v "$tool" &>/dev/null; then
        pass "$tool available"
    else
        warn "$tool not found (optional — some features degraded)"
    fi
done

# ── 6. Project-specific callback (optional) ───────────────────────────────────
header "Project checks"

env_check_app_cmd=$(_read_cfg "commands.env_check_app")

if [[ -z "$env_check_app_cmd" ]]; then
    warn "env_check_app not configured — project-specific checks skipped"
else
    $QUIET || printf "  … running env_check_app: %s\n" "$env_check_app_cmd"
    if eval "$env_check_app_cmd"; then
        pass "env_check_app passed"
    else
        fail "env_check_app failed: $env_check_app_cmd"
    fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
header "Summary"
total=$((passed + failed + warnings))
if $QUIET && [[ $failed -eq 0 ]]; then
    exit 0
fi

printf "  %d passed, %d failed, %d warnings (of %d checks)\n" "$passed" "$failed" "$warnings" "$total"

if [[ $failed -gt 0 ]]; then
    printf "\nSome environment checks failed.\n"
    exit 1
fi

exit 0
