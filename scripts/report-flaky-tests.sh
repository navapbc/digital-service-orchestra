#!/usr/bin/env bash
set -uo pipefail
# lockpick-workflow/scripts/report-flaky-tests.sh
# Detects flaky tests from JUnit XML test results and emits GitHub Actions annotations.
#
# Supported detection patterns:
#   1. <rerun> element (pytest-rerunfailures)
#   2. <flakyFailure> / <flakyError> elements (Maven Surefire)
#   3. flaky="true" attribute on <testcase> (Bazel)
#   4. Duplicate testcase entries with mixed pass/fail (generic retry frameworks)
#
# Usage: report-flaky-tests.sh <results-file.xml>
# Exit: always 0 (CI-safe contract)

set -uo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $(basename "$0") <results-file.xml>" >&2
  exit 1
fi

RESULTS_FILE="$1"

if [[ ! -f "$RESULTS_FILE" ]]; then
  echo "No test results file found at $RESULTS_FILE"
  exit 0
fi

# Associative arrays for duplicate-testcase detection (pattern 4)
declare -A seen_with_failure
declare -A seen_without_failure

# Accumulated flaky test names (reported by patterns 1-3 inline)
flaky_tests=""

# Per-testcase state
current_testcase=""
has_rerun=0
has_failure=0
has_surefire_flaky=0
has_bazel_flaky=0
in_testcase=0

while IFS= read -r line; do
  # ── Start of a new testcase ────────────────────────────────────────────────
  if [[ "$line" =~ \<testcase ]]; then
    # Reset per-testcase state
    current_testcase=""
    has_rerun=0
    has_failure=0
    has_surefire_flaky=0
    has_bazel_flaky=0
    in_testcase=1

    # Extract classname
    if [[ "$line" =~ classname= ]]; then
      temp="${line#*classname=\"}"
      classname="${temp%%\"*}"
    else
      classname="unknown"
    fi

    # Extract name (space prefix avoids matching classname=)
    if [[ "$line" =~ [[:space:]]name= ]]; then
      temp="${line#* name=\"}"
      name="${temp%%\"*}"
    else
      name="unknown"
    fi

    current_testcase="${classname}::${name}"

    # Pattern 3 (Bazel): flaky="true" attribute on opening tag
    if [[ "$line" =~ flaky=\"true\" ]]; then
      has_bazel_flaky=1
    fi
  fi

  # ── Pattern 1: <rerun> element ────────────────────────────────────────────
  if [[ "$line" =~ \<rerun ]]; then
    has_rerun=1
  fi

  # ── Pattern 2: Maven Surefire <flakyFailure> / <flakyError> ──────────────
  if [[ "$line" =~ \<flakyFailure || "$line" =~ \<flakyError ]]; then
    has_surefire_flaky=1
  fi

  # ── Track <failure> for pattern 4 ────────────────────────────────────────
  if [[ "$line" =~ \<failure ]]; then
    has_failure=1
  fi

  # ── End of testcase ───────────────────────────────────────────────────────
  if [[ "$line" =~ \</testcase\> ]] && [[ $in_testcase -eq 1 ]]; then
    in_testcase=0

    # Pattern 1: rerun + no failure = flaky via rerun
    if [[ $has_rerun -eq 1 && $has_failure -eq 0 ]]; then
      if [[ -z "$flaky_tests" ]]; then
        flaky_tests="$current_testcase"
      else
        flaky_tests="$flaky_tests
$current_testcase"
      fi
    fi

    # Pattern 2: Maven Surefire flakyFailure/flakyError
    if [[ $has_surefire_flaky -eq 1 ]]; then
      if [[ -z "$flaky_tests" ]]; then
        flaky_tests="$current_testcase"
      else
        flaky_tests="$flaky_tests
$current_testcase"
      fi
    fi

    # Pattern 3: Bazel flaky="true"
    if [[ $has_bazel_flaky -eq 1 ]]; then
      if [[ -z "$flaky_tests" ]]; then
        flaky_tests="$current_testcase"
      else
        flaky_tests="$flaky_tests
$current_testcase"
      fi
    fi

    # Pattern 4: track duplicate testcase names for mixed pass/fail detection
    if [[ -n "$current_testcase" ]]; then
      if [[ $has_failure -eq 1 ]]; then
        seen_with_failure["$current_testcase"]=1
      else
        seen_without_failure["$current_testcase"]=1
      fi
    fi
  fi

done < "$RESULTS_FILE"

# ── Pattern 4 post-processing: names in both arrays are duplicate-flaky ────
for name in "${!seen_with_failure[@]}"; do
  if [[ -n "${seen_without_failure[$name]+x}" ]]; then
    # Only add if not already reported by patterns 1-3
    if [[ "$flaky_tests" != *"$name"* ]]; then
      if [[ -z "$flaky_tests" ]]; then
        flaky_tests="$name"
      else
        flaky_tests="$flaky_tests
$name"
      fi
    fi
  fi
done

# ── Output ─────────────────────────────────────────────────────────────────
if [[ -z "$flaky_tests" ]]; then
  echo "No flaky tests detected."
  exit 0
fi

count=$(echo "$flaky_tests" | wc -l | tr -d ' ')
echo "Found $count flaky test(s):"

while IFS= read -r test; do
  echo "  - $test"
  echo "::warning::Flaky test: $test"
done <<< "$flaky_tests"

exit 0
