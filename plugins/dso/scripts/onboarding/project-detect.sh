#!/usr/bin/env bash
set -uo pipefail
# scripts/project-detect.sh
# Detect project characteristics by inspecting a target directory.
#
# Usage: project-detect.sh [--suites] <project-dir>
#   --suites      : discover test suites and emit a JSON array (see JSON schema below)
#   <project-dir> : path to the project directory to inspect
#
# Default mode (no --suites): Output (stdout) is key=value lines, one per detected
# attribute. This format is backward-compatible — adding --suites does not change it.
#
# Default mode schema:
#   stack=<value>                        — from detect-stack.sh
#   stack_confidence=confirmed           — detect-stack.sh verifies marker file existence
#   targets=<comma-separated>            — Makefile targets or package.json scripts
#   targets_confidence=confirmed         — targets read directly from Makefile/package.json
#   python_version=<value>|unknown       — detected Python version requirement
#   python_version_confidence=high|low   — confidence level for python_version
#   db_present=true|false                — whether a DB service was found
#   db_services=<comma-separated>        — names of DB services found
#   db_confidence=confirmed|inferred|none — confidence level for db_present/db_services
#   files_present=<comma-separated>      — which marker files exist
#   files_present_confidence=confirmed   — files checked with test -f
#   ci_workflow_names=<comma-separated>  — names of CI workflows found
#   ci_workflow_test_guarded=true|false  — any workflow runs test
#   ci_workflow_lint_guarded=true|false  — any workflow runs lint
#   ci_workflow_format_guarded=true|false — any workflow runs format
#   ci_workflow_confidence=high|low      — confidence level for ci_workflow detection
#   installed_deps=<comma-separated>     — CLI tools detected as installed
#   installed_deps_confidence=confirmed  — checked with command -v
#   ports=<comma-separated>              — port numbers from .claude/dso-config.conf
#   ports_confidence=confirmed           — read directly from config file
#   version_files=<comma-separated>      — files that carry a version field
#   version_files_confidence=confirmed   — checked with test -f and content parsing
#
# --suites mode: Output (stdout) is a JSON array of test suite objects. The script
# exits immediately after emitting the array; key=value output is not produced.
#
# --suites JSON output schema (each array element):
#   name        (string, unique) — short identifier for the suite (e.g. "unit", "e2e")
#   command     (string)         — shell command to run the suite (e.g. "make test-unit")
#   speed_class (string)         — "fast", "slow", or "unknown"
#   runner      (string)         — one of: "make", "pytest", "npm", "bash", "config"
#
# Heuristic sources and Precedence order (highest wins):
#   1. config   — .claude/dso-config.conf keys test.suite.<name>.command and
#                 test.suite.<name>.speed_class (explicit, highest precedence)
#   2. make     — Makefile targets matching /^test[-_]/ (e.g. test-unit -> name "unit")
#   3. pytest   — subdirectories of tests/ or test/ containing test_*.py files
#                 (e.g. tests/unit/ -> name "unit")
#   4. npm      — package.json scripts matching /^test[:_-]/ (e.g. test:integration ->
#                 name "integration")
#   5. bash     — executable test-*.sh / test_*.sh / run-tests*.sh at project root
#                 (e.g. test-hooks.sh -> name "hooks")
#
# Name derivation rules:
#   Makefile test-foo / test_foo  -> strip "test[-_]" prefix -> "foo"
#   pytest tests/unit/            -> basename of subdir -> "unit"
#   npm test:integration          -> strip "test:" prefix -> "integration"
#   bash test-hooks.sh            -> strip "test[-_]" prefix and ".sh" suffix -> "hooks"
#
# Backward compatibility guarantee:
#   Without --suites, stdout output is unchanged KEY=VALUE format. The --suites flag
#   adds a new output mode without modifying the existing key=value output path.
#
# Exit codes:
#   0 — always (detection always succeeds)
#   1 — argument error (missing or invalid project-dir)

# ── Argument parsing ───────────────────────────────────────────────────────────
SUITES_MODE=0

