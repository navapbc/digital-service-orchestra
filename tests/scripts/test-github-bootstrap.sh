#!/usr/bin/env bash
# tests/scripts/test-github-bootstrap.sh
# Behavioral tests for plugins/dso/scripts/onboarding/github-bootstrap.sh
#
# Usage: bash tests/scripts/test-github-bootstrap.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"

source "$REPO_ROOT/tests/lib/assert.sh"

SCRIPT="$REPO_ROOT/plugins/dso/scripts/onboarding/github-bootstrap.sh"

# Shared cleanup: accumulate all temp dirs in one array, clean up once at exit
_TMP_DIRS=()
trap 'rm -rf "${_TMP_DIRS[@]}"' EXIT

echo "=== test-github-bootstrap.sh ==="

# -- test_gh_missing_exits_zero -----------------------------------------------
# When gh is not on PATH, script must exit 0 (fail-open, never block onboarding).
# Use PATH=/usr/bin:/bin to exclude homebrew/local bins (where gh lives) while
# keeping essential system utilities — consistent with test-provision-ruleset.sh.
_snapshot_fail
rc=0
env PATH=/usr/bin:/bin bash "$SCRIPT" 2>/dev/null || rc=$?
assert_eq "test_gh_missing_exits_zero exit" "0" "$rc"
assert_pass_if_clean "test_gh_missing_exits_zero"

# -- test_dry_run_exits_zero --------------------------------------------------
# With mocked gh and git, --dry-run flag causes the script to exit 0 without
# making real API calls.
_snapshot_fail
TMP_DIR4="$(mktemp -d)"
_TMP_DIRS+=("$TMP_DIR4")
cat > "$TMP_DIR4/gh" <<'GH_EOF'
#!/usr/bin/env bash
# Mock gh: return fake repo name for view command, else exit 0
if [[ "$*" == *"nameWithOwner"* ]]; then
    echo "mock-owner/mock-repo"
elif [[ "$*" == *"rulesets"* ]]; then
    echo "[]"
fi
exit 0
GH_EOF
chmod +x "$TMP_DIR4/gh"
cat > "$TMP_DIR4/git" <<'GIT_EOF'
#!/usr/bin/env bash
echo "mock-git $*"
exit 0
GIT_EOF
chmod +x "$TMP_DIR4/git"
rc4=0
PATH="$TMP_DIR4:$PATH" bash "$SCRIPT" --dry-run 2>/dev/null || rc4=$?
assert_eq "test_dry_run_exits_zero exit" "0" "$rc4"
assert_pass_if_clean "test_dry_run_exits_zero"

# -- test_repo_flag_parsed ----------------------------------------------------
# --repo flag is accepted and parsed without causing a parse error exit.
_snapshot_fail
TMP_DIR5="$(mktemp -d)"
_TMP_DIRS+=("$TMP_DIR5")
cat > "$TMP_DIR5/gh" <<'GH_EOF'
#!/usr/bin/env bash
if [[ "$*" == *"rulesets"* ]]; then echo "[]"; fi
exit 0
GH_EOF
chmod +x "$TMP_DIR5/gh"
cat > "$TMP_DIR5/git" <<'GIT_EOF'
#!/usr/bin/env bash
echo "mock-git $*"
exit 0
GIT_EOF
chmod +x "$TMP_DIR5/git"
rc5=0
PATH="$TMP_DIR5:$PATH" bash "$SCRIPT" --repo "owner/repo" --dry-run 2>/dev/null || rc5=$?
assert_eq "test_repo_flag_parsed exit" "0" "$rc5"
assert_pass_if_clean "test_repo_flag_parsed"

# -- test_admin_failure_exits_zero --------------------------------------------
# When gh API returns admin=false, script must exit 0 (fail-open).
_snapshot_fail
TMP_DIR7="$(mktemp -d)"
_TMP_DIRS+=("$TMP_DIR7")
cat > "$TMP_DIR7/gh" <<'GH_EOF'
#!/usr/bin/env bash
if [[ "$*" == *"nameWithOwner"* ]]; then
    echo "mock-owner/mock-repo"
elif [[ "$*" == *"rulesets"* ]]; then
    echo "[]"
else
    # repos/<repo> endpoint: admin=false
    printf '{"permissions":{"admin":false}}'
fi
exit 0
GH_EOF
chmod +x "$TMP_DIR7/gh"
_REPO_ROOT7="$(git rev-parse --show-toplevel)"
cat > "$TMP_DIR7/git" <<GIT_EOF
#!/usr/bin/env bash
if [[ "\$*" == *"rev-parse"* ]]; then
    echo "$_REPO_ROOT7"
    exit 0
