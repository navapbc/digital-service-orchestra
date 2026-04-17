#!/usr/bin/env bash
# tests/test-readme-structure.sh
# Asserts structural contract for the root README.md:
#   - exists and is substantive (> 500 bytes)
#   - contains INSTALL.md markdown link
#   - contains at least 3 prose paragraphs (each >= 40 non-code chars)
#   - mentions "Digital Service Orchestra"
#   - mentions at least one of: plugin, Claude Code, workflow
#   - first 300 bytes are NOT a fenced code block
#
# RED: current README.md is ~90 bytes placeholder — fails size, paragraph count,
#      and plugin/Claude Code/workflow mention assertions.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
# shellcheck source=tests/lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"

README="$REPO_ROOT/README.md"

test_readme_structure() {
    # --- Assertion 1: README.md exists ---
    if [[ -f "$README" ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: README.md exists\n  expected: file at %s\n  actual:   not found\n" "$README" >&2
        # No point continuing if file is missing
        print_summary
        return
    fi

    # --- Assertion 2: Size > 500 bytes ---
    local size
    size=$(wc -c < "$README")
    if (( size > 500 )); then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: README.md size > 500 bytes\n  expected: > 500\n  actual:   %d\n" "$size" >&2
    fi

    local content
    content=$(< "$README")

    # --- Assertion 3: Contains INSTALL.md markdown link ---
    # Accepts: [INSTALL.md](INSTALL.md) or [anything](INSTALL.md) or [INSTALL.md](./INSTALL.md)
    if python3 -c "
import re, sys
content = open('$README').read()
sys.exit(0 if re.search(r'\[.*?\]\(\.?/?INSTALL\.md\)', content) else 1)
" 2>/dev/null; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: README.md contains INSTALL.md markdown link\n  expected: pattern [text](INSTALL.md)\n  actual:   not found\n" >&2
    fi

    # --- Assertion 4: At least 3 prose paragraphs (each >= 40 chars, not code) ---
    local prose_count
    prose_count=$(python3 -c "
import re
content = open('$README').read()
paragraphs = [p.strip() for p in re.split(r'\n\s*\n', content) if p.strip()]
# Exclude paragraphs that are purely heading, code block, or very short
prose = [
    p for p in paragraphs
    if len(p) >= 40
    and not p.startswith('\`\`\`')
    and not p.startswith('    ')
    and not p.startswith('\t')
]
print(len(prose))
" 2>/dev/null)
    if (( prose_count >= 3 )); then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: README.md has at least 3 prose paragraphs >= 40 chars\n  expected: >= 3\n  actual:   %s\n" "$prose_count" >&2
    fi

    # --- Assertion 5: Mentions "Digital Service Orchestra" ---
    assert_contains "README.md mentions 'Digital Service Orchestra'" "Digital Service Orchestra" "$content"

    # --- Assertion 6: Mentions at least one of: plugin, Claude Code, workflow ---
    if [[ "$content" == *"plugin"* ]] || [[ "$content" == *"Claude Code"* ]] || [[ "$content" == *"workflow"* ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: README.md mentions plugin, Claude Code, or workflow\n  expected: at least one present\n  actual:   none found\n" >&2
    fi

    # --- Assertion 7: First 300 bytes do NOT start with a fenced code block ---
    local first300
    first300=$(python3 -c "
content = open('$README').read()
print(content[:300].lstrip()[:3])
" 2>/dev/null)
    assert_ne "README.md first 300 bytes do not start with fenced code block" '```' "$first300"
}

test_readme_structure
print_summary