if [[ $# -lt 1 ]]; then
    echo "Error: project-dir argument required" >&2
    exit 1
fi

if [[ "$1" == "--suites" ]]; then
    SUITES_MODE=1
    shift
    if [[ $# -lt 1 ]]; then
        echo "Error: project-dir argument required after --suites" >&2
        exit 1
    fi
fi

PROJECT_DIR="$1"

if [[ ! -d "$PROJECT_DIR" ]]; then
    echo "Error: not a directory: $PROJECT_DIR" >&2
    exit 1
fi

# ── Suite discovery function ─────────────────────────────────────────────────
# Discovers test suites via Makefile targets, pytest directories, npm scripts,
# bash runners, and config keys. Deduplicates by name using precedence:
# config > Makefile > pytest > npm > bash. Outputs a JSON array to stdout.
_discover_suites() {
    local project_dir="$1"
    local entries=""

    _append_entry() {
        if [[ -n "$entries" ]]; then
            entries="${entries},"
        fi
        entries="${entries}$1"
    }

    # Makefile heuristic: find targets matching /^test[-_]/
    if [[ -f "$project_dir/Makefile" ]]; then
        local makefile_test_targets
        makefile_test_targets="$(grep -E '^test[-_][a-zA-Z0-9_-]+:' "$project_dir/Makefile" \
            | sed 's/:.*//' || true)"
        local target
        while IFS= read -r target; do
            [[ -z "$target" ]] && continue
            local name
            name="$(echo "$target" | sed -E 's/^test[-_]//')"
            _append_entry "make:${target}=${name}"
        done <<< "$makefile_test_targets"
    fi

    # pytest heuristic: find directories under tests/ or test/ containing test_*.py
    local test_root=""
    if [[ -d "$project_dir/tests" ]]; then
        test_root="tests"
    elif [[ -d "$project_dir/test" ]]; then
        test_root="test"
    fi

    if [[ -n "$test_root" ]]; then
        local subdir
        for subdir in "$project_dir/$test_root"/*/; do
            [[ -d "$subdir" ]] || continue
            local has_test_files
            has_test_files="$(find "$subdir" -maxdepth 1 -name 'test_*.py' 2>/dev/null | head -1)"
            if [[ -n "$has_test_files" ]]; then
                local dirname
                dirname="$(basename "$subdir")"
                _append_entry "pytest:${test_root}/${dirname}=${dirname}"
            fi
        done
    fi

    # npm heuristic: parse package.json for scripts matching /^test/
    if [[ -f "$project_dir/package.json" ]]; then
        local npm_entries
        npm_entries="$(python3 - "$project_dir/package.json" <<'PYEOF' 2>/dev/null || true
import sys, json
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    scripts = data.get("scripts", {})
    results = []
    for key in sorted(scripts.keys()):
        if key.startswith("test:") or key.startswith("test-") or key.startswith("test_"):
            # Strip prefix to derive name
            if key.startswith("test:"):
                name = key[5:]
            elif key.startswith("test-"):
                name = key[5:]
            else:
                name = key[5:]
            if name:
                results.append("npm:" + key + "=" + name)
        elif key == "test":
            results.append("npm:" + key + "=test")
    print(",".join(results))
except Exception as e:
    import sys as s
    print("Warning: failed to parse package.json: " + str(e), file=s.stderr)
PYEOF
)"
        if [[ -n "$npm_entries" ]]; then
            local npm_entry
            IFS=',' read -ra npm_parts <<< "$npm_entries"
            for npm_entry in "${npm_parts[@]}"; do
                [[ -z "$npm_entry" ]] && continue
                _append_entry "$npm_entry"
            done
        fi
    fi

    # bash runner heuristic: find executable test-*.sh, test_*.sh, run-tests*.sh
    local bash_file
    for bash_file in "$project_dir"/test-*.sh "$project_dir"/test_*.sh "$project_dir"/run-tests*.sh; do
        [[ -f "$bash_file" ]] || continue
        [[ -x "$bash_file" ]] || continue
        local basename_file
        basename_file="$(basename "$bash_file")"
        # Derive name: strip prefix and .sh suffix
        local bash_name
        bash_name="$(echo "$basename_file" | sed -E 's/\.sh$//; s/^run-tests[-_]//; s/^test[-_]//')"
        [[ -z "$bash_name" ]] && continue
        _append_entry "bash:${basename_file}=${bash_name}"
    done

    # config heuristic: parse .claude/dso-config.conf for test.suite.<name>.command
    if [[ -f "$project_dir/.claude/dso-config.conf" ]]; then
        local config_entries
        config_entries="$(grep -E '^test\.suite\.[^.]+\.command=' "$project_dir/.claude/dso-config.conf" 2>/dev/null | while IFS= read -r line; do
            local cfg_name cfg_command
            # Extract name: test.suite.<name>.command=<value>
            cfg_name="$(echo "$line" | sed -E 's/^test\.suite\.([^.]+)\.command=.*/\1/')"
            cfg_command="$(echo "$line" | sed -E 's/^test\.suite\.[^.]+\.command=//')"
            if [[ -n "$cfg_name" && -n "$cfg_command" ]]; then
                echo "config:${cfg_command}=${cfg_name}"
            fi
        done | paste -sd',' -)"
        if [[ -n "$config_entries" ]]; then
            local cfg_entry
            IFS=',' read -ra cfg_parts <<< "$config_entries"
            for cfg_entry in "${cfg_parts[@]}"; do
                [[ -z "$cfg_entry" ]] && continue
                _append_entry "$cfg_entry"
            done
        fi
    fi

    # Short-circuit: if no entries were discovered, emit empty JSON array without python3.
    if [[ -z "$entries" ]]; then
        echo "[]"
        return 0
    fi

    # Generate JSON output via python3.
    # Entries are passed via DSO_SUITE_ENTRIES env var, comma-delimited.
    # Python handles dedup by name with precedence: config > make > pytest > npm > bash.
    # Also reads config for speed_class overrides.
    DSO_SUITE_ENTRIES="$entries" DSO_CONFIG_PATH="$project_dir/.claude/dso-config.conf" python3 - <<'PYEOF'
import os, json

PRECEDENCE = {"config": 0, "make": 1, "pytest": 2, "npm": 3, "bash": 4}

entries_raw = os.environ.get("DSO_SUITE_ENTRIES", "")
config_path = os.environ.get("DSO_CONFIG_PATH", "")

# Parse config for speed_class overrides
speed_overrides = {}
if config_path:
    try:
        with open(config_path) as f:
            for line in f:
                line = line.strip()
                if line.startswith("test.suite.") and ".speed_class=" in line:
                    # test.suite.<name>.speed_class=<value>
                    rest = line[len("test.suite."):]
                    dot_idx = rest.index(".speed_class=")
                    name = rest[:dot_idx]
                    val = rest[dot_idx + len(".speed_class="):]
                    speed_overrides[name] = val
    except Exception:
        pass

# Parse all entries into a dict keyed by name, keeping highest precedence
seen = {}  # name -> (precedence, entry_dict)

if entries_raw:
    for entry_str in entries_raw.split(","):
        entry_str = entry_str.strip()
        if not entry_str:
            continue

        # Parse prefix:detail=name
        colon_idx = entry_str.index(":")
        runner = entry_str[:colon_idx]
        rest = entry_str[colon_idx + 1:]
        detail, name = rest.split("=", 1)

        prec = PRECEDENCE.get(runner, 99)

        if runner == "make":
            entry = {
                "name": name,
                "command": "make " + detail,
                "speed_class": "unknown",
                "runner": "make",
            }
        elif runner == "pytest":
            entry = {
                "name": name,
                "command": "pytest " + detail + "/",
                "speed_class": "unknown",
                "runner": "pytest",
            }
        elif runner == "npm":
            entry = {
                "name": name,
                "command": "npm run " + detail,
                "speed_class": "unknown",
                "runner": "npm",
            }
        elif runner == "bash":
            entry = {
                "name": name,
                "command": "bash " + detail,
                "speed_class": "unknown",
                "runner": "bash",
            }
        elif runner == "config":
            entry = {
                "name": name,
                "command": detail,
                "speed_class": "unknown",
                "runner": "config",
            }
        else:
            continue

        # Dedup: keep highest precedence (lowest number)
        if name not in seen or prec < seen[name][0]:
            seen[name] = (prec, entry)

# Apply speed_class overrides from config
for name, speed in speed_overrides.items():
    if name in seen:
        seen[name][1]["speed_class"] = speed

# Sort by name for consistent output
result = [entry for _, entry in sorted(seen.values(), key=lambda x: x[1]["name"])]
print(json.dumps(result))
PYEOF
}

# If --suites mode, run suite discovery and exit
if [[ "$SUITES_MODE" -eq 1 ]]; then
    _discover_suites "$PROJECT_DIR"
    exit 0
fi

# BACKWARD_COMPAT: do not modify the key=value stdout output below this line without
# a backward-compat test. The --suites JSON output path above is NOT subject to this
# constraint — it exits before reaching the key=value section.

# Resolve the directory containing this script so we can locate siblings.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# detect-stack.sh lives in scripts/ (one level up from scripts/onboarding/).
DETECT_STACK="$SCRIPT_DIR/../detect-stack.sh"

# ── Category 2: Stack detection (delegates to detect-stack.sh) ────────────────
if [[ -x "$DETECT_STACK" ]]; then
    stack="$(bash "$DETECT_STACK" "$PROJECT_DIR" 2>/dev/null || echo "unknown")"
else
    stack="unknown"
fi
echo "stack=${stack}"
echo "stack_confidence=confirmed"

# ── Category 3: Target enumeration ────────────────────────────────────────────
targets=""

if [[ -f "$PROJECT_DIR/Makefile" ]]; then
    # Extract top-level targets: lines starting with a word followed by ':'
    # Exclude lines starting with '.' (phony declarations) and variable assignments.
    makefile_targets="$(grep -E '^[a-zA-Z0-9_-]+:' "$PROJECT_DIR/Makefile" \
        | sed 's/:.*//' \
        | tr '\n' ',' \
        | sed 's/,$//')"
    targets="${makefile_targets}"
fi

if [[ -f "$PROJECT_DIR/package.json" ]]; then
    # Extract keys from the "scripts" object using python3 (stdlib, no jq needed).
    pkg_targets="$(python3 - "$PROJECT_DIR/package.json" <<'PYEOF'
import sys, json
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    scripts = data.get("scripts", {})
    print(",".join(scripts.keys()))
except Exception:
    pass
PYEOF
)"
    if [[ -n "$pkg_targets" ]]; then
        if [[ -n "$targets" ]]; then
            targets="${targets},${pkg_targets}"
        else
            targets="${pkg_targets}"
        fi
    fi
fi

echo "targets=${targets}"
echo "targets_confidence=confirmed"

# ── Category 6: Python version detection ──────────────────────────────────────
python_version="unknown"
python_version_confidence="low"

if [[ -f "$PROJECT_DIR/.python-version" ]]; then
    # Exact version pinned — highest confidence.
    pyver_raw="$(tr -d '[:space:]' < "$PROJECT_DIR/.python-version")"
    if [[ -n "$pyver_raw" ]]; then
        python_version="$pyver_raw"
        python_version_confidence="high"
    fi
elif [[ -f "$PROJECT_DIR/pyproject.toml" ]]; then
    # Try requires-python in [project] section: requires-python = ">=3.11"
    requires_py="$(python3 - "$PROJECT_DIR/pyproject.toml" <<'PYEOF'
import re, sys
with open(sys.argv[1]) as f:
    content = f.read()
# Match requires-python = ">=3.11" or requires-python = '>=3.11'
m = re.search(r'^requires-python\s*=\s*["\']([^"\']+)["\']', content, re.MULTILINE)
if m:
    # Strip leading operator characters to get the bare version number
    ver = re.sub(r'^[><=!^~]+', '', m.group(1).strip())
    print(ver)
PYEOF
)"
    if [[ -n "$requires_py" ]]; then
        python_version="$requires_py"
        python_version_confidence="high"
    else
        # pyproject.toml present but no explicit version — medium confidence.
        python_version_confidence="low"
    fi
fi
# If none of the above matched, python_version stays "unknown", confidence "low".

echo "python_version=${python_version}"
echo "python_version_confidence=${python_version_confidence}"

# ── Category 5: Database presence ─────────────────────────────────────────────
db_present="false"
db_services=""
db_confidence="none"

DB_IMAGES="postgres|mysql|mariadb|mongodb|mongo|redis|elasticsearch|cassandra|cockroachdb|mssql|sqlite"

for compose_file in "$PROJECT_DIR/docker-compose.yml" "$PROJECT_DIR/docker-compose.yaml"; do
    if [[ -f "$compose_file" ]]; then
        # Parse service names that use a DB image.
        found_services="$(python3 - "$compose_file" "$DB_IMAGES" <<'PYEOF'
import sys, re

compose_file = sys.argv[1]
db_pattern = re.compile(sys.argv[2], re.IGNORECASE)

with open(compose_file) as f:
    content = f.read()

# Simple line-by-line YAML parse: find service blocks whose image: line matches.
# Strategy: collect all service names from "services:" block, then check if
# their image line contains a DB keyword.
services_found = []
in_services = False
current_service = None
indent_level = 0

lines = content.splitlines()
for i, line in enumerate(lines):
    stripped = line.lstrip()
    indent = len(line) - len(stripped)

    if stripped.startswith("services:"):
        in_services = True
        indent_level = indent
        continue

    if in_services:
        # A top-level key at services indent+2 is a service name.
        if indent == indent_level + 2 and stripped.endswith(":") and not stripped.startswith("#"):
            current_service = stripped.rstrip(":")
        elif current_service and stripped.startswith("image:"):
            image_val = stripped[len("image:"):].strip()
            if db_pattern.search(image_val):
                services_found.append(current_service)
            current_service = None
        # Reset if we leave the services block.
        if indent <= indent_level and stripped and not stripped.startswith("#") and not stripped.endswith(":") and i > 0:
            # Could be end of services block — conservatively keep scanning.
            pass

print(",".join(services_found))
PYEOF
)"
        if [[ -n "$found_services" ]]; then
            db_present="true"
            db_services="$found_services"
        fi
        break
    fi
