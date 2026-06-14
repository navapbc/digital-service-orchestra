#!/usr/bin/env bash
# Validate that every prompt file in the registry satisfies the interface
# contract: required frontmatter keys, a declared category that matches its
# directory, and the self-sufficient body sections (output contract +
# constraints). Exits non-zero if any prompt is non-conforming.
#
# Usage: prompt-registry/scripts/validate-registry.sh [registry-root]
set -uo pipefail

REGISTRY_ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

REQUIRED_KEYS=(id title category operation when_to_use inputs outputs tools determinism model_hint source)
VALID_CATEGORIES="classification review exploration generation verification transformation diagnosis decomposition planning remediation"

fail_count=0
file_count=0

emit() { printf '%s\n' "$1"; }

while IFS= read -r -d '' file; do
    base="$(basename "$file")"
    # Skip non-prompt docs. Prompts live in category subdirectories; any .md
    # directly under the registry root is meta-documentation, not a prompt.
    # README/_TEMPLATE/STATUS plus ALL-CAPS catalog docs (e.g. LENSES.md,
    # INVESTIGATION-LENSES.md) are meta-documentation, not prompts. Prompt
    # files use lowercase kebab-case stems; catalog docs use an all-caps stem.
    stem="${base%.md}"
    case "$base" in
        README.md|_TEMPLATE.md|STATUS.md) continue ;;
    esac
    case "$stem" in
        *[a-z]*) ;;            # lowercase in the stem → a prompt file
        *) continue ;;          # all-caps stem → a catalog/meta doc
    esac
    parent_dir="$(dirname "$file")"
    [[ "$parent_dir" == "$REGISTRY_ROOT" ]] && continue
    # Only files inside a valid category directory are prompts. Reference content
    # (standards/, scripts/) lives in its own directories and is not a prompt.
    parent_cat="$(basename "$parent_dir")"
    grep -qw "$parent_cat" <<<"$VALID_CATEGORIES" || continue
    file_count=$((file_count + 1))
    rel="${file#"$REGISTRY_ROOT"/}"

    # Extract frontmatter (between the first two '---' lines).
    if ! head -1 "$file" | grep -q '^---$'; then
        emit "FAIL $rel: missing YAML frontmatter opener"
        fail_count=$((fail_count + 1))
        continue
    fi
    frontmatter="$(awk 'NR==1{next} /^---$/{exit} {print}' "$file")"

    for key in "${REQUIRED_KEYS[@]}"; do
        if ! grep -qE "^${key}:" <<<"$frontmatter"; then
            emit "FAIL $rel: missing required frontmatter key '${key}'"
            fail_count=$((fail_count + 1))
        fi
    done

    # category must match the containing directory and be in the valid set.
    dir_category="$(basename "$(dirname "$file")")"
    declared_category="$(grep -E '^category:' <<<"$frontmatter" | head -1 | sed -E 's/^category:[[:space:]]*//')"
    if [[ -n "$declared_category" && "$declared_category" != "$dir_category" ]]; then
        emit "FAIL $rel: declared category '$declared_category' != directory '$dir_category'"
        fail_count=$((fail_count + 1))
    fi
    if [[ -n "$declared_category" ]] && ! grep -qw "$declared_category" <<<"$VALID_CATEGORIES"; then
        emit "FAIL $rel: category '$declared_category' is not in the valid set"
        fail_count=$((fail_count + 1))
    fi

    # Body must restate the contract so the prompt is self-sufficient.
    if ! grep -qiE '^##+ .*(output contract|output)' "$file"; then
        emit "FAIL $rel: body has no 'Output contract' section"
        fail_count=$((fail_count + 1))
    fi
    if ! grep -qiE '^##+ .*constraints' "$file"; then
        emit "FAIL $rel: body has no 'Constraints' section"
        fail_count=$((fail_count + 1))
    fi
done < <(find "$REGISTRY_ROOT" -type f -name '*.md' -print0)

emit "---"
emit "Checked $file_count prompt files; $fail_count violation(s)."
[[ "$fail_count" -eq 0 ]]
