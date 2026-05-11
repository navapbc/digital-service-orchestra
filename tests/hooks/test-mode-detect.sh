#!/usr/bin/env bash
# tests/hooks/test-mode-detect.sh
# Behavioral tests for plugins/dso/scripts/mode-detect.sh
#
# mode-detect.sh outputs 'ci-pr' when ALL three conditions are met:
#   - enforcement.strategy=ci  (from dso-config.conf)
#   - merge.strategy=pr        (from dso-config.conf)
#   - git remote URL is non-empty
# Otherwise outputs 'local'.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
source "$SCRIPT_DIR/../lib/assert.sh"

TARGET_SCRIPT="$REPO_ROOT/plugins/dso/scripts/mode-detect.sh"

# ── RED gate: fail immediately if mode-detect.sh does not exist ──
if [[ ! -f "$TARGET_SCRIPT" ]]; then
    printf "FAIL: mode-detect.sh does not exist at: %s\n" "$TARGET_SCRIPT" >&2
    (( ++FAIL ))
    print_summary
fi

# ── Shared fixture setup ──
_TEST_TMPDIRS=()
cleanup() {
    for d in "${_TEST_TMPDIRS[@]:-}"; do
        rm -rf "$d"
    done
}
trap cleanup EXIT

make_tmpdir() {
    local d
    d=$(mktemp -d)
    _TEST_TMPDIRS+=("$d")
    printf '%s' "$d"
}

# Helper: create a mock 'git' binary that intercepts 'remote get-url origin'
# and returns the given URL (empty string means no remote configured).
make_git_stub() {
    local bin_dir="$1"
    local remote_url="$2"
    mkdir -p "$bin_dir"
    cat > "$bin_dir/git" <<STUB
#!/usr/bin/env bash
# Minimal git stub for mode-detect tests
if [[ "\$*" == "remote get-url origin" ]]; then
    if [[ -n "${remote_url}" ]]; then
        printf '%s\n' "${remote_url}"
        exit 0
    else
        printf 'error: No such remote '\''origin'\''\n' >&2
        exit 2
    fi
fi
# Fall through to real git for all other subcommands
exec "$(command -v git)" "\$@"
STUB
    chmod +x "$bin_dir/git"
}

# Helper: write a minimal dso-config.conf
make_config() {
    local config_file="$1"
    local enforcement="$2"
    local merge="$3"
    cat > "$config_file" <<CFG
enforcement.strategy=${enforcement}
merge.strategy=${merge}
CFG
}

# ── Case 1: local when remote is empty ──
# Given: enforcement.strategy=ci, merge.strategy=pr
# When:  git remote get-url origin returns empty (no remote)
# Then:  mode-detect.sh outputs 'local'
test_mode_detect_local_empty_remote() {
    local tmp_dir bin_dir config_file output
    tmp_dir=$(make_tmpdir)
    bin_dir="${tmp_dir}/bin"
    config_file="${tmp_dir}/dso-config.conf"

    make_git_stub "$bin_dir" ""
    make_config "$config_file" "ci" "pr"

    output=$(PATH="${bin_dir}:${PATH}" DSO_CONFIG_PATH="$config_file" bash "$TARGET_SCRIPT" 2>/dev/null)
    assert_eq "local_when_no_remote" "local" "$output"
}

# ── Case 2: ci-pr when all three conditions are met ──
# Given: enforcement.strategy=ci, merge.strategy=pr
# When:  git remote get-url origin returns a non-empty URL
# Then:  mode-detect.sh outputs 'ci-pr'
test_mode_detect_ci_pr() {
    local tmp_dir bin_dir config_file output
    tmp_dir=$(make_tmpdir)
    bin_dir="${tmp_dir}/bin"
    config_file="${tmp_dir}/dso-config.conf"

    make_git_stub "$bin_dir" "https://github.com/org/repo"
    make_config "$config_file" "ci" "pr"

    output=$(PATH="${bin_dir}:${PATH}" DSO_CONFIG_PATH="$config_file" bash "$TARGET_SCRIPT" 2>/dev/null)
    assert_eq "ci_pr_all_conditions_met" "ci-pr" "$output"
}

# ── Case 3: local when enforcement.strategy is not 'ci' ──
# Given: enforcement.strategy=local, merge.strategy=pr, remote present
# When:  mode-detect.sh is called
# Then:  output is 'local'
test_mode_detect_non_ci_enforcement() {
    local tmp_dir bin_dir config_file output
    tmp_dir=$(make_tmpdir)
    bin_dir="${tmp_dir}/bin"
    config_file="${tmp_dir}/dso-config.conf"

    make_git_stub "$bin_dir" "https://github.com/org/repo"
    make_config "$config_file" "local" "pr"

    output=$(PATH="${bin_dir}:${PATH}" DSO_CONFIG_PATH="$config_file" bash "$TARGET_SCRIPT" 2>/dev/null)
    assert_eq "local_when_non_ci_enforcement" "local" "$output"
}

# ── Case 4: local when merge.strategy is not 'pr' ──
# Given: enforcement.strategy=ci, merge.strategy=direct, remote present
# When:  mode-detect.sh is called
# Then:  output is 'local'
test_mode_detect_non_pr_merge() {
    local tmp_dir bin_dir config_file output
    tmp_dir=$(make_tmpdir)
    bin_dir="${tmp_dir}/bin"
    config_file="${tmp_dir}/dso-config.conf"

    make_git_stub "$bin_dir" "https://github.com/org/repo"
    make_config "$config_file" "ci" "direct"

    output=$(PATH="${bin_dir}:${PATH}" DSO_CONFIG_PATH="$config_file" bash "$TARGET_SCRIPT" 2>/dev/null)
    assert_eq "local_when_non_pr_merge" "local" "$output"
}

# ── Run all cases ──
test_mode_detect_local_empty_remote
test_mode_detect_ci_pr
test_mode_detect_non_ci_enforcement
test_mode_detect_non_pr_merge

print_summary