done

# ── Category 5b: Dockerfile DB detection ──────────────────────────────────────
# docker-compose match → confirmed
if [[ "$db_present" == "true" ]]; then
    db_confidence="confirmed"
fi

# Scan Dockerfile and Dockerfile.* for FROM lines matching DB images
if [[ "$db_present" == "false" ]]; then
    for dockerfile in "$PROJECT_DIR"/Dockerfile "$PROJECT_DIR"/Dockerfile.*; do
        if [[ -f "$dockerfile" ]]; then
            dockerfile_services="$(python3 - "$dockerfile" "$DB_IMAGES" <<'PYEOF'
import sys, re

dockerfile_path = sys.argv[1]
db_pattern = re.compile(sys.argv[2], re.IGNORECASE)

with open(dockerfile_path) as f:
    lines = f.readlines()

found = []
for line in lines:
    stripped = line.strip()
    # Match: FROM <image>[:<tag>] [AS <name>]
    m = re.match(r'^FROM\s+(\S+)', stripped, re.IGNORECASE)
    if m:
        image = m.group(1)
        match = db_pattern.search(image)
        if match:
            # Extract the DB type from the image name
            db_type = match.group(0).lower()
            # Normalise mongo variants
            if db_type == "mongodb":
                db_type = "mongo"
            if db_type not in found:
                found.append(db_type)

