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
# When the Ruleset already exists, script must exit 0 without re-provisioning.
# Mock: gh returns admin=true and rulesets JSON containing "DSO CI Enforcement".
_snapshot_fail
TMP_DIR8="$(mktemp -d)"
_TMP_DIRS+=("$TMP_DIR8")

# Create a real required-checks.txt so the checks-file guard passes
REAL_REPO_ROOT="$(git rev-parse --show-toplevel)"
CHECKS_DIR="$REAL_REPO_ROOT/.github"
CHECKS_FILE_PATH="$CHECKS_DIR/required-checks.txt"
CREATED_CHECKS_FILE=0
if [[ ! -f "$CHECKS_FILE_PATH" ]]; then
    mkdir -p "$CHECKS_DIR"
    echo "ci / test" > "$CHECKS_FILE_PATH"
    CREATED_CHECKS_FILE=1
fi

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
    echo "$REAL_REPO_ROOT"
    exit 0
fi
echo "mock-git \$*"
exit 0
GIT_EOF
chmod +x "$TMP_DIR8/git"

rc8=0
PATH="$TMP_DIR8:$PATH" bash "$SCRIPT" 2>/dev/null || rc8=$?

# Clean up the checks file if we created it
if [[ "$CREATED_CHECKS_FILE" -eq 1 ]]; then
    rm -f "$CHECKS_FILE_PATH"
fi

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

print_summary
