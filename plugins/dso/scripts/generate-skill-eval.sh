#!/usr/bin/env bash
# plugins/dso/scripts/generate-skill-eval.sh
# Generate a starter evals/promptfooconfig.yaml for a DSO skill.
#
# Usage:
#   generate-skill-eval.sh [--skills-root <path>] <skill-name>
#   generate-skill-eval.sh --help
#
# Exit codes:
#   0  Success (or --help)
#   1  Error (missing skill, existing config, no description)

set -uo pipefail

# ── Defaults ─────────────────────────────────────────────────────────────────
REPO_ROOT="$(git rev-parse --show-toplevel)"
DSO_SKILLS_ROOT="$REPO_ROOT/plugins/dso/skills"

# ── Usage ─────────────────────────────────────────────────────────────────────
_usage() {
    cat <<EOF
Usage:
  generate-skill-eval.sh [--skills-root <path>] <skill-name>
  generate-skill-eval.sh --help

Arguments:
  skill-name            Name of the skill directory under the skills root

Options:
  --skills-root <path>  Override the default skills root directory
                        (default: plugins/dso/skills)
  --help                Show this help message and exit

Exit codes:
  0  Success
  1  Error (skill not found, config already exists, no parseable description)

Examples:
  generate-skill-eval.sh fix-bug
  generate-skill-eval.sh --skills-root /tmp/skills sprint
EOF
}

# ── Argument parsing ─────────────────────────────────────────────────────────
SKILL_NAME=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            _usage
            exit 0
            ;;
        --skills-root)
            if [[ -z "${2:-}" ]]; then
                echo "ERROR: --skills-root requires a path argument" >&2
                exit 1
            fi
            DSO_SKILLS_ROOT="$2"
            shift 2
            ;;
        -*)
            echo "ERROR: Unknown option: $1" >&2
            _usage >&2
            exit 1
            ;;
        *)
            SKILL_NAME="$1"
            shift
            ;;
    esac
done

if [[ -z "$SKILL_NAME" ]]; then
    echo "ERROR: skill name is required" >&2
    _usage >&2
    exit 1
fi

# ── Validate skill directory ──────────────────────────────────────────────────
SKILL_DIR="$DSO_SKILLS_ROOT/$SKILL_NAME"
if [[ ! -d "$SKILL_DIR" ]]; then
    echo "ERROR: Skill directory not found: $SKILL_DIR" >&2
    exit 1
fi

# ── Check for existing evals config ──────────────────────────────────────────
EVAL_CONFIG="$SKILL_DIR/evals/promptfooconfig.yaml"
if [[ -f "$EVAL_CONFIG" ]]; then
    echo "ERROR: evals/promptfooconfig.yaml already exists for skill '$SKILL_NAME'" >&2
    exit 1
fi

SKILL_MD="$SKILL_DIR/SKILL.md"
if [[ ! -f "$SKILL_MD" ]]; then
    echo "ERROR: SKILL.md not found at $SKILL_MD" >&2
    exit 1
fi

# ── Parse description from SKILL.md ──────────────────────────────────────────
# Strategy 1: frontmatter description: field
# Strategy 2: first H2 heading (fence-aware)

DESCRIPTION=""