print(",".join(found))
PYEOF
)"
            if [[ -n "$dockerfile_services" ]]; then
                db_present="true"
                db_services="$dockerfile_services"
                db_confidence="confirmed"
                break
            fi
        fi
    done
fi

# ── Category 5c: Python code import scanning ───────────────────────────────────
# Scan Python files in project root and common src dirs for DB library imports
if [[ "$db_present" == "false" ]]; then
    DB_PY_LIBS="psycopg2|sqlalchemy|pymongo|redis|mysql\.connector|pymysql|asyncpg|motor|aiomysql|aiopg"
    # Directories to scan (project root + common source dirs)
    py_scan_dirs=("$PROJECT_DIR")
    for srcdir in src app lib; do
        if [[ -d "$PROJECT_DIR/$srcdir" ]]; then
            py_scan_dirs+=("$PROJECT_DIR/$srcdir")
        fi
    done

    py_import_match=""
    for scan_dir in "${py_scan_dirs[@]}"; do
        # Only scan *.py files directly in this directory (not recursive to avoid deep scanning)
        while IFS= read -r -d '' pyfile; do
            py_import_match="$(grep -oE "^\s*(import|from)\s+(${DB_PY_LIBS})" "$pyfile" 2>/dev/null | grep -oE "(${DB_PY_LIBS})" | head -1)"
            if [[ -n "$py_import_match" ]]; then
                break 2
            fi
        done < <(find "$scan_dir" -maxdepth 1 -name "*.py" -print0 2>/dev/null)
    done

    if [[ -n "$py_import_match" ]]; then
        db_present="true"
        # Map library name to DB service name
        case "$py_import_match" in
            psycopg2|asyncpg|aiopg) db_services="postgres" ;;
            sqlalchemy)              db_services="database" ;;
            pymongo|motor)           db_services="mongo" ;;
            redis)                   db_services="redis" ;;
            mysql\.connector|pymysql|aiomysql) db_services="mysql" ;;
            *)                       db_services="$py_import_match" ;;
        esac
        db_confidence="inferred"
    fi
