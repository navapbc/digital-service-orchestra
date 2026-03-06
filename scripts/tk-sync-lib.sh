#!/usr/bin/env bash
# lockpick-workflow/scripts/tk-sync-lib.sh
# Shared library: detached-index commit-and-push for .tickets/ files.
#
# Provides _sync_ticket_file <absolute_file_path> which:
#   1. Hashes the file into the git object store (git hash-object -w)
#   2. Builds a detached-index commit on refs/heads/main containing the change
#   3. Pushes to origin/main with one fetch-and-rebase retry on non-fast-forward
#
# Design principles:
#   - Fire-and-forget: the function always exits 0; errors are logged to stderr.
#   - Works from any worktree or main repo checkout.
#   - REPO_ROOT can be injected via env var; otherwise resolved via git rev-parse.
#   - The worktree's HEAD, index, and staged files are NEVER touched.
#
# Usage:
#   source scripts/tk-sync-lib.sh
#   _sync_ticket_file /absolute/path/to/.tickets/foo.md
#
# Guard: only load once
[[ "${_TK_SYNC_LIB_LOADED:-}" == "1" ]] && return 0
_TK_SYNC_LIB_LOADED=1

# _clear_ticket_skip_worktree [dir]
#
# Clears all skip-worktree flags on .tickets/ files in the current repo.
# Uses --stdin for batch reliability (replaces fragile xargs -r pattern).
# Safe under set -euo pipefail: || true catches all pipeline failures.
# CWD-dependent: operates on whichever repo the current directory belongs to.
_clear_ticket_skip_worktree() {
    local dir="${1:-.tickets/}"
    git ls-files -v -- "$dir" 2>/dev/null \
        | sed -n 's/^S //p' \
        | git update-index --no-skip-worktree --stdin 2>/dev/null || true
}

# _tk_sync_log <message>
#
# Logs timestamped message to ~/.claude/logs/ticket-sync.log AND stderr.
# Rotates the log when it exceeds 1MB.
_tk_sync_log() {
    local msg
    # shellcheck disable=SC2059
    msg=$(printf "$@")
    local log_dir="$HOME/.claude/logs"
    local log_file="$log_dir/ticket-sync.log"
    local max_bytes=1048576  # 1MB

    # Always emit to stderr for immediate visibility
    printf "%s\n" "$msg" >&2

    # Best-effort file logging
    mkdir -p "$log_dir" 2>/dev/null || return 0

    # Rotate if over 1MB
    if [[ -f "$log_file" ]]; then
        local size
        size=$(wc -c < "$log_file" 2>/dev/null) || size=0
        if [[ "$size" -gt "$max_bytes" ]]; then
            mv -f "$log_file" "${log_file}.1" 2>/dev/null || true
        fi
    fi

    printf "[%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$msg" >> "$log_file" 2>/dev/null || true
}

# ── Merge helpers ────────────────────────────────────────────────────────────
# These functions support field-level merging of ticket files to prevent
# cross-worktree overwrites. All are pure functions (no git state needed).

# _status_rank <status>
# Maps status string to numeric rank for hierarchy comparison.
# Returns: 0 (unknown), 1 (open), 2 (in_progress), 3 (closed)
_status_rank() {
    case "$1" in
        open)        echo 1 ;;
        in_progress) echo 2 ;;
        closed)      echo 3 ;;
        *)           echo 0 ;;
    esac
}

# _parse_frontmatter_field <file> <field_name>
# Extracts a single field value from YAML frontmatter (between --- markers).
# Returns the raw value (including brackets for lists).
_parse_frontmatter_field() {
    local file="$1" field="$2"
    awk -v f="$field" '
        /^---$/ { c++; next }
        c == 1 {
            # Match "field: value" — capture everything after "field: "
            if ($0 ~ "^" f ": ") {
                sub("^" f ": ", "")
                print
                exit
            }
        }
        c >= 2 { exit }
    ' "$file"
}

# _parse_frontmatter_field_str <content_string> <field_name>
# Same as _parse_frontmatter_field but operates on a string instead of a file.
_parse_frontmatter_field_str() {
    local content="$1" field="$2"
    printf '%s\n' "$content" | awk -v f="$field" '
        /^---$/ { c++; next }
        c == 1 {
            if ($0 ~ "^" f ": ") {
                sub("^" f ": ", "")
                print
                exit
            }
        }
        c >= 2 { exit }
    '
}

