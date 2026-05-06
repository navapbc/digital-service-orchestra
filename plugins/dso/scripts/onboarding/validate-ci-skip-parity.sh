#!/usr/bin/env bash
set -euo pipefail
# validate-ci-skip-parity.sh
# Asserts that ci-skip.yml contains exactly the no-op stubs needed to satisfy
# branch-protection required checks when ci.yml is skipped by its paths-ignore
# filter (docs-only PRs).
#
# Invariant:
#   set(job names in ci-skip.yml) == set(job names in ci.yml) ∩ set(required-checks.txt entries)
#
# Drift in either direction (missing stub OR orphan stub) exits non-zero.
#
# Usage: validate-ci-skip-parity.sh [--repo-root <path>]
#
# Exit codes:
#   0 — in sync
#   1 — drift detected (or required input file missing)

REPO_ROOT_ARG=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo-root) REPO_ROOT_ARG="${2:-}"; shift 2 ;;
        --repo-root=*) REPO_ROOT_ARG="${1#--repo-root=}"; shift ;;
        -h|--help)
            echo "Usage: validate-ci-skip-parity.sh [--repo-root <path>]"
            exit 0 ;;
        *) echo "Error: unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ -n "$REPO_ROOT_ARG" ]]; then
    REPO_ROOT="$REPO_ROOT_ARG"
else
    REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi

CI_YML="$REPO_ROOT/.github/workflows/ci.yml"
SKIP_YML="$REPO_ROOT/.github/workflows/ci-skip.yml"
CHECKS_FILE="$REPO_ROOT/.github/required-checks.txt"

if [[ ! -f "$CI_YML" ]]; then
    echo "ERROR: ci.yml not found: $CI_YML" >&2
    exit 1
fi
if [[ ! -f "$CHECKS_FILE" ]]; then
    echo "ERROR: required-checks.txt not found: $CHECKS_FILE" >&2
    exit 1
fi

# REVIEW-DEFENSE: PyYAML is a hard dependency, no regex fallback. Unlike
# validate-required-checks.sh — which is called from onboarding contexts where
# pyyaml may not yet be installed — this script runs only inside ci.yml's
# validate-required-checks job, which already runs `pip install pyyaml` (see
# .github/workflows/ci.yml). For local invocation, the explicit ImportError
# message points the user at `pip install pyyaml`. A regex fallback would add
# ~50 lines of fragile parsing for a script with one CI caller.
python3 - "$CI_YML" "$SKIP_YML" "$CHECKS_FILE" <<'PYEOF'
import sys, os
try:
    import yaml
except ImportError:
    print("ERROR: PyYAML is required (pip install pyyaml)", file=sys.stderr)
    sys.exit(1)

ci_yml, skip_yml, checks_file = sys.argv[1], sys.argv[2], sys.argv[3]

def job_names(path):
    if not os.path.isfile(path):
        return None
    with open(path) as f:
        data = yaml.safe_load(f) or {}
    jobs = data.get('jobs') or {}
    out = set()
    for key, val in jobs.items():
        if not isinstance(val, dict):
            continue
        out.add(val.get('name', key))
    return out

ci_jobs = job_names(ci_yml) or set()
skip_jobs = job_names(skip_yml)
with open(checks_file) as f:
    required = {line.strip() for line in f
                if line.strip() and not line.lstrip().startswith('#')}

expected_stubs = ci_jobs & required

if skip_jobs is None:
    if expected_stubs:
        print(f"ERROR: ci-skip.yml is missing but ci.yml emits {len(expected_stubs)} required check(s):",
              file=sys.stderr)
        for n in sorted(expected_stubs):
            print(f"  - {n}", file=sys.stderr)
        print("\nCreate .github/workflows/ci-skip.yml with no-op stubs for these job names.",
              file=sys.stderr)
        sys.exit(1)
    sys.exit(0)

missing = expected_stubs - skip_jobs
extra = skip_jobs - expected_stubs

if missing or extra:
    print("ERROR: ci-skip.yml is out of sync with ci.yml + required-checks.txt", file=sys.stderr)
    if missing:
        print("\n  Missing stubs (required by branch protection but absent from ci-skip.yml):",
              file=sys.stderr)
        for n in sorted(missing):
            print(f"    - {n}", file=sys.stderr)
    if extra:
        print("\n  Orphan stubs (in ci-skip.yml but not a required ci.yml job):",
              file=sys.stderr)
        for n in sorted(extra):
            print(f"    - {n}", file=sys.stderr)
    print("\nFix: align job 'name:' fields across ci.yml, ci-skip.yml, and required-checks.txt.",
          file=sys.stderr)
    sys.exit(1)

sys.exit(0)
PYEOF