fi

# ── Category 5d: .env file scanning ───────────────────────────────────────────
# Scan .env and .env.* files for DATABASE_URL, DB_HOST, REDIS_URL patterns
if [[ "$db_present" == "false" ]]; then
    ENV_DB_PATTERNS="DATABASE_URL|DB_HOST|DB_URL|REDIS_URL|MONGO_URI|MONGODB_URI"
    for envfile in "$PROJECT_DIR"/.env "$PROJECT_DIR"/.env.*; do
        if [[ -f "$envfile" ]]; then
            env_match="$(grep -oE "^(${ENV_DB_PATTERNS})=" "$envfile" 2>/dev/null | head -1 | cut -d= -f1)"
            if [[ -n "$env_match" ]]; then
                db_present="true"
                # Map env var to DB service name
                case "$env_match" in
                    DATABASE_URL|DB_HOST|DB_URL) db_services="database" ;;
                    REDIS_URL)                   db_services="redis" ;;
                    MONGO_URI|MONGODB_URI)        db_services="mongo" ;;
                    *)                           db_services="database" ;;
                esac
                db_confidence="inferred"
                break
            fi
        fi
    done
fi

echo "db_present=${db_present}"
echo "db_services=${db_services}"
echo "db_confidence=${db_confidence}"

# ── Category 8: File presence checks ──────────────────────────────────────────
MARKER_FILES=(
    "CLAUDE.md"
    "KNOWN-ISSUES.md"
    ".pre-commit-config.yaml"
    ".claude/dso-config.conf"
)

