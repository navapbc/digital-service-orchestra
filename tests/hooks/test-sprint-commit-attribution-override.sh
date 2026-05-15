#!/usr/bin/env bash
set -uo pipefail
REPO_ROOT=$(git rev-parse --show-toplevel)
source "$REPO_ROOT/tests/lib/assert.sh"

_script="$REPO_ROOT/plugins/dso/scripts/apply-attribution-trailers.sh"

_script_content=$(cat "$_script")

assert_contains "apply-attribution-trailers.sh: dso.workflow check present" \
    "dso.workflow" "$_script_content"
assert_contains "apply-attribution-trailers.sh: .sprint-active check present" \
    ".sprint-active" "$_script_content"
assert_not_contains "apply-attribution-trailers.sh: DSO_SPRINT_MODE removed" \
    "DSO_SPRINT_MODE" "$_script_content"

# ── Functional test: ci-pr + .sprint-active=1 bypasses attribution.enabled guard ──
_tmp_dir=$(mktemp -d)
trap 'rm -rf "$_tmp_dir"' EXIT

# Create a fake git repo so .sprint-active resolution works
_fake_repo="$_tmp_dir/repo"
mkdir -p "$_fake_repo"
git -C "$_fake_repo" init -q
git -C "$_fake_repo" commit --allow-empty -m "init"
touch "$_fake_repo/.sprint-active"

# Create a minimal JSONL with one entry
_jsonl="$_tmp_dir/attribution-contributors.jsonl"
printf '{"type":"agent","subagent_type":"dso:sprint","model":"claude-sonnet-4-6"}\n' > "$_jsonl"

# Create a commit msg file
_msg_file="$_tmp_dir/commit-msg.txt"
printf 'Test commit\n' > "$_msg_file"

# Create a fake read-config.sh that returns dso.workflow=ci-pr
_scripts_dir="$_tmp_dir/scripts"
mkdir -p "$_scripts_dir"
cat > "$_scripts_dir/read-config.sh" <<'RC'
#!/usr/bin/env bash
key="$1"
if [[ "$key" == "dso.workflow" ]]; then
    echo "ci-pr"
elif [[ "$key" == "attribution.enabled" ]]; then
    echo "false"
fi
exit 0
RC
chmod +x "$_scripts_dir/read-config.sh"

# Create a mock git that supports interpret-trailers
_git_bin="$_tmp_dir/git"
cat > "$_git_bin" <<'GITEOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
    echo "git version 2.40.0"
elif [[ "${1:-}" == "interpret-trailers" ]]; then
    # append a trailer line to the commit-msg file
    _file="${@: -1}"
    echo "DSO-Agent: dso:sprint" >> "$_file"
fi
exit 0
GITEOF
chmod +x "$_git_bin"

_result=$(
    SCRIPTS_DIR="$_scripts_dir" \
    _REPO_ROOT="$_fake_repo" \
    ARTIFACTS_DIR="$_tmp_dir" \
    GIT_BINARY="$_git_bin" \
    bash "$_script" --jsonl "$_jsonl" "$_msg_file" 2>&1
    echo "exit:$?"
)

assert_contains "ci-pr + .sprint-active bypasses attribution guard" \
    "DSO-Agent:" "$(cat "$_msg_file")"

print_summary