# _parse_yaml_list <list_string>
# Parses "[a, b, c]" format into newline-separated items.
# Returns empty string for "[]".
_parse_yaml_list() {
    local raw="$1"
    # Strip brackets
    raw="${raw#\[}"
    raw="${raw%\]}"
    # Trim whitespace
    raw="${raw## }"
    raw="${raw%% }"
    [[ -z "$raw" ]] && return 0
    # Split on ", " and output one per line
    printf '%s\n' "$raw" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | grep -v '^$'
}

# _format_yaml_list <newline-separated items>
# Formats newline-separated items back into "[a, b, c]" YAML inline format.
_format_yaml_list() {
    local items="$1"
    if [[ -z "$items" ]]; then
        echo "[]"
        return
    fi
    local result
    result=$(printf '%s\n' "$items" | sort -u | paste -sd ',' - | sed 's/,/, /g')
    printf '[%s]' "$result"
}

# _extract_body <file>
# Extracts body content (between second --- and ## Notes).
_extract_body() {
    local file="$1"
    awk '
        /^---$/ { c++; next }
        c >= 2 && /^## Notes/ { exit }
        c >= 2 { print }
    ' "$file"
}

# _extract_notes_raw <file>
# Extracts everything from "## Notes" to end of file (raw text).
_extract_notes_raw() {
    local file="$1"
    awk '/^## Notes/{found=1; next} found{print}' "$file"
}

# _extract_note_blocks <file>
# Parses note blocks from a file. Outputs blocks separated by \x00.
# Each block is the raw text of one note (including <!-- markers -->).
# Format per block: timestamp\tnote_id\traw_lines
_extract_note_blocks() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    grep -q '^## Notes' "$file" || return 0

    awk '
        /^## Notes/ { in_notes=1; next }
        !in_notes { next }
        /^<!-- note-id: / {
            if (note_id != "") {
                # Flush previous note
                printf "%s\t%s\t%s\000", ts, note_id, buf
            }
            # Extract note-id
            match($0, /note-id: ([a-z0-9-]+)/, m)
            note_id = m[1]
            ts = ""
            buf = $0
            next
        }
        note_id != "" && /^<!-- timestamp: / {
            match($0, /timestamp: (.+) -->/, m)
            ts = m[1]
            buf = buf "\n" $0
            next
        }
        note_id != "" {
            buf = buf "\n" $0
        }
        END {
            if (note_id != "") {
                printf "%s\t%s\t%s\000", ts, note_id, buf
            }
        }
    ' "$file"
}

