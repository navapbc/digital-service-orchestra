#!/usr/bin/env bash
# tests/lib/git-fixtures.sh
# Shared git repo template for test files.
#
# Creates a template git repo once per process, then cp -r's it for each test
# that needs a fresh repo. ~10x faster than git init + add + commit per test.
#
# Usage:
#   source "$PLUGIN_ROOT/tests/lib/git-fixtures.sh"
#   clone_test_repo "$dest_path"
#
# Provides:
#   clone_test_repo <dest>  — fast-copy a pre-built template repo to <dest>
#
# The template contains:
#   - git init with branch "main"
#   - user.email "test@test.com", user.name "Test"
#   - A README.md with content "initial"
#   - One commit: "init"
#
# Template lifecycle:
#   - Created lazily on first clone_test_repo call
#   - Stored in _GIT_FIXTURE_TEMPLATE_DIR (exported so callers can inspect)
#   - Callers are responsible for their own dest cleanup

# Skip ticket dispatcher's remote sync in test repos (no remote exists).
# The env var is only checked by plugins/dso/scripts/ticket _ensure_initialized;
# harmless for non-ticket tests.
export _TICKET_TEST_NO_SYNC=1

# Temp dir cleanup on exit (guarded for sourced usage — avoid clobbering caller state)
if [[ -z "${_CLEANUP_DIRS+set}" ]]; then
    _CLEANUP_DIRS=()
    _cleanup() { for d in "${_CLEANUP_DIRS[@]}"; do rm -rf "$d"; done; }
    trap _cleanup EXIT
fi

# Global: path to the cached template repo (empty = not yet created)
# Unconditional reset — prevents inherited env from batch runner restarts (e26c-fce4)
_GIT_FIXTURE_TEMPLATE_DIR=""

_ensure_git_fixture_template() {
    if [ -n "$_GIT_FIXTURE_TEMPLATE_DIR" ] && [ -d "$_GIT_FIXTURE_TEMPLATE_DIR/.git" ]; then
        return
    fi
    _GIT_FIXTURE_TEMPLATE_DIR=$(mktemp -d)
    _CLEANUP_DIRS+=("$_GIT_FIXTURE_TEMPLATE_DIR")
    git init -q -b main "$_GIT_FIXTURE_TEMPLATE_DIR"
    git -C "$_GIT_FIXTURE_TEMPLATE_DIR" config user.email "test@test.com"
    git -C "$_GIT_FIXTURE_TEMPLATE_DIR" config user.name "Test"
    echo "initial" > "$_GIT_FIXTURE_TEMPLATE_DIR/README.md"
    git -C "$_GIT_FIXTURE_TEMPLATE_DIR" add -A
    git -C "$_GIT_FIXTURE_TEMPLATE_DIR" commit -q -m "init"
}

# clone_test_repo <dest>
# Fast-copies the template repo to <dest>. <dest> must not already exist.
clone_test_repo() {
    local dest="$1"
    _ensure_git_fixture_template
    cp -r "$_GIT_FIXTURE_TEMPLATE_DIR" "$dest"
}