fi
echo "mock-git \$*"
exit 0
GIT_EOF
chmod +x "$TMP_DIR7/git"
rc7=0
PATH="$TMP_DIR7:$PATH" bash "$SCRIPT" 2>/dev/null || rc7=$?
assert_eq "test_admin_failure_exits_zero exit" "0" "$rc7"
assert_pass_if_clean "test_admin_failure_exits_zero"

# -- test_idempotency_exits_zero ----------------------------------------------
# When the Ruleset already exists in local mode (dso.workflow=local),
# script must exit 0 without re-provisioning.
# Mock: gh returns admin=true and rulesets JSON containing "DSO CI Enforcement".
# Uses a fake REPO_ROOT with dso.workflow=local so the new PR-mode guard
# does not trigger.
_snapshot_fail
TMP_DIR8="$(mktemp -d)"
_TMP_DIRS+=("$TMP_DIR8")
FAKE_ROOT8="$(mktemp -d)"
_TMP_DIRS+=("$FAKE_ROOT8")
mkdir -p "$FAKE_ROOT8/.github"
echo "ci / test" > "$FAKE_ROOT8/.github/required-checks.txt"
mkdir -p "$FAKE_ROOT8/.claude"
echo "dso.workflow=local" > "$FAKE_ROOT8/.claude/dso-config.conf"

cat > "$TMP_DIR8/gh" <<GH_EOF
#!/usr/bin/env bash
if [[ "\$*" == *"nameWithOwner"* ]]; then
    echo "mock-owner/mock-repo"
elif [[ "\$*" == *"rulesets"* ]]; then
    printf '[{"name":"DSO CI Enforcement","id":1}]'
else
    # repos/<repo> endpoint: admin=true
    printf '{"permissions":{"admin":true}}'
fi
exit 0
GH_EOF
chmod +x "$TMP_DIR8/gh"
cat > "$TMP_DIR8/git" <<GIT_EOF
#!/usr/bin/env bash
if [[ "\$*" == *"rev-parse"* ]]; then
    echo "$FAKE_ROOT8"
    exit 0
fi
echo "mock-git \$*"
exit 0
GIT_EOF
chmod +x "$TMP_DIR8/git"

rc8=0
PATH="$TMP_DIR8:$PATH" bash "$SCRIPT" 2>/dev/null || rc8=$?

assert_eq "test_idempotency_exits_zero exit" "0" "$rc8"
assert_pass_if_clean "test_idempotency_exits_zero"

# -- test_missing_checks_file_exits_zero --------------------------------------
# When .github/required-checks.txt is absent, script must exit 0 (fail-open).
# Use a temp dir as the fake REPO_ROOT so the checks file path doesn't exist.
_snapshot_fail
TMP_DIR9="$(mktemp -d)"
_TMP_DIRS+=("$TMP_DIR9")
cat > "$TMP_DIR9/gh" <<GH_EOF
#!/usr/bin/env bash
if [[ "\$*" == *"nameWithOwner"* ]]; then echo "mock-owner/mock-repo"
elif [[ "\$*" == *"rulesets"* ]]; then echo "[]"
else printf '{"permissions":{"admin":true}}'; fi
exit 0
GH_EOF
chmod +x "$TMP_DIR9/gh"
cat > "$TMP_DIR9/git" <<GIT_EOF
#!/usr/bin/env bash
if [[ "\$*" == *"rev-parse"* ]]; then echo "$TMP_DIR9"; exit 0; fi
echo "mock-git \$*"; exit 0
GIT_EOF
chmod +x "$TMP_DIR9/git"
rc9=0
PATH="$TMP_DIR9:$PATH" bash "$SCRIPT" 2>/dev/null || rc9=$?
assert_eq "test_missing_checks_file_exits_zero exit" "0" "$rc9"
assert_pass_if_clean "test_missing_checks_file_exits_zero"

# -- test_happy_path_exits_zero -----------------------------------------------
# Full success path: admin=true, checks file present, ruleset absent, git push
# and provision-ruleset.sh both succeed -> exit 0.
# Copy script to a temp dir so sibling scripts (provision-ruleset.sh,
# validate-required-checks.sh) can be mocked without touching the real tree.
_snapshot_fail
TMP_SCRIPT_DIR="$(mktemp -d)"
_TMP_DIRS+=("$TMP_SCRIPT_DIR")
cp "$SCRIPT" "$TMP_SCRIPT_DIR/github-bootstrap.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP_SCRIPT_DIR/provision-ruleset.sh"
chmod +x "$TMP_SCRIPT_DIR/provision-ruleset.sh"