# _merge_ticket_file <local_file> <main_file> <output_file>
# Merges a local ticket file with main's version.
# Returns 0 on success, 1 if merge not possible (main doesn't exist or parse fails).
# On failure, output_file is NOT written — caller should use local file as-is.
_merge_ticket_file() {
    local local_file="$1" main_file="$2" output_file="$3"

    # If main file doesn't exist, no merge needed
    [[ -f "$main_file" ]] || return 1

    # Verify both files have frontmatter (basic sanity)
    grep -q '^---$' "$local_file" 2>/dev/null || return 1
    grep -q '^---$' "$main_file" 2>/dev/null || return 1

    # Check main has at least 2 --- delimiters (valid frontmatter)
    local main_delim_count
    main_delim_count=$(grep -c '^---$' "$main_file" 2>/dev/null) || main_delim_count=0
    [[ "$main_delim_count" -ge 2 ]] || return 1

    # ── Parse frontmatter fields from both files ──────────────────────────

    # Collect all field names from local frontmatter
    local all_fields
    all_fields=$(awk '/^---$/{c++; next} c==1 && /^[a-z_]+: /{print $1} c>=2{exit}' "$local_file" | sed 's/:$//')
    # Add fields from main that may not be in local
    all_fields=$(printf '%s\n%s' "$all_fields" \
        "$(awk '/^---$/{c++; next} c==1 && /^[a-z_]+: /{print $1} c>=2{exit}' "$main_file" | sed 's/:$//')" \
        | sort -u)

    # ── Build merged frontmatter ──────────────────────────────────────────
    local merged_fm=""

    while IFS= read -r field; do
        [[ -z "$field" ]] && continue
        local local_val main_val merged_val
        local_val=$(_parse_frontmatter_field "$local_file" "$field")
        main_val=$(_parse_frontmatter_field "$main_file" "$field")

        case "$field" in
            id|type)
                # Immutable — local wins
                merged_val="${local_val:-$main_val}"
                ;;
            status)
                # Hierarchy max
                local lr mr
                lr=$(_status_rank "${local_val:-open}")
                mr=$(_status_rank "${main_val:-open}")
                if [[ "$mr" -gt "$lr" ]]; then
                    merged_val="$main_val"
                else
                    merged_val="${local_val:-$main_val}"
                fi
                ;;
            deps|links)
                # Set union
                local local_items main_items union_items
                local_items=$(_parse_yaml_list "${local_val:-[]}")
                main_items=$(_parse_yaml_list "${main_val:-[]}")
                union_items=$(printf '%s\n%s' "$local_items" "$main_items" | grep -v '^$' | sort -u)
                merged_val=$(_format_yaml_list "$union_items")
                ;;
            priority)
                # Min numeric value (lower = higher priority)
                if [[ -n "$local_val" ]] && [[ -n "$main_val" ]]; then
                    if [[ "$main_val" -lt "$local_val" ]] 2>/dev/null; then
                        merged_val="$main_val"
                    else
                        merged_val="$local_val"
                    fi
                else
                    merged_val="${local_val:-$main_val}"
                fi
                ;;
            assignee|parent)
                # Local wins (if local has it; otherwise keep main's)
                merged_val="${local_val:-$main_val}"
                ;;
            jira_key)
                # Non-empty wins; if both non-empty and different, main wins
                if [[ -n "$local_val" ]] && [[ -n "$main_val" ]]; then
                    merged_val="$main_val"
                elif [[ -n "$main_val" ]]; then
                    merged_val="$main_val"
                else
                    merged_val="$local_val"
                fi
                ;;
            created)
                # Earliest timestamp wins (lexicographic comparison works for ISO 8601)
                if [[ -n "$local_val" ]] && [[ -n "$main_val" ]]; then
                    if [[ "$main_val" < "$local_val" ]]; then
                        merged_val="$main_val"
                    else
                        merged_val="$local_val"
                    fi
                else
                    merged_val="${local_val:-$main_val}"
                fi
                ;;
            *)
                # Unknown fields: local wins, fall back to main
                merged_val="${local_val:-$main_val}"
                ;;
        esac

        # Only add field if it has a value
        if [[ -n "$merged_val" ]]; then
            merged_fm="${merged_fm}${field}: ${merged_val}
"
        fi
    done <<< "$all_fields"

    # ── Extract body (local wins) ─────────────────────────────────────────
    local body
    body=$(_extract_body "$local_file")

    # ── Merge notes (union by note-id) ────────────────────────────────────
    local has_local_notes=0 has_main_notes=0
    grep -q '^## Notes' "$local_file" 2>/dev/null && has_local_notes=1
    grep -q '^## Notes' "$main_file" 2>/dev/null && has_main_notes=1

    local merged_notes_section=""
    if [[ "$has_local_notes" -eq 1 ]] || [[ "$has_main_notes" -eq 1 ]]; then
        # Collect all note blocks with their IDs and timestamps
        # We'll use temp files to gather notes from both sources
        local notes_tmp
        notes_tmp=$(mktemp -d)

        # Parse notes from local file
        if [[ "$has_local_notes" -eq 1 ]]; then
            _collect_notes_to_dir "$local_file" "$notes_tmp"
        fi

        # Parse notes from main file (only add if note-id not already present)
        if [[ "$has_main_notes" -eq 1 ]]; then
            _collect_notes_to_dir "$main_file" "$notes_tmp"
        fi

        # Sort notes by timestamp filename and reconstruct
        local sorted_notes=""
        if [[ -n "$(ls -A "$notes_tmp" 2>/dev/null)" ]]; then
            local note_file
            for note_file in $(ls "$notes_tmp" | sort); do
                if [[ -n "$sorted_notes" ]]; then
                    sorted_notes="${sorted_notes}
