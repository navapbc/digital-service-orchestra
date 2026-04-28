#!/usr/bin/env bash
set -euo pipefail
# validate-required-checks.sh
# Validates that every check-context name in .github/required-checks.txt
# corresponds to an actual job that emits that context in GitHub Actions
# workflow files.
#
# Usage: validate-required-checks.sh [--checks-file <path>] [--workflows-dir <path>]
#
# Exit codes:
#   0 — all check names matched
#   1 — one or more check names not found in any workflow job

# Defaults relative to repo root (resolved from git)
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CHECKS_FILE="$REPO_ROOT/.github/required-checks.txt"
WORKFLOWS_DIR="$REPO_ROOT/.github/workflows"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --checks-file)
            CHECKS_FILE="${2:-}"
            shift 2
            ;;
        --checks-file=*)
            CHECKS_FILE="${1#--checks-file=}"
            shift
            ;;
        --workflows-dir)
            WORKFLOWS_DIR="${2:-}"
            shift 2
            ;;
        --workflows-dir=*)
            WORKFLOWS_DIR="${1#--workflows-dir=}"
            shift
            ;;
        -h|--help)
            echo "Usage: validate-required-checks.sh [--checks-file <path>] [--workflows-dir <path>]"
            exit 0
            ;;
        *)
            echo "Error: unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

# Validate inputs
if [[ ! -f "$CHECKS_FILE" ]]; then
    echo "Error: checks file not found: $CHECKS_FILE" >&2
    exit 1
fi

if [[ ! -d "$WORKFLOWS_DIR" ]]; then
    echo "Error: workflows directory not found: $WORKFLOWS_DIR" >&2
    exit 1
fi

# Collect non-comment, non-blank lines from checks file
mapfile -t CHECK_NAMES < <(grep -v '^\s*#' "$CHECKS_FILE" | grep -v '^\s*$' || true)

# If nothing to check, exit 0
if [[ ${#CHECK_NAMES[@]} -eq 0 ]]; then
    exit 0
fi

# Delegate YAML parsing and matrix expansion to Python
EXPANDED_JOB_NAMES="$(python3 - "$WORKFLOWS_DIR" <<'PYEOF'
import sys
import os
import re

workflows_dir = sys.argv[1]

expanded_names = set()

for fname in os.listdir(workflows_dir):
    if not (fname.endswith('.yml') or fname.endswith('.yaml')):
        continue
    fpath = os.path.join(workflows_dir, fname)
    try:
        with open(fpath, 'r') as f:
            content = f.read()
    except OSError:
        continue

    # Use simple YAML parsing with PyYAML if available, else regex fallback
    try:
        import yaml
        data = yaml.safe_load(content)
    except ImportError:
        # Minimal regex-based fallback: extract jobs block as text
        data = None
    except Exception:
        data = None

    if data and isinstance(data, dict):
        jobs = data.get('jobs', {})
        if not isinstance(jobs, dict):
            continue
        for job_key, job_val in jobs.items():
            if not isinstance(job_val, dict):
                continue
            job_name = job_val.get('name', job_key)
            if not isinstance(job_name, str):
                job_name = str(job_name)

            # Check if name contains matrix expressions
            if '${{ matrix.' in job_name:
                # Extract matrix values from strategy.matrix
                strategy = job_val.get('strategy', {})
                matrix = strategy.get('matrix', {}) if isinstance(strategy, dict) else {}

                # Support both simple lists and 'include' style matrices
                matrix_vars = {}

                if isinstance(matrix, dict):
                    for k, v in matrix.items():
                        if k == 'include':
                            # include is a list of dicts; extract per-var values
                            if isinstance(v, list):
                                for item in v:
                                    if isinstance(item, dict):
                                        for ik, iv in item.items():
                                            matrix_vars.setdefault(ik, [])
                                            if iv not in matrix_vars[ik]:
                                                matrix_vars[ik].append(iv)
                        elif k != 'exclude':
                            if isinstance(v, list):
                                matrix_vars[k] = v

                if not matrix_vars:
                    # No matrix vars found — emit name as-is (may contain unexpanded expr)
                    expanded_names.add(job_name)
                else:
                    # Generate all combinations of matrix variables
                    import itertools
                    keys = list(matrix_vars.keys())
                    value_lists = [matrix_vars[k] for k in keys]
                    for combo in itertools.product(*value_lists):
                        name = job_name
                        for k, v in zip(keys, combo):
                            name = name.replace('${{ matrix.' + k + ' }}', str(v))
                        expanded_names.add(name)
            else:
                expanded_names.add(job_name)
    else:
        # Regex fallback for when PyYAML is unavailable
        # Extract 'name:' fields that appear as job-level names
        # This is a best-effort heuristic: match lines starting with 2-space indent "name:"
        job_names_raw = re.findall(r'^\s{4}name:\s*(.+)$', content, re.MULTILINE)
        for raw_name in job_names_raw:
            raw_name = raw_name.strip().strip('"\'')
            if '${{ matrix.' in raw_name:
                # Attempt to find matrix values in the same file
                matrix_vals = re.findall(r'^\s+- name:\s*(.+)$', content, re.MULTILINE)
                if matrix_vals:
                    for mv in matrix_vals:
                        mv = mv.strip().strip('"\'')
                        name = re.sub(r'\$\{\{\s*matrix\.\w+\s*\}\}', mv, raw_name)
                        expanded_names.add(name)
                else:
                    expanded_names.add(raw_name)
            else:
                expanded_names.add(raw_name)

for name in sorted(expanded_names):
    print(name)
PYEOF
)"

# Build an array of expanded job names; guard against mapfile injecting
# a single empty-string element when python3 returns no output.
if [[ -z "$EXPANDED_JOB_NAMES" ]]; then
    JOB_NAMES=()
else
    mapfile -t JOB_NAMES <<< "$EXPANDED_JOB_NAMES"
fi

# Check each required check name against expanded job names
UNMATCHED=()
for check in "${CHECK_NAMES[@]}"; do
    found=0
    for job in "${JOB_NAMES[@]}"; do
        if [[ "$job" == "$check" ]]; then
            found=1
            break
        fi
    done
    if [[ $found -eq 0 ]]; then
        UNMATCHED+=("$check")
    fi
done

# Report unmatched names
if [[ ${#UNMATCHED[@]} -gt 0 ]]; then
    echo "ERROR: The following required check names were not found in any workflow job:" >&2
    for name in "${UNMATCHED[@]}"; do
        echo "  - $name" >&2
    done
    echo "" >&2
    echo "Known job names found in $WORKFLOWS_DIR:" >&2
    for job in "${JOB_NAMES[@]}"; do
        echo "  - $job" >&2
    done
    exit 1
fi

exit 0