# Try frontmatter first: look for description: between --- delimiters
_parse_frontmatter_description() {
    local file="$1"
    local in_frontmatter=0
    local first_delim_seen=0
    local desc=""

    while IFS= read -r line; do
        if [[ $first_delim_seen -eq 0 && "$line" == "---" ]]; then
            first_delim_seen=1
            in_frontmatter=1
            continue
        fi
        if [[ $in_frontmatter -eq 1 && "$line" == "---" ]]; then
            # End of frontmatter
            break
        fi
        if [[ $in_frontmatter -eq 1 ]]; then
            # Match: description: "value" or description: value
            if [[ "$line" =~ ^description:[[:space:]]*(.*) ]]; then
                desc="${BASH_REMATCH[1]}"
                # Strip surrounding quotes if present
                if [[ "$desc" =~ ^\"(.*)\"$ ]]; then
                    desc="${BASH_REMATCH[1]}"
                elif [[ "$desc" =~ ^\'(.*)\'$ ]]; then
                    desc="${BASH_REMATCH[1]}"
                fi
                # Unescape \" within the string
                desc="${desc//\\\"/\"}"
                echo "$desc"
                return 0
            fi
        fi
    done < "$file"
    return 1
}

# Try frontmatter
if fm_desc=$(_parse_frontmatter_description "$SKILL_MD" 2>/dev/null); then
    DESCRIPTION="$fm_desc"
fi

# Try H2 extraction if no frontmatter description
if [[ -z "$DESCRIPTION" ]]; then
    _parse_h2_description() {
        local file="$1"
        local in_fence=0

        while IFS= read -r line; do
            # Track fence open/close (``` markers)
            if [[ "$line" =~ ^(\`\`\`) ]]; then
                if [[ $in_fence -eq 0 ]]; then
                    in_fence=1
                else
                    in_fence=0
                fi
                continue
            fi
            # Skip lines inside code fences
            if [[ $in_fence -eq 1 ]]; then
                continue
            fi
            # Match H2 heading outside fences
            if [[ "$line" =~ ^##[[:space:]]+(.*) ]]; then
                echo "${BASH_REMATCH[1]}"
                return 0
            fi
        done < "$file"
        return 1
    }

    if h2_desc=$(_parse_h2_description "$SKILL_MD" 2>/dev/null); then
        DESCRIPTION="$h2_desc"
    fi
fi

if [[ -z "$DESCRIPTION" ]]; then
    echo "ERROR: no parseable description found in SKILL.md for skill '$SKILL_NAME'" >&2
    exit 1
fi

# ── YAML-escape the description ───────────────────────────────────────────────
# Escape for use inside a double-quoted YAML string:
#   backslashes first, then double quotes, then control characters
_yaml_escape() {
    local str="$1"
    # Escape backslashes
    str="${str//\\/\\\\}"
    # Escape double quotes
    str="${str//\"/\\\"}"
    # Collapse newlines to space
    str="${str//$'\n'/ }"
    # Collapse carriage returns
    str="${str//$'\r'/ }"
    echo "$str"
}

ESCAPED_DESC=$(_yaml_escape "$DESCRIPTION")
ESCAPED_NAME=$(_yaml_escape "$SKILL_NAME")
# Truncate for summary usage (first 80 chars)
ESCAPED_DESC_SUMMARY="${ESCAPED_DESC:0:80}"

# ── Generate YAML ─────────────────────────────────────────────────────────────
TMPFILE="$(mktemp)"
trap 'rm -f "$TMPFILE"' EXIT

cat > "$TMPFILE" <<EOF
description: "${ESCAPED_NAME} skill evals"

providers:
  - id: "anthropic:messages:claude-haiku-4-5-20251001"

defaultTest:
  options:
    provider: "anthropic:messages:claude-haiku-4-5-20251001"

prompts:
  - |
    You are the ${ESCAPED_NAME} skill.
    ${ESCAPED_DESC}

    The user says:
    {{prompt}}

tests:
  - description: "TODO: Verify ${ESCAPED_NAME} handles basic input correctly"
    vars:
      prompt: |
        TODO: Replace with a representative input for the ${ESCAPED_NAME} skill
    assert:
      - type: llm-rubric
        value: >
          TODO: Replace with evaluation criteria derived from the skill
          description: ${ESCAPED_DESC_SUMMARY}

  - description: "TODO: Verify ${ESCAPED_NAME} follows behavioral constraints"
    vars:
      prompt: |
        TODO: Replace with an input that tests a behavioral constraint
    assert:
      - type: llm-rubric
        value: >
          TODO: Replace with behavioral constraint verification criteria
          derived from: ${ESCAPED_DESC_SUMMARY}
EOF

# ── Atomic write ──────────────────────────────────────────────────────────────
mkdir -p "$SKILL_DIR/evals"
mv "$TMPFILE" "$EVAL_CONFIG"

echo "Generated evals/promptfooconfig.yaml for skill '$SKILL_NAME'"