"
                fi
                sorted_notes="${sorted_notes}$(cat "$notes_tmp/$note_file")"
            done
        fi
        rm -rf "$notes_tmp"

        if [[ -n "$sorted_notes" ]]; then
            merged_notes_section="$sorted_notes"
        fi
    fi

    # ── Write merged file ─────────────────────────────────────────────────
    {
        printf '%s\n' "---"
        printf '%s' "$merged_fm"
        printf '%s\n' "---"
        printf '%s' "$body"
        if [[ -n "$merged_notes_section" ]]; then
            # Ensure blank line before ## Notes
            printf '\n%s\n\n' "## Notes"
            printf '%s\n' "$merged_notes_section"
        fi
    } > "$output_file"

    return 0
}

# _collect_notes_to_dir <file> <output_dir>
# Parses structured notes from a ticket file and writes each to a file
# in output_dir named "<timestamp>_<note-id>" to enable sorted reassembly.
# Skips notes whose note-id already has a file in output_dir (dedup).
_collect_notes_to_dir() {
    local file="$1" out_dir="$2"
    [[ -f "$file" ]] || return 0
    grep -q '^## Notes' "$file" 2>/dev/null || return 0

    local notes_text
    notes_text=$(awk '/^## Notes/{found=1; next} found{print}' "$file")
    [[ -z "$notes_text" ]] && return 0

    local note_id="" timestamp="" buf="" in_note=0

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^\<\!--\ note-id:\ ([a-z0-9-]+)\ --\> ]]; then
            # Flush previous note
            if [[ -n "$note_id" ]] && [[ $in_note -eq 1 ]]; then
                _write_note_file "$out_dir" "$timestamp" "$note_id" "$buf"
            fi
            note_id="${BASH_REMATCH[1]}"
            timestamp=""
            buf="$line"
            in_note=1
            continue
        fi

        if [[ $in_note -eq 1 ]]; then
            if [[ "$line" =~ ^\<\!--\ timestamp:\ (.+)\ --\> ]]; then
                timestamp="${BASH_REMATCH[1]}"
            fi
            buf="${buf}
${line}"
        fi
    done <<< "$notes_text"

    # Flush last note
    if [[ -n "$note_id" ]] && [[ $in_note -eq 1 ]]; then
        _write_note_file "$out_dir" "$timestamp" "$note_id" "$buf"
    fi
}

