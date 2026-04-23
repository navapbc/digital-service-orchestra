#!/usr/bin/env bash
# Stratified 7-file sampler for large-refactor review path.
#
# Selects 7 files from the current git diff using stratified sampling:
#   - Excludes .test-index, binary files, and generated files
#   - Scores by line count (descending)
#   - Applies directory spread: at most 2 files per directory
#
# Injection contract (for tests):
#   GIT_DIFF_MOCK                  — newline-separated file paths (replaces git diff)
#   BINARY_MOCK_<basename>=1       — treat file as binary
#   LINE_COUNT_MOCK_<basename>=N   — override line count for file
#
# Output:
#   7 file paths on stdout (one per line), exit 0
#   INSUFFICIENT_FILES message on stdout + exit 1 if <7 eligible files

set -uo pipefail

# ── Constants ──────────────────────────────────────────────────────────────────

readonly SAMPLE_SIZE=7
readonly MAX_PER_DIR=2

# ── Helpers ───────────────────────────────────────────────────────────────────

_is_excluded() {
    local filepath="$1"
    local basename
    basename="$(basename "$filepath")"

    # Exclude .test-index
    [[ "$basename" == ".test-index" ]] && return 0

    # Exclude generated file patterns
    [[ "$filepath" == *vendor/* ]] && return 0
    [[ "$filepath" == *node_modules/* ]] && return 0
    [[ "$filepath" == *_generated.* ]] && return 0
    [[ "$filepath" == *.pb.go ]] && return 0

    return 1
}

_is_binary() {
    local filepath="$1"
    local basename
    basename="$(basename "$filepath")"

    # Check mock injection — use printenv to handle dots in basename (valid env var names)
    local mock_val
    mock_val="$(printenv "BINARY_MOCK_${basename}" 2>/dev/null || true)"
    if [[ "$mock_val" == "1" ]]; then
        return 0
    fi

    # Production: use git check-attr
    if [[ -z "${GIT_DIFF_MOCK:-}" ]]; then
        local attr_output
        attr_output="$(git check-attr binary "$filepath" 2>/dev/null)"
        if [[ "$attr_output" == *"binary: set"* ]]; then
            return 0
        fi
    fi

    return 1
}

_get_line_count() {
    local filepath="$1"
    local basename
    basename="$(basename "$filepath")"

    # Check mock injection — use printenv to handle dots in basename
    local mock_val
    mock_val="$(printenv "LINE_COUNT_MOCK_${basename}" 2>/dev/null || true)"
    if [[ -n "$mock_val" ]]; then
        printf '%s' "$mock_val"
        return
    fi

    # Production: parse git diff --stat HEAD
    if [[ -z "${GIT_DIFF_MOCK:-}" ]]; then
        local stat_line
        stat_line="$(git diff --stat HEAD 2>/dev/null | grep -F "$filepath" | head -1)"
        # Format: " filename | 42 +++---"
        local count
        count="$(printf '%s' "$stat_line" | grep -oE '[0-9]+' | head -1)"
        printf '%s' "${count:-0}"
        return
    fi

    printf '0'
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
    # Step 1: Get file list
    local file_list
    if [[ -n "${GIT_DIFF_MOCK:-}" ]]; then
        file_list="$GIT_DIFF_MOCK"
    else
        file_list="$(git diff --name-only HEAD 2>/dev/null)"
    fi

    # Step 2: Filter out excluded and binary files; build eligible list
    # eligible_files: array of "filepath"
    local -a eligible_files=()

    while IFS= read -r filepath; do
        [[ -z "$filepath" ]] && continue

        # Apply exclusions
        if _is_excluded "$filepath"; then
            continue
        fi

        # Apply binary filter
        if _is_binary "$filepath"; then
            continue
        fi

        eligible_files+=("$filepath")
    done <<< "$file_list"

    # Step 3: Count eligible files
    local eligible_count="${#eligible_files[@]}"

    # Step 4: Check threshold
    if [[ "$eligible_count" -lt "$SAMPLE_SIZE" ]]; then
        printf 'INSUFFICIENT_FILES: %d eligible files (minimum %d required)\n' \
            "$eligible_count" "$SAMPLE_SIZE"
        return 1
    fi

    # Step 5: Score each file by line count, build sortable list
    # Format: "<line_count> <filepath>"
    local -a scored=()
    for filepath in "${eligible_files[@]}"; do
        local lc
        lc="$(_get_line_count "$filepath")"
        scored+=("${lc} ${filepath}")
    done

    # Sort by line count descending
    local sorted_files
    sorted_files="$(printf '%s\n' "${scored[@]}" | sort -t' ' -k1,1 -rn)"

    # Step 6: Select 7 files with directory spread
    # At most MAX_PER_DIR files per directory
    declare -A dir_count=()
    local -a selected=()

    # First pass: strict directory cap
    while IFS= read -r scored_line; do
        [[ -z "$scored_line" ]] && continue
        local filepath="${scored_line#* }"
        local dirpath
        dirpath="$(dirname "$filepath")"

        local current_count="${dir_count[$dirpath]:-0}"
        if [[ "$current_count" -lt "$MAX_PER_DIR" ]]; then
            selected+=("$filepath")
            dir_count[$dirpath]=$(( current_count + 1 ))
            if [[ "${#selected[@]}" -ge "$SAMPLE_SIZE" ]]; then
                break
            fi
        fi
    done <<< "$sorted_files"

    # Second pass: relax cap if we don't have enough
    if [[ "${#selected[@]}" -lt "$SAMPLE_SIZE" ]]; then
        # Reset and relax: allow any number per directory
        declare -A dir_count2=()
        local -a selected2=()

        # Add already-selected first (preserve priority)
        for f in "${selected[@]}"; do
            selected2+=("$f")
            local d
            d="$(dirname "$f")"
            dir_count2[$d]=$(( ${dir_count2[$d]:-0} + 1 ))
        done

        # Fill remaining from sorted list, skipping already selected
        while IFS= read -r scored_line; do
            [[ -z "$scored_line" ]] && continue
            local filepath="${scored_line#* }"

            # Check if already in selected2
            local already=0
            for existing in "${selected2[@]}"; do
                if [[ "$existing" == "$filepath" ]]; then
                    already=1
                    break
                fi
            done
            [[ "$already" -eq 1 ]] && continue

            selected2+=("$filepath")
            if [[ "${#selected2[@]}" -ge "$SAMPLE_SIZE" ]]; then
                break
            fi
        done <<< "$sorted_files"

        selected=("${selected2[@]}")
    fi

    # Step 7: Output selected files
    for f in "${selected[@]}"; do
        printf '%s\n' "$f"
    done

    return 0
}

main "$@"