TMP_BIN10="$(mktemp -d)"
_TMP_DIRS+=("$TMP_BIN10")
FAKE_ROOT10="$(mktemp -d)"
_TMP_DIRS+=("$FAKE_ROOT10")
mkdir -p "$FAKE_ROOT10/.github"
echo "ci / test" > "$FAKE_ROOT10/.github/required-checks.txt"
cat > "$TMP_BIN10/gh" <<GH_EOF
#!/usr/bin/env bash
if [[ "\$*" == *"nameWithOwner"* ]]; then echo "mock-owner/mock-repo"
elif [[ "\$*" == *"rulesets"* ]]; then echo "[]"
else printf '{"permissions":{"admin":true}}'; fi
exit 0
GH_EOF
chmod +x "$TMP_BIN10/gh"
cat > "$TMP_BIN10/git" <<GIT_EOF
#!/usr/bin/env bash
if [[ "\$*" == *"rev-parse"* ]]; then echo "$FAKE_ROOT10"; exit 0; fi
if [[ "\$*" == *"push"* ]]; then exit 0; fi
echo "mock-git \$*"; exit 0
GIT_EOF
chmod +x "$TMP_BIN10/git"
rc10=0
PATH="$TMP_BIN10:$PATH" bash "$TMP_SCRIPT_DIR/github-bootstrap.sh" 2>/dev/null || rc10=$?
assert_eq "test_happy_path_exits_zero exit" "0" "$rc10"
assert_pass_if_clean "test_happy_path_exits_zero"


# -- test_pr_mode_with_existing_ruleset_emits_error ---------------------------
# When dso.workflow=ci-pr and "DSO CI Enforcement" Ruleset already exists,
# script must exit non-zero with guidance to disable the Ruleset.
_snapshot_fail
TMP_DIR_PR1="$(mktemp -d)"
_TMP_DIRS+=("$TMP_DIR_PR1")
FAKE_ROOT_PR1="$(mktemp -d)"
_TMP_DIRS+=("$FAKE_ROOT_PR1")
mkdir -p "$FAKE_ROOT_PR1/.github"
echo "ci / test" > "$FAKE_ROOT_PR1/.github/required-checks.txt"
mkdir -p "$FAKE_ROOT_PR1/.claude"
echo "dso.workflow=ci-pr" > "$FAKE_ROOT_PR1/.claude/dso-config.conf"
cat > "$TMP_DIR_PR1/gh" <<GH_EOF
#!/usr/bin/env bash
if [[ "\$*" == *"nameWithOwner"* ]]; then echo "mock-owner/mock-repo"
elif [[ "\$*" == *"rulesets"* ]]; then printf '[{"name":"DSO CI Enforcement","id":1}]'
else printf '{"permissions":{"admin":true}}'; fi
exit 0
GH_EOF
chmod +x "$TMP_DIR_PR1/gh"
cat > "$TMP_DIR_PR1/git" <<GIT_EOF
#!/usr/bin/env bash
if [[ "\$*" == *"rev-parse"* ]]; then echo "$FAKE_ROOT_PR1"; exit 0; fi
echo "mock-git \$*"; exit 0
GIT_EOF
chmod +x "$TMP_DIR_PR1/git"
rc_pr1=0
stderr_pr1="$(PATH="$TMP_DIR_PR1:$PATH" bash "$SCRIPT" 2>&1 >/dev/null)" || rc_pr1=$?
assert_ne "test_pr_mode_with_existing_ruleset_emits_error exit nonzero" "0" "$rc_pr1"
assert_contains "test_pr_mode_with_existing_ruleset_emits_error stderr has 'disable'" "disable" "$stderr_pr1"
assert_contains "test_pr_mode_with_existing_ruleset_emits_error stderr has 'Ruleset'" "Ruleset" "$stderr_pr1"
assert_pass_if_clean "test_pr_mode_with_existing_ruleset_emits_error"

# -- test_pr_mode_without_existing_ruleset_calls_provision_ruleset ------------
# When dso.workflow=ci-pr and no Ruleset exists, script must invoke provision-
# ruleset.sh and exit 0.
_snapshot_fail
TMP_SCRIPT_DIR_PR2="$(mktemp -d)"
_TMP_DIRS+=("$TMP_SCRIPT_DIR_PR2")
cp "$SCRIPT" "$TMP_SCRIPT_DIR_PR2/github-bootstrap.sh"
PROVISION_CALLED_FILE="$(mktemp)"
_TMP_DIRS+=("$PROVISION_CALLED_FILE")
cat > "$TMP_SCRIPT_DIR_PR2/provision-ruleset.sh" <<PROV_EOF
#!/usr/bin/env bash
echo "provision-called" > "$PROVISION_CALLED_FILE"
exit 0
PROV_EOF
chmod +x "$TMP_SCRIPT_DIR_PR2/provision-ruleset.sh"