files_present=""
for marker in "${MARKER_FILES[@]}"; do
    if [[ -f "$PROJECT_DIR/$marker" ]]; then
        if [[ -n "$files_present" ]]; then
            files_present="${files_present},${marker}"
        else
            files_present="${marker}"
        fi
    fi
done

echo "files_present=${files_present}"
echo "files_present_confidence=confirmed"

# ── Category 4: CI workflow analysis ──────────────────────────────────────────
ci_workflow_names=""
ci_workflow_test_guarded="false"
ci_workflow_lint_guarded="false"
ci_workflow_format_guarded="false"
ci_workflow_confidence="low"

WORKFLOWS_DIR="$PROJECT_DIR/.github/workflows"
if [[ -d "$WORKFLOWS_DIR" ]]; then
    _wf_found=0
    for wf_file in "$WORKFLOWS_DIR"/*.yml "$WORKFLOWS_DIR"/*.yaml; do
        [[ -f "$wf_file" ]] || continue
        _wf_found=1

        # Extract workflow name from "name: ..." line.
        wf_name="$(grep -E '^name:' "$wf_file" | head -1 | sed 's/^name:\s*//' | tr -d '"'"'")"
        if [[ -n "$wf_name" ]]; then
            if [[ -n "$ci_workflow_names" ]]; then
                ci_workflow_names="${ci_workflow_names},${wf_name}"
            else
                ci_workflow_names="${wf_name}"
            fi
        fi

        # Check for test/lint/format invocations in the workflow.
        if grep -qE '(make test|npm (run )?test|yarn test|pytest|run: test|jest|cargo test|go test)' "$wf_file" 2>/dev/null; then
            ci_workflow_test_guarded="true"
        fi
        if grep -qE '(make lint|npm (run )?lint|yarn lint|ruff check|eslint|flake8|golangci|cargo clippy)' "$wf_file" 2>/dev/null; then
            ci_workflow_lint_guarded="true"
        fi
        if grep -qE '(make format|npm (run )?format|yarn format|ruff format|prettier|gofmt|rustfmt)' "$wf_file" 2>/dev/null; then
            ci_workflow_format_guarded="true"
        fi
    done
    if [[ "$_wf_found" -eq 1 ]]; then
        ci_workflow_confidence="high"
    fi
