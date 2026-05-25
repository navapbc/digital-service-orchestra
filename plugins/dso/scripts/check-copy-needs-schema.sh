#!/usr/bin/env bash
# check-copy-needs-schema.sh — Validate a ## Copy Needs section in a markdown file.
#
# Usage:
#   bash check-copy-needs-schema.sh <file.md>
#
# Exit codes:
#   0   Section conforms to the copy-needs schema
#   1   Section is invalid (errors printed to stderr)
#   2   Usage error or file not found
#
# Schema reference: ${CLAUDE_PLUGIN_ROOT}/docs/contracts/copy-needs-section.md
set -euo pipefail

# ---------------------------------------------------------------------------
# Argument handling
# ---------------------------------------------------------------------------
if [[ $# -lt 1 ]]; then
  echo "ERROR: Usage: $(basename "$0") <file.md>" >&2
  exit 2
fi

INPUT_FILE="$1"

if [[ ! -f "$INPUT_FILE" ]]; then
  echo "ERROR: File not found: $INPUT_FILE" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Controlled vocabularies
# ---------------------------------------------------------------------------
VALID_PAGE_VALUES=(
  application_form
  eligibility_screen
  document_upload
  status_page
  confirmation_page
  login
  signup
  error_page
  dashboard
  review_screen
)

VALID_TYPE_VALUES=(
  heading
  label
  button
  error
  helper_text
  body
  status
  confirmation
)

# ---------------------------------------------------------------------------
# Helper: check if value is in an array
# ---------------------------------------------------------------------------
_in_array() {
  local needle="$1"
  shift
  local item
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

# ---------------------------------------------------------------------------
# Extract the ## Copy Needs section from the file
# ---------------------------------------------------------------------------
# Reads from the "## Copy Needs" heading until the next "## " heading (or EOF).
_extract_copy_needs_section() {
  local file="$1"
  awk '/^## Copy Needs/{found=1; next} found && /^## /{exit} found{print}' "$file"
}

# ---------------------------------------------------------------------------
# Main validation logic
# ---------------------------------------------------------------------------
ERRORS=()

SECTION=$(_extract_copy_needs_section "$INPUT_FILE")

if [[ -z "$SECTION" ]]; then
  echo "ERROR: No '## Copy Needs' section found in: $INPUT_FILE" >&2
  exit 1
fi

# Check schema_version: 1 is present as first non-blank line
FIRST_NONBLANK=$(echo "$SECTION" | grep -m1 -v '^[[:space:]]*$' || true)
if [[ "$FIRST_NONBLANK" != "schema_version: 1" ]]; then
  echo "MISSING_SCHEMA_VERSION: '## Copy Needs' section must begin with 'schema_version: 1'" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Parse items
# Each item begins with a line matching "^- stable_id:" and ends before the
# next such line or end of section. We collect each block and validate it.
# ---------------------------------------------------------------------------

# Split section into per-item blocks using awk:
# An item block starts at a line beginning with "- stable_id:" and ends
# before the next such line.
parse_items() {
  echo "$SECTION" | awk '
    /^- stable_id:/ {
      if (NR > 1 && block != "") {
        print block
        print "---ITEM_END---"
      }
      block = $0
      next
    }
    {
      if (block != "") {
        block = block "\n" $0
      }
    }
    END {
      if (block != "") {
        print block
        print "---ITEM_END---"
      }
    }
  '
}

ITEM_BLOCKS=()
CURRENT_BLOCK=""

while IFS= read -r line; do
  if [[ "$line" == "---ITEM_END---" ]]; then
    ITEM_BLOCKS+=("$CURRENT_BLOCK")
    CURRENT_BLOCK=""
  else
    if [[ -n "$CURRENT_BLOCK" ]]; then
      CURRENT_BLOCK="${CURRENT_BLOCK}"$'\n'"${line}"
    else
      CURRENT_BLOCK="${line}"
    fi
  fi
done < <(parse_items)

if [[ ${#ITEM_BLOCKS[@]} -eq 0 ]]; then
  echo "ERROR: No copy items found in '## Copy Needs' section" >&2
  exit 1
fi

# Track stable_ids for uniqueness
declare -A SEEN_STABLE_IDS

REQUIRED_FIELDS=(stable_id type location page validation_rule)

for block in "${ITEM_BLOCKS[@]}"; do
  # Extract field values from the block using grep
  _get_field() {
    local field="$1"
    local blk="$2"
    # Match "  field: value" or "- field: value" patterns
    # grep returns 1 on no-match; suppress that with || true so set -e doesn't abort
    echo "$blk" | grep -E "^[[:space:]]*(- )?${field}:[[:space:]]" | head -1 | sed -E "s/^[[:space:]]*(- )?${field}:[[:space:]]*//" || true
  }

  stable_id=$(_get_field "stable_id" "$block")
  type_val=$(_get_field "type" "$block")
  location=$(_get_field "location" "$block")
  page=$(_get_field "page" "$block")
  validation_rule=$(_get_field "validation_rule" "$block")

  # Check each required field is present and non-empty
  for field in "${REQUIRED_FIELDS[@]}"; do
    val=$(_get_field "$field" "$block")
    # Strip whitespace
    stripped="${val#"${val%%[![:space:]]*}"}"
    stripped="${stripped%"${stripped##*[![:space:]]}"}"
    if [[ -z "$stripped" ]]; then
      ERRORS+=("MISSING_REQUIRED_FIELD: ${field} (item: '${stable_id:-<unknown>}')")
    fi
  done

  # Check stable_id uniqueness (only if stable_id is present)
  if [[ -n "$stable_id" ]]; then
    if [[ -v SEEN_STABLE_IDS["$stable_id"] ]]; then
      ERRORS+=("DUPLICATE_STABLE_ID: ${stable_id}")
    else
      SEEN_STABLE_IDS["$stable_id"]=1
    fi
  fi

  # Check page is in controlled vocabulary (only if page is present)
  if [[ -n "$page" ]]; then
    if ! _in_array "$page" "${VALID_PAGE_VALUES[@]}"; then
      ERRORS+=("UNKNOWN_PAGE_IDENTIFIER: ${page} (item: '${stable_id:-<unknown>}')")
    fi
  fi

  # Check type is in controlled vocabulary (only if type is present)
  if [[ -n "$type_val" ]]; then
    if ! _in_array "$type_val" "${VALID_TYPE_VALUES[@]}"; then
      ERRORS+=("UNKNOWN_TYPE_VALUE: ${type_val} (item: '${stable_id:-<unknown>}')")
    fi
  fi
done

# ---------------------------------------------------------------------------
# Report results
# ---------------------------------------------------------------------------
if [[ ${#ERRORS[@]} -gt 0 ]]; then
  echo "INVALID: ${INPUT_FILE}" >&2
  for err in "${ERRORS[@]}"; do
    echo "  - ${err}" >&2
  done
  exit 1
fi

echo "OK: ${INPUT_FILE}"
exit 0
