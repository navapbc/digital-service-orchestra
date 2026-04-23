#!/usr/bin/env bash
# tests/scripts/test-create-dso-app-real-url.sh
#
# Real-URL end-to-end validation for the DSO NextJS template + create-dso-app
# installer interface contract. Resolves bug 068c-1e8a (the standard suite at
# tests/scripts/test-create-dso-app.sh stubs git, so it cannot detect real-URL
# breakage of the published template repo).
#
# This test is OPT-IN and is skipped unless RUN_REAL_URL_E2E=1 is set in the
# environment. It performs a real `git clone` against the live template repo at
# https://github.com/navapbc/digital-service-orchestra-nextjs-template, then
# verifies every interface contract surface from
# docs/designs/create-dso-app-template-contract.md.
#
# It does NOT run `npm install` or launch Claude Code — those are out of scope
# for the contract verification path. It exercises only what the installer's
# clone/substitute steps depend on.
#
# Usage:
#   RUN_REAL_URL_E2E=1 bash tests/scripts/test-create-dso-app-real-url.sh
#
# Exit codes:
#   0  — all assertions passed (or test was skipped because opt-in flag absent)
#   1  — at least one assertion failed
#   2  — environment problem (network, gh, git unavailable)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$PLUGIN_ROOT/tests/lib/assert.sh"

TEMPLATE_URL="https://github.com/navapbc/digital-service-orchestra-nextjs-template"
TEMPLATE_OWNER_REPO="navapbc/digital-service-orchestra-nextjs-template"
UPSTREAM_OWNER_REPO="navapbc/template-application-nextjs"

