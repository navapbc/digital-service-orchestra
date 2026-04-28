#!/usr/bin/env bash
# github-bootstrap.sh
# Orchestrates the GitHub repository bootstrap during /dso:onboarding:
#   1. Pre-flight checks (gh CLI, admin permissions, checks file)
#   2. Push CI workflow file to main branch (chicken-and-egg: workflow must
#      be on main before the Ruleset can require its status checks)
#   3. Validate required check names against workflow job names
#   4. Create GitHub Ruleset via provision-ruleset.sh
#
# All pre-flight failures are non-fatal (exit 0) — onboarding must not be
# blocked by GitHub configuration steps.
#
# Usage: github-bootstrap.sh [--repo <owner/repo>] [--dry-run]
#
# Exit codes:
#   0 — bootstrap complete, or skipped due to pre-flight failure / idempotent
#   1 — unknown argument

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO=""
DRY_RUN=0

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CHECKS_FILE="$REPO_ROOT/.github/required-checks.txt"

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --repo)
            REPO="${2:-}"
            shift 2
            ;;
        --repo=*)
            REPO="${1#--repo=}"
            shift
            ;;
        *)
            echo "Error: unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

# ── Pre-flight: gh CLI ────────────────────────────────────────────────────────
if ! command -v gh >/dev/null 2>&1; then
    echo "WARNING: gh CLI not found — GitHub Ruleset cannot be provisioned automatically." >&2
    echo "Install gh CLI (https://cli.github.com/) and re-run /dso:onboarding," >&2
    echo "or provision the Ruleset manually using provision-ruleset.sh." >&2
    exit 0
fi

# ── Resolve repo ──────────────────────────────────────────────────────────────
if [[ -z "$REPO" ]]; then
    REPO="$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || echo "")"
    if [[ -z "$REPO" ]]; then
        echo "WARNING: could not detect GitHub repository — skipping Ruleset provisioning." >&2
        echo "Run: bash \"$SCRIPT_DIR/provision-ruleset.sh\" --repo <owner/repo>" >&2
        exit 0
    fi
fi

# ── Dry-run mode (checked before network pre-flights) ─────────────────────────
if [[ "$DRY_RUN" == "1" ]]; then
    echo "=== DRY RUN: No changes will be made ===" >&2
    echo "Would push current HEAD to main on $REPO" >&2
    echo "Would call provision-ruleset.sh --non-interactive --repo $REPO --dry-run" >&2
    exit 0
fi

# ── Pre-flight: admin permissions ─────────────────────────────────────────────
ADMIN_OK="$(gh api "repos/$REPO" 2>/dev/null | python3 -c 'import sys,json; d=json.load(sys.stdin); print(str(d.get("permissions",{}).get("admin",False)).lower())' 2>/dev/null || echo "false")"
if [[ "$ADMIN_OK" != "true" ]]; then
    echo "WARNING: admin permission not confirmed for $REPO — skipping Ruleset provisioning." >&2
    echo "Ensure your GitHub token has admin scope, then run:" >&2
    echo "  bash \"$SCRIPT_DIR/provision-ruleset.sh\" --repo $REPO" >&2
    exit 0
fi

# ── Pre-flight: required-checks.txt ──────────────────────────────────────────
if [[ ! -f "$CHECKS_FILE" ]]; then
    echo "WARNING: .github/required-checks.txt not found — skipping Ruleset provisioning." >&2
    echo "Create .github/required-checks.txt with CI check names, then run:" >&2
    echo "  bash \"$SCRIPT_DIR/provision-ruleset.sh\" --repo $REPO" >&2
    exit 0
fi

# ── Idempotency: skip if Ruleset already exists ───────────────────────────────
if gh api --paginate "repos/$REPO/rulesets" 2>/dev/null | grep -q '"DSO CI Enforcement"'; then
    echo "INFO: Ruleset 'DSO CI Enforcement' already exists on $REPO — skipping." >&2
    exit 0
fi

# ── Push CI workflow to main ───────────────────────────────────────────────────
echo "Pushing CI workflow to main branch on $REPO..." >&2
if ! git push origin HEAD:main; then
    echo "WARNING: git push to main failed — Ruleset provisioning skipped." >&2
    echo "Push manually and then run provision-ruleset.sh to complete setup." >&2
    exit 0
fi

# ── Validate check names (warn-only) ─────────────────────────────────────────
VALIDATE_SCRIPT="$SCRIPT_DIR/validate-required-checks.sh"
if [[ -f "$VALIDATE_SCRIPT" ]]; then
    if ! bash "$VALIDATE_SCRIPT" 2>/dev/null; then
        echo "WARNING: validate-required-checks.sh found mismatches — review .github/required-checks.txt." >&2
    fi
fi

# ── Provision Ruleset ─────────────────────────────────────────────────────────
PROVISION_SCRIPT="$SCRIPT_DIR/provision-ruleset.sh"
if [[ ! -f "$PROVISION_SCRIPT" ]]; then
    echo "WARNING: provision-ruleset.sh not found at $PROVISION_SCRIPT — Ruleset provisioning skipped." >&2
    exit 0
fi

echo "Provisioning GitHub Ruleset on $REPO..." >&2
if ! bash "$PROVISION_SCRIPT" --non-interactive --repo "$REPO"; then
    echo "WARNING: provision-ruleset.sh failed — Ruleset may need to be created manually." >&2
    exit 0
fi

echo "GitHub repository configuration complete." >&2
exit 0
