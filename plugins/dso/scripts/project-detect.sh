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
#   ports=<comma-separated>              — port numbers from workflow-config.conf
#   version_files=<comma-separated>      — files that carry a version field
#
# Exit codes:
#   0 — always (detection always succeeds)
#   1 — argument error (missing or invalid project-dir)

# ── Argument parsing ───────────────────────────────────────────────────────────
if [[ $# -lt 1 ]]; then
    echo "Error: project-dir argument required" >&2
    exit 1
fi

PROJECT_DIR="$1"

if [[ ! -d "$PROJECT_DIR" ]]; then
    echo "Error: not a directory: $PROJECT_DIR" >&2
    exit 1
fi

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
    "workflow-config.conf"
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

WORKFLOWS_DIR="$PROJECT_DIR/.github/workflows"
if [[ -d "$WORKFLOWS_DIR" ]]; then
    for wf_file in "$WORKFLOWS_DIR"/*.yml "$WORKFLOWS_DIR"/*.yaml; do
        [[ -f "$wf_file" ]] || continue

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
fi

echo "ci_workflow_names=${ci_workflow_names}"
echo "ci_workflow_test_guarded=${ci_workflow_test_guarded}"
echo "ci_workflow_lint_guarded=${ci_workflow_lint_guarded}"
echo "ci_workflow_format_guarded=${ci_workflow_format_guarded}"

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

# ── Category 9: Port numbers from workflow-config.conf ────────────────────────
ports=""

if [[ -f "$PROJECT_DIR/workflow-config.conf" ]]; then
    # Extract values that look like port numbers (numeric values for *_port keys).
    port_values="$(grep -E '_port\s*=' "$PROJECT_DIR/workflow-config.conf" \
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