TMPDIRS=()
cleanup() {
    local d
    for d in "${TMPDIRS[@]:-}"; do
        [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d"
    done
}
trap cleanup EXIT

echo "=== test-create-dso-app-real-url.sh ==="

# ── Opt-in gate ──────────────────────────────────────────────────────────────
if [ "${RUN_REAL_URL_E2E:-}" != "1" ]; then
    echo "SKIP: RUN_REAL_URL_E2E not set to 1. To run this test:"
    echo "  RUN_REAL_URL_E2E=1 bash tests/scripts/test-create-dso-app-real-url.sh"
    echo ""
    echo "PASSED: 0  FAILED: 0  (skipped)"
    exit 0
fi

# ── Environment prerequisites ────────────────────────────────────────────────
if ! command -v git >/dev/null 2>&1; then
    echo "ERROR: git not found in PATH" >&2
    exit 2
fi

# ── Test 1: Template repo is publicly accessible ─────────────────────────────
test_template_repo_public_clone() {
    local clone_dir
    clone_dir=$(mktemp -d)
    TMPDIRS+=("$clone_dir/check")

    local clone_ok="no"
    # --no-single-branch is what the installer uses; confirm it works
    if git clone --no-single-branch --depth=1 "$TEMPLATE_URL" "$clone_dir/check" >/dev/null 2>&1; then
        clone_ok="yes"
    fi
    assert_eq "template repo: anonymous git clone --no-single-branch succeeds" "yes" "$clone_ok"
}

# ── Test 2: tickets orphan branch reachable on the remote ────────────────────
test_tickets_branch_reachable() {
    local refs
    refs=$(git ls-remote "$TEMPLATE_URL" tickets 2>/dev/null || true)
    local has_ticket_ref="no"
    if echo "$refs" | grep -q 'refs/heads/tickets'; then
        has_ticket_ref="yes"
    fi
    assert_eq "tickets orphan branch: reachable via git ls-remote" "yes" "$has_ticket_ref"
}

# ── Test 3: SC2 strip-list — no nava-platform machinery in tracked files ─────
test_sc2_strip_list_clean() {
    local clone_dir
    clone_dir=$(mktemp -d)
    TMPDIRS+=("$clone_dir/strip")

    git clone --depth=1 "$TEMPLATE_URL" "$clone_dir/strip" >/dev/null 2>&1 || true

    # SC2 intent is "no nava-platform tooling in the source tree". The Apache-2.0
    # NOTICE necessarily references stripped artifacts as part of §4 attribution
    # (modifications must be enumerated). Excluding NOTICE is the documented
    # interpretation of SC2(a). See docs/designs/create-dso-app-template-contract.md.
    local strip_ok="no"
    if ! ( cd "$clone_dir/strip" && git grep -E 'nava-platform|\.copier-answers|^copier\.yml$|template-only-(bin|docs)|code\.json' -- ':!NOTICE' >/dev/null 2>&1 ); then
        strip_ok="yes"
    fi
    assert_eq "SC2 strip-list: zero matches in source tree (NOTICE excluded — see contract doc)" "yes" "$strip_ok"
}

# ── Test 4: LICENSE preserved unmodified vs upstream ─────────────────────────
test_license_preserved_unmodified() {
    local clone_dir local_blob
    clone_dir=$(mktemp -d)
    TMPDIRS+=("$clone_dir/license")

    git clone --depth=1 "$TEMPLATE_URL" "$clone_dir/license" >/dev/null 2>&1 || true

    if [ ! -f "$clone_dir/license/LICENSE" ]; then
        assert_eq "LICENSE: file present" "yes" "no"
        return
    fi
    local_blob=$(cd "$clone_dir/license" && git hash-object LICENSE)

    local upstream_blob=""
    if command -v gh >/dev/null 2>&1; then
        upstream_blob=$(gh api "repos/$UPSTREAM_OWNER_REPO/contents/LICENSE" --jq .sha 2>/dev/null || true)
    fi

    if [ -z "$upstream_blob" ]; then
        # gh unavailable — fall back to checking that our LICENSE is the canonical
        # Apache 2.0 by hashing a fresh upstream raw download.
        upstream_blob=$(curl -fsSL "https://raw.githubusercontent.com/$UPSTREAM_OWNER_REPO/HEAD/LICENSE" 2>/dev/null \
            | git hash-object --stdin 2>/dev/null || true)
    fi

    assert_eq "LICENSE: blob SHA matches upstream (preserved unmodified)" "$upstream_blob" "$local_blob"
}

# ── Test 5: NOTICE present and pins upstream commit ──────────────────────────
test_notice_apache_attribution() {
    local clone_dir
    clone_dir=$(mktemp -d)
    TMPDIRS+=("$clone_dir/notice")

    git clone --depth=1 "$TEMPLATE_URL" "$clone_dir/notice" >/dev/null 2>&1 || true

    local notice_present="no"
    [ -f "$clone_dir/notice/NOTICE" ] && notice_present="yes"
    assert_eq "NOTICE: file present" "yes" "$notice_present"

    local notice_complete="no"
    if [ -f "$clone_dir/notice/NOTICE" ]; then
        # Must reference upstream owner/repo, an Apache reference, and a pinned SHA
        if grep -q "$UPSTREAM_OWNER_REPO" "$clone_dir/notice/NOTICE" \
           && grep -qiE 'Apache License' "$clone_dir/notice/NOTICE" \
           && grep -qE 'SHA: *[0-9a-f]{40}' "$clone_dir/notice/NOTICE"; then
            notice_complete="yes"
        fi
    fi
    assert_eq "NOTICE: contains upstream ref + Apache ref + pinned SHA" "yes" "$notice_complete"
}

# ── Test 6: Installer-substitution end-to-end with sanitized name ────────────
# This is the SC5 verification: simulate the installer's sed and verify zero
# residual {{PROJECT_NAME}} matches plus a correct package.json name field.
test_installer_substitution_end_to_end() {
    local clone_dir sanitized="demo-proto"
    clone_dir=$(mktemp -d)
    TMPDIRS+=("$clone_dir/subst")

    git clone --depth=1 "$TEMPLATE_URL" "$clone_dir/subst" >/dev/null 2>&1 || true

    # Apply the installer's sed step (mirrors create-dso-app.sh:407-414).
    local files_with
    files_with=$(grep -rl '{{PROJECT_NAME}}' "$clone_dir/subst" --exclude-dir=.git 2>/dev/null || true)

    if [ -n "$files_with" ]; then
        echo "$files_with" | while IFS= read -r f; do
            [[ "$f" == *"/.git/"* ]] && continue
            if sed --version >/dev/null 2>&1; then
                sed -i "s/{{PROJECT_NAME}}/$sanitized/g" "$f"
            else
                sed -i '' "s/{{PROJECT_NAME}}/$sanitized/g" "$f"
            fi
        done
    fi

    local residual
    residual=$(grep -r '{{PROJECT_NAME}}' "$clone_dir/subst" --exclude-dir=.git 2>/dev/null | wc -l | tr -d ' ')
    assert_eq "SC5 substitution: zero residual {{PROJECT_NAME}} matches outside .git/" "0" "$residual"

    local pkg_name
    pkg_name=$(grep '"name"' "$clone_dir/subst/package.json" 2>/dev/null \
        | head -1 \
        | sed -E 's/.*"name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')
    assert_eq "SC5 substitution: package.json name matches sanitized project name" "$sanitized" "$pkg_name"
}

# ── Test 7: DSO infra files are pre-baked (SC3 contract) ─────────────────────
test_dso_infra_files_present() {
    local clone_dir
    clone_dir=$(mktemp -d)
    TMPDIRS+=("$clone_dir/infra")

    git clone --depth=1 "$TEMPLATE_URL" "$clone_dir/infra" >/dev/null 2>&1 || true

    local f
    for f in CLAUDE.md project-understanding.md design-notes.md \
             .claude/ARCH_ENFORCEMENT.md .claude/dso-config.conf \
             .pre-commit-config.yaml .github/workflows/ci.yml; do
        local present="no"
        [ -f "$clone_dir/infra/$f" ] && present="yes"
        assert_eq "DSO infra: $f present in template" "yes" "$present"
    done

    # SC3: dso.plugin_root must be present-but-empty so the installer can fill it
    local plugin_root_line
    plugin_root_line=$(grep '^dso\.plugin_root=' "$clone_dir/infra/.claude/dso-config.conf" 2>/dev/null || true)
    assert_eq "SC3 contract: dso.plugin_root key present (empty value)" "dso.plugin_root=" "$plugin_root_line"
}

# ── Test 8: SC3 — no TODO/TBD/<FILL IN> markers in DSO infra files ───────────
test_no_placeholder_markers_in_infra() {
    local clone_dir
    clone_dir=$(mktemp -d)
    TMPDIRS+=("$clone_dir/markers")

    git clone --depth=1 "$TEMPLATE_URL" "$clone_dir/markers" >/dev/null 2>&1 || true

    local hits
    hits=$(grep -rE '\bTODO\b|\bTBD\b|<FILL IN>' \
        "$clone_dir/markers/CLAUDE.md" \
        "$clone_dir/markers/project-understanding.md" \
        "$clone_dir/markers/design-notes.md" \
        "$clone_dir/markers/SECURITY.md" \
        "$clone_dir/markers/README.md" \
        "$clone_dir/markers/.claude/ARCH_ENFORCEMENT.md" \
        "$clone_dir/markers/.claude/dso-config.conf" \
        "$clone_dir/markers/.pre-commit-config.yaml" \
        "$clone_dir/markers/.github/workflows/ci.yml" \
        2>/dev/null | wc -l | tr -d ' ')
    assert_eq "SC3: zero TODO/TBD/<FILL IN> markers in DSO infra" "0" "$hits"
}

# ── Run all tests ────────────────────────────────────────────────────────────
test_template_repo_public_clone
test_tickets_branch_reachable
test_sc2_strip_list_clean
test_license_preserved_unmodified
test_notice_apache_attribution
test_installer_substitution_end_to_end
test_dso_infra_files_present
test_no_placeholder_markers_in_infra

print_summary
