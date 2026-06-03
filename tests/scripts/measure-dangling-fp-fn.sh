#!/usr/bin/env bash
# tests/scripts/measure-dangling-fp-fn.sh
#
# Story 29e7 (CF-8 / E7): FP/FN measurement harness for the sg-based dangling-
# reference matcher (plugins/dso/scripts/ci/check-dangling-references.sh).
#
# Materializes each ground-truth case under
# tests/fixtures/dangling-references-groundtruth/cases/ into a synthetic git repo
# (base on origin/main, head commit), runs the check, and scores TP/FP/FN/TN
# against the case's `expect` verdict. Prints a confusion matrix and FP/FN rates.
#
# Exit codes:
#   0  measurement ran (always — the harness MEASURES; it does not gate)
#   2  harness setup error (missing fixtures, git failure)
#
# Flags:
#   --force-no-sg   run the matcher via its git-grep fallback (sg forced absent)
#                   to measure the fallback path's FP/FN for comparison.
#
# This harness is informational. The GO/FALLBACK recommendation derived from its
# numbers is recorded in the story report, not enforced here.

set -uo pipefail
unset GITHUB_BASE_REF GITHUB_SHA GITHUB_REPOSITORY

REPO_ROOT="$(git rev-parse --show-toplevel)"
CHECK="$REPO_ROOT/plugins/dso/scripts/ci/check-dangling-references.sh"
CASES_DIR="$REPO_ROOT/tests/fixtures/dangling-references-groundtruth/cases"

EXTRA_ENV=()
LABEL="sg path"
if [[ "${1:-}" == "--force-no-sg" ]]; then
    EXTRA_ENV=(DSO_DANGLING_FORCE_NO_SG=1)
    LABEL="git-grep fallback path"
fi

[[ -d "$CASES_DIR" ]] || { echo "ERROR: fixtures dir not found: $CASES_DIR" >&2; exit 2; }

_W="$(mktemp -d "${TMPDIR:-/tmp}/dso-fpfn.XXXXXX")" || exit 2
trap 'rm -rf "$_W"' EXIT

# Build a synthetic repo from a case's base/ and head/ dirs; echo the head SHA.
_build_repo() {
    local case_dir="$1" repo="$2"
    mkdir -p "$repo"
    git -C "$repo" init -q -b main
    git -C "$repo" config user.email t@e.st
    git -C "$repo" config user.name t
    git -C "$repo" config commit.gpgsign false
    cp -R "$case_dir/base/." "$repo/" 2>/dev/null
    git -C "$repo" add -A; git -C "$repo" commit -qm base
    git -C "$repo" init -q --bare "$repo/origin.git"
    git -C "$repo" remote add origin "$repo/origin.git"
    git -C "$repo" push -q origin main
    # Apply head: wipe tracked files, lay down head/.
    git -C "$repo" rm -q -rf . >/dev/null 2>&1
    cp -R "$case_dir/head/." "$repo/" 2>/dev/null
    git -C "$repo" add -A; git -C "$repo" commit -qm head
    git -C "$repo" rev-parse HEAD
}

TP=0; FP=0; FN=0; TN=0; ERR=0
declare -a MISCLASSIFIED=()

echo "=== Dangling-reference FP/FN measurement (${LABEL}) ==="
printf '%-28s %-8s %-8s %s\n' "CASE" "EXPECT" "RESULT" "VERDICT"

for case_dir in "$CASES_DIR"/*/; do
    [[ -d "$case_dir" ]] || continue
    id="$(basename "$case_dir")"
    expect="$(tr -d '[:space:]' < "$case_dir/expect")"
    repo="$_W/$id"
    head_sha="$(_build_repo "$case_dir" "$repo")" || { echo "  $id: BUILD FAILED"; ERR=$((ERR+1)); continue; }

    out="$( cd "$repo" && env DSO_HEAD_SHA="$head_sha" "${EXTRA_ENV[@]}" bash "$CHECK" 2>&1 )"
    rc=$?
    if [[ $rc -eq 1 ]]; then result="FLAGGED"; elif [[ $rc -eq 0 ]]; then result="CLEAN"; else result="ERR($rc)"; fi

    verdict="?"
    if [[ "$expect" == "DANGLING" ]]; then
        if [[ "$result" == "FLAGGED" ]]; then verdict="TP"; TP=$((TP+1)); else verdict="FN"; FN=$((FN+1)); MISCLASSIFIED+=("$id (FN: expected DANGLING, got $result)"); fi
    elif [[ "$expect" == "CLEAN" ]]; then
        if [[ "$result" == "CLEAN" ]]; then verdict="TN"; TN=$((TN+1)); else verdict="FP"; FP=$((FP+1)); MISCLASSIFIED+=("$id (FP: expected CLEAN, got $result)"); fi
    fi
    printf '%-28s %-8s %-8s %s\n' "$id" "$expect" "$result" "$verdict"
done

echo ""
echo "--- Confusion matrix (${LABEL}) ---"
echo "  TP=$TP  FP=$FP  FN=$FN  TN=$TN  (build errors=$ERR)"

_pos=$((TP+FN)); _neg=$((FP+TN))
fp_rate="n/a"; fn_rate="n/a"
[[ $_neg -gt 0 ]] && fp_rate="$(awk "BEGIN{printf \"%.1f%%\", 100*$FP/$_neg}")"
[[ $_pos -gt 0 ]] && fn_rate="$(awk "BEGIN{printf \"%.1f%%\", 100*$FN/$_pos}")"
echo "  FP rate (FP / actual-negatives) = $fp_rate   [$FP / $_neg]"
echo "  FN rate (FN / actual-positives) = $fn_rate   [$FN / $_pos]"

if (( ${#MISCLASSIFIED[@]} > 0 )); then
    echo ""
    echo "  MISCLASSIFIED:"
    for m in "${MISCLASSIFIED[@]}"; do echo "    - $m"; done
fi

echo ""
echo "NOTE: representative fixture set. Full E7 verification (20 real historical"
echo "PRs via live gh data) remains the open step — see fixtures README."
exit 0
