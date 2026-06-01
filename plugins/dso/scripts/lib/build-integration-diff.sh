#!/usr/bin/env bash
# build-integration-diff.sh — net-end-state integration diff construction (W2a).
#
# Sourced by llm-review-dispatch-or-skip.sh. Exposes build_net_integration_diff,
# which replaces the chronic-re-flag (CS-10) per-commit `git show` concatenation.
#
# THE BUG IT FIXES (CS-10 / P5): the integration review used to build its diff by
# concatenating `git show --diff-merges=first-parent <sha>` for every unprovenanced
# SHA. When commit A introduces a problem and a later in-range commit D fixes it,
# BOTH hunks appear in the concatenation, so the reviewer flags the already-fixed
# intermediate state (the 2026-05-31 PR #509 cycle-3 false positive).
#
# THE FIX: review the NET END-STATE of the files touched by the unprovenanced
# commits — `git diff <merge-base(MAIN,HEAD)>..HEAD -- <touched-files>` (three-dot).
# An introduce-then-fix within the range collapses to the final state, so it can
# no longer re-flag. The diff stays file-bounded to the unprovenanced set (it is
# NOT the full PR diff), so previously-reviewed files outside that set are not
# re-reviewed. When an unprovenanced commit and an already-covered commit touch
# the SAME file, the file's net end-state is reviewed in full — that is correct,
# not an FP: the combination is genuinely new (see v4 plan W2a; "net diff
# excluding covered hunks" is intentionally NOT attempted — it is ill-defined
# under overlap).
#
# Path handling: filenames are read newline-delimited from `git diff-tree
# --name-only`; core.quotepath=false keeps non-ASCII paths literal. This repo's
# tracked paths contain no embedded newlines, the one shape this cannot represent.

# build_net_integration_diff MAIN_REF HEAD_REF SCOPE_FILE OUT_PATH
#
#   MAIN_REF    base ref (e.g. origin/main) — the three-dot left side.
#   HEAD_REF    the combined staged head whose net state is under review.
#   SCOPE_FILE  file of unprovenanced commit SHAs (one per line).
#   OUT_PATH    destination for the unified diff.
#
# Writes the net-end-state diff to OUT_PATH and prints the touched-file count on
# stdout. Returns:
#   0  success (OUT_PATH written; may be empty if no files were touched)
#   1  git error (caller fails closed — do NOT fall back to a full/own diff)
build_net_integration_diff() {
    local main_ref="$1" head_ref="$2" scope_file="$3" out_path="$4"
    local touched sha
    touched="$(mktemp "${TMPDIR:-/tmp}/dso-touched.XXXXXX")" || return 1

    # Union of files touched by each in-scope SHA. quotepath=false so non-ASCII
    # paths are emitted literally (octal-escaped paths would not match as
    # pathspecs). diff-tree on a SHA gives that commit's own changed paths.
    while IFS= read -r sha; do
        [[ -z "$sha" ]] && continue
        git -c core.quotepath=false diff-tree --no-commit-id --name-only -r "$sha" 2>/dev/null
    done < "$scope_file" | LC_ALL=C sort -u > "$touched"

    if [[ ! -s "$touched" ]]; then
        # No touched files resolvable (e.g. all SHAs are empty-first-parent
        # merges). Emit an empty diff and let the caller decide (it fails closed).
        rm -f "$touched"
        : > "$out_path"
        echo "0"
        return 0
    fi

    # Build the pathspec array (bash 3.2-safe: no mapfile).
    local -a _files=()
    local _f
    while IFS= read -r _f; do
        [[ -n "$_f" ]] && _files+=("$_f")
    done < "$touched"

    # Net end-state: three-dot diff = merge-base(main,head)..head, restricted to
    # the touched files. This is what collapses introduce-then-fix to the final
    # state.
    if ! git -c core.quotepath=false diff "${main_ref}...${head_ref}" -- "${_files[@]}" > "$out_path" 2>/dev/null; then
        rm -f "$touched"
        return 1
    fi

    echo "${#_files[@]}"
    rm -f "$touched"
    return 0
}