fi

echo "ci_workflow_names=${ci_workflow_names}"
echo "ci_workflow_test_guarded=${ci_workflow_test_guarded}"
echo "ci_workflow_lint_guarded=${ci_workflow_lint_guarded}"
echo "ci_workflow_format_guarded=${ci_workflow_format_guarded}"
echo "ci_workflow_confidence=${ci_workflow_confidence}"

# ── Category 7: Installed CLI dependencies ────────────────────────────────────
# Check for common CLI tools that might be relevant to the project.
CLI_TOOLS=(
    "git"
    "docker"
    "make"
    "python3"
    "node"
    "poetry"
    "cargo"
    "go"
    "ruff"
    "jq"
    "gh"
)

installed_deps=""
for tool in "${CLI_TOOLS[@]}"; do
    if command -v "$tool" &>/dev/null; then
        if [[ -n "$installed_deps" ]]; then
            installed_deps="${installed_deps},${tool}"
        else
            installed_deps="${tool}"
        fi
    fi
done

# Check DSO-specific optional dependencies with individual boolean keys.
if command -v acli >/dev/null 2>&1; then
    echo "acli_installed=true"
    if [[ -n "$installed_deps" ]]; then installed_deps="${installed_deps},acli"; else installed_deps="acli"; fi
else
    echo "acli_installed=false"
fi

if command -v pre-commit >/dev/null 2>&1; then
    echo "pre_commit_installed=true"
    if [[ -n "$installed_deps" ]]; then installed_deps="${installed_deps},pre-commit"; else installed_deps="pre-commit"; fi
else
    echo "pre_commit_installed=false"
fi

if command -v shasum >/dev/null 2>&1; then
    echo "shasum_installed=true"
    if [[ -n "$installed_deps" ]]; then installed_deps="${installed_deps},shasum"; else installed_deps="shasum"; fi
else
    echo "shasum_installed=false"
fi

if python3 -c 'import yaml' >/dev/null 2>&1; then
    echo "pyyaml_installed=true"
    if [[ -n "$installed_deps" ]]; then installed_deps="${installed_deps},pyyaml"; else installed_deps="pyyaml"; fi
else
    echo "pyyaml_installed=false"
fi

echo "installed_deps=${installed_deps}"
echo "installed_deps_confidence=confirmed"

# ── Category 9: Port numbers from .claude/dso-config.conf ────────────────────
ports=""

if [[ -f "$PROJECT_DIR/.claude/dso-config.conf" ]]; then
    # Extract values that look like port numbers (numeric values for *_port keys).
    port_values="$(grep -E '_port\s*=' "$PROJECT_DIR/.claude/dso-config.conf" \
        | sed 's/.*=\s*//' \
        | tr -d '[:space:]' \
        | grep -E '^[0-9]+$' \
        | sort -u \
        | tr '\n' ',' \
        | sed 's/,$//')"
    ports="${port_values}"
fi

echo "ports=${ports}"
echo "ports_confidence=confirmed"

# ── Category 10: Version file candidates ──────────────────────────────────────
version_files=""

# package.json with "version" key
if [[ -f "$PROJECT_DIR/package.json" ]]; then
    has_version="$(python3 - "$PROJECT_DIR/package.json" <<'PYEOF'
import sys, json
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    if "version" in data:
        print("yes")
except Exception:
    pass
PYEOF
)"
    if [[ "$has_version" == "yes" ]]; then
        version_files="package.json"
    fi
fi

# pyproject.toml with version = "..." field
if [[ -f "$PROJECT_DIR/pyproject.toml" ]]; then
    if grep -qE '^version\s*=' "$PROJECT_DIR/pyproject.toml"; then
        if [[ -n "$version_files" ]]; then
            version_files="${version_files},pyproject.toml"
        else
            version_files="pyproject.toml"
        fi
    fi
fi

echo "version_files=${version_files}"
echo "version_files_confidence=confirmed"