TMP_BIN_PR2="$(mktemp -d)"
_TMP_DIRS+=("$TMP_BIN_PR2")
FAKE_ROOT_PR2="$(mktemp -d)"
_TMP_DIRS+=("$FAKE_ROOT_PR2")
mkdir -p "$FAKE_ROOT_PR2/.github"
echo "ci / test" > "$FAKE_ROOT_PR2/.github/required-checks.txt"
mkdir -p "$FAKE_ROOT_PR2/.claude"
echo "dso.workflow=ci-pr" > "$FAKE_ROOT_PR2/.claude/dso-config.conf"
cat > "$TMP_BIN_PR2/gh" <<GH_EOF
#!/usr/bin/env bash
if [[ "\$*" == *"nameWithOwner"* ]]; then echo "mock-owner/mock-repo"
elif [[ "\$*" == *"rulesets"* ]]; then echo "[]"
else printf '{"permissions":{"admin":true}}'; fi
exit 0
GH_EOF
chmod +x "$TMP_BIN_PR2/gh"
cat > "$TMP_BIN_PR2/git" <<GIT_EOF
#!/usr/bin/env bash
if [[ "\$*" == *"rev-parse"* ]]; then echo "$FAKE_ROOT_PR2"; exit 0; fi
if [[ "\$*" == *"push"* ]]; then exit 0; fi
echo "mock-git \$*"; exit 0
GIT_EOF
chmod +x "$TMP_BIN_PR2/git"
rc_pr2=0
PATH="$TMP_BIN_PR2:$PATH" bash "$TMP_SCRIPT_DIR_PR2/github-bootstrap.sh" 2>/dev/null || rc_pr2=$?
assert_eq "test_pr_mode_without_existing_ruleset_calls_provision_ruleset exit" "0" "$rc_pr2"
assert_eq "test_pr_mode_without_existing_ruleset_calls_provision_ruleset provision called" \
    "provision-called" "$(cat "$PROVISION_CALLED_FILE" 2>/dev/null | tr -d '\n')"
assert_pass_if_clean "test_pr_mode_without_existing_ruleset_calls_provision_ruleset"

# -- test_missing_merge_strategy_defaults_to_direct_behavior -----------------
# When dso-config.conf is absent, merge.strategy defaults to "direct" and
# the script must NOT exit 1 due to the conditional — it should proceed
# normally (e.g., exit 0 after admin/checks guards or happy path).
_snapshot_fail
TMP_SCRIPT_DIR_PR3="$(mktemp -d)"
_TMP_DIRS+=("$TMP_SCRIPT_DIR_PR3")
cp "$SCRIPT" "$TMP_SCRIPT_DIR_PR3/github-bootstrap.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP_SCRIPT_DIR_PR3/provision-ruleset.sh"
chmod +x "$TMP_SCRIPT_DIR_PR3/provision-ruleset.sh"

TMP_BIN_PR3="$(mktemp -d)"
_TMP_DIRS+=("$TMP_BIN_PR3")
FAKE_ROOT_PR3="$(mktemp -d)"
_TMP_DIRS+=("$FAKE_ROOT_PR3")
# No .claude/dso-config.conf created — simulates absent config
mkdir -p "$FAKE_ROOT_PR3/.github"
echo "ci / test" > "$FAKE_ROOT_PR3/.github/required-checks.txt"
cat > "$TMP_BIN_PR3/gh" <<GH_EOF
#!/usr/bin/env bash
if [[ "\$*" == *"nameWithOwner"* ]]; then echo "mock-owner/mock-repo"
elif [[ "\$*" == *"rulesets"* ]]; then echo "[]"
else printf '{"permissions":{"admin":true}}'; fi
exit 0
GH_EOF
chmod +x "$TMP_BIN_PR3/gh"
cat > "$TMP_BIN_PR3/git" <<GIT_EOF
#!/usr/bin/env bash
if [[ "\$*" == *"rev-parse"* ]]; then echo "$FAKE_ROOT_PR3"; exit 0; fi
if [[ "\$*" == *"push"* ]]; then exit 0; fi
echo "mock-git \$*"; exit 0
GIT_EOF
chmod +x "$TMP_BIN_PR3/git"
rc_pr3=0
PATH="$TMP_BIN_PR3:$PATH" bash "$TMP_SCRIPT_DIR_PR3/github-bootstrap.sh" 2>/dev/null || rc_pr3=$?
assert_eq "test_missing_merge_strategy_defaults_to_direct_behavior exit" "0" "$rc_pr3"
assert_pass_if_clean "test_missing_merge_strategy_defaults_to_direct_behavior"

print_summary