# _write_note_file <dir> <timestamp> <note_id> <content>
# Writes a note to dir/<timestamp>_<note_id> if not already present.
_write_note_file() {
    local dir="$1" ts="$2" note_id="$3" content="$4"
    # Check if this note-id already exists (dedup)
    if ls "$dir"/*"_${note_id}" 2>/dev/null | grep -q .; then
        return 0
    fi
    # Use timestamp for sorting; default to "9999" if missing so it sorts last
    local sort_key="${ts:-9999-99-99T99:99:99Z}"
    # Trim trailing blank lines from content
    while [[ "$content" == *$'\n' ]]; do
        content="${content%$'\n'}"
    done
    printf '%s\n' "$content" > "${dir}/${sort_key}_${note_id}"
}

# _sync_ticket_file <absolute_file_path>
#
# Commits and pushes a single .tickets/ file to refs/heads/main using
# git plumbing (detached temporary index). Always returns 0.
_sync_ticket_file() {
    local FILE_PATH="$1"
    local MAIN_BRANCH="main"

    # ── Bulk-mode short-circuit ───────────────────────────────────────────────
    # When TK_SYNC_SKIP_WORKTREE_PUSH=1, skip the per-file commit+push.
    # Callers (e.g. reset-tickets.sh) set this during bulk sync and do a
    # single batch commit+push afterward.
    if [[ "${TK_SYNC_SKIP_WORKTREE_PUSH:-}" == "1" ]]; then
        return 0
    fi

    # ── Resolve REPO_ROOT ────────────────────────────────────────────────────
    local _REPO_ROOT="${REPO_ROOT:-}"
    if [[ -z "$_REPO_ROOT" ]]; then
        _REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
            _tk_sync_log "tk-sync-lib: could not resolve REPO_ROOT"
            return 0
        }
    fi

    # ── Guard: file must exist ───────────────────────────────────────────────
    if [[ ! -f "$FILE_PATH" ]]; then
        _tk_sync_log "tk-sync-lib: file not found, skipping: %s" "$FILE_PATH"
        return 0
    fi

    # ── Detached-index commit mechanism ──────────────────────────────────────
    # Build a commit on refs/heads/main without touching the worktree index.

    local MAIN_REF
    MAIN_REF=$(git -C "$_REPO_ROOT" rev-parse "refs/heads/${MAIN_BRANCH}" 2>/dev/null) || MAIN_REF=""

    # Create a temporary index file. mktemp gives us a unique path; we remove
    # the empty file immediately so git can create a fresh binary index.
    # (git read-tree fails with "index file smaller than expected" on a 0-byte file.)
    local TMPINDEX
    TMPINDEX=$(mktemp)
    rm -f "$TMPINDEX"

    # Cleanup trap — remove temp index on any exit path.
    local _orig_tmpindex="$TMPINDEX"
    # REVIEW-DEFENSE: RETURN trap is scoped per function invocation in bash.
    # Each call captures its own $_orig_tmpindex at definition time, so
    # concurrent calls clean up their own temp files correctly.
    trap 'rm -f "$_orig_tmpindex"' RETURN

    # Seed the temporary index from main's full tree.
    # Using only the .tickets/ subtree would create a commit whose tree
    # contains nothing but .tickets/, effectively deleting all other files.
    export GIT_INDEX_FILE="$TMPINDEX"
    if [[ -n "$MAIN_REF" ]]; then
        git -C "$_REPO_ROOT" read-tree "$MAIN_REF" 2>/dev/null || true
    fi

    # Compute path of the changed file relative to the repo root
    local REL_PATH="${FILE_PATH#"$_REPO_ROOT/"}"

    # ── Field-level merge with main's version ────────────────────────────
    # Before hashing, attempt to merge the local file with main's current
    # version to prevent cross-worktree overwrites. If merge fails, fall
    # back to hashing the original local file (current behavior).
    local _MERGE_FILE=""
    if [[ -n "$MAIN_REF" ]]; then
        local _MAIN_CONTENT
        _MAIN_CONTENT=$(git -C "$_REPO_ROOT" cat-file blob "${MAIN_REF}:${REL_PATH}" 2>/dev/null) || _MAIN_CONTENT=""
        if [[ -n "$_MAIN_CONTENT" ]]; then
            local _MAIN_TMPFILE _MERGED_TMPFILE
            _MAIN_TMPFILE=$(mktemp)
            _MERGED_TMPFILE=$(mktemp)
            printf '%s\n' "$_MAIN_CONTENT" > "$_MAIN_TMPFILE"
            if _merge_ticket_file "$FILE_PATH" "$_MAIN_TMPFILE" "$_MERGED_TMPFILE" 2>/dev/null; then
                _MERGE_FILE="$_MERGED_TMPFILE"
            else
                rm -f "$_MERGED_TMPFILE"
            fi
            rm -f "$_MAIN_TMPFILE"
        fi
    fi

    local _HASH_SOURCE="${_MERGE_FILE:-$FILE_PATH}"

    # Stage the changed file into the detached index
    local BLOB_HASH
    BLOB_HASH=$(git -C "$_REPO_ROOT" hash-object -w "$_HASH_SOURCE" 2>/dev/null) || {
        [[ -n "$_MERGE_FILE" ]] && rm -f "$_MERGE_FILE"
        unset GIT_INDEX_FILE
        _tk_sync_log "tk-sync-lib: hash-object failed for %s" "$FILE_PATH"
        return 0
    }
    # Clean up merge temp file after hashing
    [[ -n "$_MERGE_FILE" ]] && rm -f "$_MERGE_FILE"

    git -C "$_REPO_ROOT" update-index --add --cacheinfo "100644,${BLOB_HASH},${REL_PATH}" 2>/dev/null || {
        unset GIT_INDEX_FILE
        _tk_sync_log "tk-sync-lib: update-index failed for %s" "$REL_PATH"
        return 0
    }

    # Write the tree object from the detached index
    local NEW_TREE
    NEW_TREE=$(git -C "$_REPO_ROOT" write-tree 2>/dev/null) || {
        unset GIT_INDEX_FILE
        _tk_sync_log "tk-sync-lib: write-tree failed"
        return 0
    }
    unset GIT_INDEX_FILE

    # Build the commit message
    local COMMIT_MSG
    COMMIT_MSG="chore: sync ticket changes from worktree [skip ci]

Updated: ${REL_PATH}"

    # Create the commit object
    local NEW_COMMIT
    if [[ -n "$MAIN_REF" ]]; then
        NEW_COMMIT=$(git -C "$_REPO_ROOT" commit-tree "$NEW_TREE" -p "$MAIN_REF" -m "$COMMIT_MSG" 2>/dev/null) || {
            _tk_sync_log "tk-sync-lib: commit-tree failed"
            return 0
        }
    else
        # First commit — no parent (fresh repo)
        NEW_COMMIT=$(git -C "$_REPO_ROOT" commit-tree "$NEW_TREE" -m "$COMMIT_MSG" 2>/dev/null) || {
            _tk_sync_log "tk-sync-lib: commit-tree failed (no parent)"
            return 0
        }
    fi

    # Update local refs/heads/main atomically
    if [[ -n "$MAIN_REF" ]]; then
        git -C "$_REPO_ROOT" update-ref "refs/heads/${MAIN_BRANCH}" "$NEW_COMMIT" "$MAIN_REF" 2>/dev/null || {
            _tk_sync_log "tk-sync-lib: update-ref failed"
            return 0
        }
    else
        git -C "$_REPO_ROOT" update-ref "refs/heads/${MAIN_BRANCH}" "$NEW_COMMIT" 2>/dev/null || {
            _tk_sync_log "tk-sync-lib: update-ref failed (no prior ref)"
            return 0
        }
    fi

    # ── Push with retry ──────────────────────────────────────────────────────
    local _push_attempt=0
    local _push_done=0

    while [[ "$_push_done" -eq 0 ]]; do
        local _push_stderr
        _push_stderr=$(git -C "$_REPO_ROOT" push origin \
            "refs/heads/${MAIN_BRANCH}:refs/heads/${MAIN_BRANCH}" 2>&1) && {
            _push_done=1
            break
        }

        if [[ "$_push_attempt" -ge 1 ]]; then
            _tk_sync_log "tk-sync-lib: push failed after retry (attempt %d): %s" \
                "$((_push_attempt + 1))" "$_push_stderr"
            # Push failed — log warning and continue (fire-and-forget)
            _tk_sync_log "tk-sync-lib: ticket changes saved locally but not pushed to origin: %s" \
                "$(basename "$FILE_PATH")"
            return 0
        fi

        # Non-fast-forward: fetch and rebase the ticket commit onto new tip
        git -C "$_REPO_ROOT" fetch origin "${MAIN_BRANCH}" 2>/dev/null || {
            printf "tk-sync-lib: fetch failed during retry: could not fetch origin/%s\n" \
                "$MAIN_BRANCH" >&2
            return 0
        }

        local NEW_MAIN_TIP
        NEW_MAIN_TIP=$(git -C "$_REPO_ROOT" rev-parse "origin/${MAIN_BRANCH}" 2>/dev/null) || {
            _tk_sync_log "tk-sync-lib: could not resolve origin/%s after fetch" "$MAIN_BRANCH"
            return 0
        }

        # Rebase: rebuild the tree on top of the fetched tip.
        # We cannot reuse $NEW_TREE — it was built from the old main tip.
        local RETRY_INDEX
        RETRY_INDEX=$(mktemp)
        rm -f "$RETRY_INDEX"

        GIT_INDEX_FILE="$RETRY_INDEX" \
            git -C "$_REPO_ROOT" read-tree "$NEW_MAIN_TIP" 2>/dev/null || {
            rm -f "$RETRY_INDEX"
            _tk_sync_log "tk-sync-lib: read-tree failed during rebase retry"
            return 0
        }
        GIT_INDEX_FILE="$RETRY_INDEX" \
            git -C "$_REPO_ROOT" update-index \
            --add --cacheinfo "100644,${BLOB_HASH},${REL_PATH}" 2>/dev/null || {
            rm -f "$RETRY_INDEX"
            _tk_sync_log "tk-sync-lib: update-index failed during rebase retry"
            return 0
        }
        local RETRY_TREE
        RETRY_TREE=$(GIT_INDEX_FILE="$RETRY_INDEX" \
            git -C "$_REPO_ROOT" write-tree 2>/dev/null) || {
            rm -f "$RETRY_INDEX"
            _tk_sync_log "tk-sync-lib: write-tree failed during rebase retry"
            return 0
        }
        rm -f "$RETRY_INDEX"

        local REBASED_COMMIT
        REBASED_COMMIT=$(git -C "$_REPO_ROOT" commit-tree "$RETRY_TREE" \
            -p "$NEW_MAIN_TIP" -m "$COMMIT_MSG" 2>/dev/null) || {
            _tk_sync_log "tk-sync-lib: commit-tree failed during rebase retry"
            return 0
        }

        # Re-read the current local ref for CAS — it may differ from
        # $NEW_MAIN_TIP if the initial update-ref (line 150) already moved it.
        local CURRENT_LOCAL_REF
        CURRENT_LOCAL_REF=$(git -C "$_REPO_ROOT" rev-parse "refs/heads/${MAIN_BRANCH}" 2>/dev/null) || CURRENT_LOCAL_REF=""
        git -C "$_REPO_ROOT" update-ref "refs/heads/${MAIN_BRANCH}" \
            "$REBASED_COMMIT" "$CURRENT_LOCAL_REF" 2>/dev/null || {
            _tk_sync_log "tk-sync-lib: update-ref failed during rebase retry"
            return 0
        }

        _push_attempt=$((_push_attempt + 1))
    done

    # ── Update .tickets/.last-sync-hash on successful push ───────────────────
    if [[ "$_push_done" -eq 1 ]]; then
        local TREE_HASH
        TREE_HASH=$(git -C "$_REPO_ROOT" rev-parse \
            "refs/heads/${MAIN_BRANCH}:.tickets" 2>/dev/null) || TREE_HASH=""
        if [[ -n "$TREE_HASH" ]]; then
            printf "%s\n" "$TREE_HASH" > "$_REPO_ROOT/.tickets/.last-sync-hash" 2>/dev/null || true
        fi

        # ── Mark the synced file as skip-worktree ────────────────────────────
        # After a successful push the file is on main; the worktree branch may
        # not track it, which causes `git status` to show it as dirty/untracked.
        # Marking it skip-worktree suppresses that noise without staging the file.
        # This runs against the worktree's own index (GIT_INDEX_FILE is already
        # unset above), so it never touches the detached temp index.
        git -C "$_REPO_ROOT" update-index --skip-worktree "$REL_PATH" 2>/dev/null || true
    fi

    return 0
}

# _sync_ticket_delete <absolute_file_path>
#
# Removes a .tickets/ file from refs/heads/main using git plumbing
# (detached temporary index). The file does NOT need to exist on disk.
# Always returns 0 (fire-and-forget).
_sync_ticket_delete() {
    local FILE_PATH="$1"
    local MAIN_BRANCH="main"

    local _REPO_ROOT="${REPO_ROOT:-}"
    if [[ -z "$_REPO_ROOT" ]]; then
        _REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
            _tk_sync_log "tk-sync-lib: could not resolve REPO_ROOT"
            return 0
        }
    fi

    local MAIN_REF
    MAIN_REF=$(git -C "$_REPO_ROOT" rev-parse "refs/heads/${MAIN_BRANCH}" 2>/dev/null) || {
        _tk_sync_log "tk-sync-lib: no main branch for delete sync"
        return 0
    }

    local TMPINDEX
    TMPINDEX=$(mktemp)
    rm -f "$TMPINDEX"
    local _orig_tmpindex="$TMPINDEX"
    # REVIEW-DEFENSE: RETURN trap is scoped per function invocation in bash.
    # Each call captures its own $_orig_tmpindex at definition time, so
    # concurrent calls clean up their own temp files correctly.
    trap 'rm -f "$_orig_tmpindex"' RETURN

    export GIT_INDEX_FILE="$TMPINDEX"
    git -C "$_REPO_ROOT" read-tree "$MAIN_REF" 2>/dev/null || {
        unset GIT_INDEX_FILE
        return 0
    }

    local REL_PATH="${FILE_PATH#"$_REPO_ROOT/"}"

    # Remove the file from the index (--force-remove works even if file doesn't exist on disk)
    git -C "$_REPO_ROOT" update-index --force-remove "$REL_PATH" 2>/dev/null || {
        unset GIT_INDEX_FILE
        _tk_sync_log "tk-sync-lib: update-index --force-remove failed for %s" "$REL_PATH"
        return 0
    }

    local NEW_TREE
    NEW_TREE=$(git -C "$_REPO_ROOT" write-tree 2>/dev/null) || {
        unset GIT_INDEX_FILE
        return 0
    }
    unset GIT_INDEX_FILE

    local COMMIT_MSG="chore: sync ticket deletion from worktree [skip ci]

Deleted: ${REL_PATH}"

    local NEW_COMMIT
    NEW_COMMIT=$(git -C "$_REPO_ROOT" commit-tree "$NEW_TREE" -p "$MAIN_REF" -m "$COMMIT_MSG" 2>/dev/null) || {
        return 0
    }

    git -C "$_REPO_ROOT" update-ref "refs/heads/${MAIN_BRANCH}" "$NEW_COMMIT" "$MAIN_REF" 2>/dev/null || {
        return 0
    }

    # Push with one retry (same pattern as _sync_ticket_file)
    local _push_stderr
    _push_stderr=$(git -C "$_REPO_ROOT" push origin \
        "refs/heads/${MAIN_BRANCH}:refs/heads/${MAIN_BRANCH}" 2>&1) || {
        # Retry once after fetch
        git -C "$_REPO_ROOT" fetch origin "${MAIN_BRANCH}" 2>/dev/null || return 0
        local NEW_MAIN_TIP
        NEW_MAIN_TIP=$(git -C "$_REPO_ROOT" rev-parse "origin/${MAIN_BRANCH}" 2>/dev/null) || return 0

        local RETRY_INDEX
        RETRY_INDEX=$(mktemp); rm -f "$RETRY_INDEX"
        GIT_INDEX_FILE="$RETRY_INDEX" git -C "$_REPO_ROOT" read-tree "$NEW_MAIN_TIP" 2>/dev/null || { rm -f "$RETRY_INDEX"; return 0; }
        GIT_INDEX_FILE="$RETRY_INDEX" git -C "$_REPO_ROOT" update-index --force-remove "$REL_PATH" 2>/dev/null || { rm -f "$RETRY_INDEX"; return 0; }
        local RETRY_TREE
        RETRY_TREE=$(GIT_INDEX_FILE="$RETRY_INDEX" git -C "$_REPO_ROOT" write-tree 2>/dev/null) || { rm -f "$RETRY_INDEX"; return 0; }
        rm -f "$RETRY_INDEX"
        local REBASED_COMMIT
        REBASED_COMMIT=$(git -C "$_REPO_ROOT" commit-tree "$RETRY_TREE" -p "$NEW_MAIN_TIP" -m "$COMMIT_MSG" 2>/dev/null) || return 0
        git -C "$_REPO_ROOT" update-ref "refs/heads/${MAIN_BRANCH}" "$REBASED_COMMIT" "$NEW_MAIN_TIP" 2>/dev/null || return 0
        git -C "$_REPO_ROOT" push origin "refs/heads/${MAIN_BRANCH}:refs/heads/${MAIN_BRANCH}" 2>/dev/null || {
            _tk_sync_log "tk-sync-lib: delete push failed after retry"
            return 0
        }
    }

    # Update .tickets/.last-sync-hash
    local TREE_HASH
    TREE_HASH=$(git -C "$_REPO_ROOT" rev-parse "refs/heads/${MAIN_BRANCH}:.tickets" 2>/dev/null) || TREE_HASH=""
    if [[ -n "$TREE_HASH" ]]; then
        printf "%s\n" "$TREE_HASH" > "$_REPO_ROOT/.tickets/.last-sync-hash" 2>/dev/null || true
    fi

    return 0
}
# extra comment
