#!/usr/bin/env bash
set -uo pipefail
# scripts/project-detect.sh
# Detect project characteristics by inspecting a target directory.
#
# Usage: project-detect.sh <project-dir>
#   <project-dir>: path to the project directory to inspect
#
# Output (stdout): key=value lines, one per detected attribute.
#
# Schema:
#   stack=<value>                        — from detect-stack.sh
#   targets=<comma-separated>            — Makefile targets or package.json scripts
#   python_version=<value>|unknown       — detected Python version requirement
#   python_version_confidence=high|low   — confidence level for python_version
#   db_present=true|false                — whether a DB service was found
#   db_services=<comma-separated>        — names of DB services found
#   files_present=<comma-separated>      — which marker files exist
#   ci_workflow_names=<comma-separated>  — names of CI workflows found
#   ci_workflow_test_guarded=true|false  — any workflow runs test
#   ci_workflow_lint_guarded=true|false  — any workflow runs lint
#   ci_workflow_format_guarded=true|false — any workflow runs format
#   installed_deps=<comma-separated>     — CLI tools detected as installed
#   ports=<comma-separated>              — port numbers from .claude/dso-config.conf
#   version_files=<comma-separated>      — files that carry a version field
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
# Discovers test suites via Makefile targets and pytest directories.
# Outputs a JSON array to stdout via python3.
_discover_suites() {
    local project_dir="$1"
    local entries=""

    # Makefile heuristic: find targets matching /^test[-_]/
    if [[ -f "$project_dir/Makefile" ]]; then
        local makefile_test_targets
        makefile_test_targets="$(grep -E '^test[-_][a-zA-Z0-9_-]+:' "$project_dir/Makefile" \
            | sed 's/:.*//' || true)"
        local target
        while IFS= read -r target; do
            [[ -z "$target" ]] && continue
            # Derive name by stripping test- or test_ prefix
            local name
            name="$(echo "$target" | sed -E 's/^test[-_]//')"
            if [[ -n "$entries" ]]; then
                entries="${entries},"
            fi
            entries="${entries}${target}=${name}"
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
            # Check if directory contains at least one test_*.py file
            local has_test_files
            has_test_files="$(find "$subdir" -maxdepth 1 -name 'test_*.py' -print -quit 2>/dev/null)"
            if [[ -n "$has_test_files" ]]; then
                local dirname
                dirname="$(basename "$subdir")"
                # Skip if already covered by a Makefile target with same name.
                # Use delimiter-anchored match to prevent substring false positives
                # (e.g. 'unit' falsely matching 'integration_unit').
                if [[ ",${entries}," == *",=${dirname},"* || ",${entries}," == *",pytest:"*"=${dirname},"* ]]; then
                    continue
                fi
                if [[ -n "$entries" ]]; then
                    entries="${entries},"
                fi
                entries="${entries}pytest:${test_root}/${dirname}=${dirname}"
            fi
        done
    fi

    # Generate JSON output via python3.
    # Entries are passed via DSO_SUITE_ENTRIES env var, newline-delimited, to avoid
    # fragility with comma delimiters (Makefile target or directory names could
    # contain commas, silently corrupting a comma-separated argument string).
    DSO_SUITE_ENTRIES="$entries" python3 - <<'PYEOF'
import os, json

entries_raw = os.environ.get("DSO_SUITE_ENTRIES", "")
result = []

if entries_raw:
    for entry_str in entries_raw.split(","):
        entry_str = entry_str.strip()
        if not entry_str:
            continue
        if entry_str.startswith("pytest:"):
            # pytest heuristic entry: pytest:tests/models=models
            rest = entry_str[len("pytest:"):]
            path_part, name = rest.split("=", 1)
            result.append({
                "name": name,
                "command": "pytest " + path_part + "/",
                "speed_class": "unknown",
                "runner": "pytest"
            })
        else:
            # Makefile heuristic entry: test-unit=unit
            target, name = entry_str.split("=", 1)
            result.append({
                "name": name,
                "command": "make " + target,
                "speed_class": "unknown",
                "runner": "make"
            })

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
DETECT_STACK="$SCRIPT_DIR/detect-stack.sh"

# ── Category 2: Stack detection (delegates to detect-stack.sh) ────────────────
if [[ -x "$DETECT_STACK" ]]; then
    stack="$(bash "$DETECT_STACK" "$PROJECT_DIR" 2>/dev/null || echo "unknown")"
else
    stack="unknown"
fi
echo "stack=${stack}"

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

echo "db_present=${db_present}"
echo "db_services=${db_services}"

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
