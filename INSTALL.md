# Installing Digital Service Orchestra

This file is for platform engineers onboarding onto DSO. It covers the prerequisites, plugin installation commands, optional tooling, and how to run `/dso:onboarding` to configure DSO for your project.

## Prerequisites

All prerequisites below are **blocking** — they must be installed before running the `/plugin` commands.

- **[Homebrew](https://brew.sh/)** (macOS): the package manager used for most prerequisite installations. Install via the one-liner at https://brew.sh/
- **Claude Code**: the CLI that hosts DSO. Download from https://claude.ai/code and follow the setup guide there.
- **bash >= 4.0**: DSO hooks require bash 4.0 or later. macOS ships with bash 3.2.57 (GPL-2); upgrade with:
  ```
  brew install bash
  ```
- **GNU coreutils** (macOS): required for portable shell utilities (`timeout`, `date -d`, etc.). Install with:
  ```
  brew install coreutils
  ```

## Installation

Run the following commands inside Claude Code while your working directory is set to the project you want DSO to manage:

```
/plugin marketplace add navapbc/digital-service-orchestra
/plugin install dso@digital-service-orchestra
```

After the plugin is installed, proceed to [Getting Started with /dso:onboarding](#getting-started-with-dsoonboarding) below.

> **Session-start note**: If DSO skills (e.g. `/dso:sprint`, `/dso:fix-bug`) are not available at the start of a new session, run `/reload-plugins` to register them. This is a known upstream Claude Code harness issue (INC-030 in `docs/KNOWN-ISSUES.md`); the workaround is to run `/reload-plugins` once at the top of each affected session.

### Release Channels

DSO is published on two channels. Choose the channel that fits your team's risk tolerance:

| Channel | Install command | When it advances |
|---------|----------------|-----------------|
| **Stable** (default) | `/plugin install dso@digital-service-orchestra` | Tagged releases only |
| **Dev** | `/plugin install dso-dev@digital-service-orchestra` | Every merge to main |

**Version semantics**: dso advances on tagged releases; dso-dev advances on every merge to main.

**Recommendation**: Enable auto-update for your chosen channel in the marketplace via the `/plugin` UI so you receive fixes and improvements automatically without a manual reinstall.

### Layer 2 Review-Gate Coverage Note

The DSO review-gate is two-layer (see `plugins/dso/docs/HOOKS-REFERENCE.md`):

- **Layer 1** — `pre-commit-review-gate.sh`, a git pre-commit hook that enforces the allowlist + review-status + diff-hash invariants.
- **Layer 2** — a PreToolUse Bash hook that blocks bypass vectors like `--no-verify`, `core.hooksPath` overrides, `git commit-tree`, direct writes to `.git/hooks/`. The bypass logic lives in `plugins/dso/hooks/lib/review-gate-bypass-sentinel.sh` (function: `hook_review_bypass_sentinel`).

Layer 2 is wired automatically when DSO is installed via the Claude Code plugin manager — `plugins/dso/.claude-plugin/plugin.json` registers the PreToolUse Bash matcher that dispatches `dispatchers/pre-bash.sh`, which sources the lib and runs the sentinel.

**If you install DSO as files-only (not as a Claude Code plugin) you MUST wire Layer 2 manually** by adding the wrapper `plugins/dso/hooks/review-gate.sh` to your project's `settings.json` `hooks.PreToolUse` array with a Bash matcher. Without this wiring, `--no-verify` and the other bypass vectors are not blocked. The same applies to `plan-review-gate.sh` (PreToolUse ExitPlanMode matcher) for plan-review enforcement.

## Optional Dependencies

- **ast-grep** (`sg`): enables structural code search in `/dso:fix-bug`, `/dso:sprint`, and other skills. DSO falls back to text grep when `ast-grep` is absent, but structural search significantly reduces false positives when tracing call sites and dependency graphs. Install with:
  ```
  brew install ast-grep
  ```

### Optional Plugins — Agent Enhancements

DSO works standalone with `general-purpose` agents for all task categories. Installing optional
Claude Code plugins adds specialized agents that are automatically discovered:

| Plugin | Enhancement |
|--------|-------------|
| **feature-dev** | Code review (`code-reviewer`), architecture exploration (`code-explorer`, `code-architect`) |
| **error-debugging** | Error pattern detection (`error-detective`), structured debugging (`debugger`); enhances INTERMEDIATE investigation in `/dso:fix-bug` |
| **playwright** | Browser automation for visual regression testing and staging verification via `@playwright/cli` (`npm install --save-dev @playwright/cli`) |

When a plugin is not installed, DSO falls back to `general-purpose` with a category-specific
prompt. No manual configuration is required.

## Getting Started with /dso:onboarding

`/dso:onboarding` is a Socratic dialogue that configures DSO for your specific project. It walks you through your stack, key commands, architecture overview, CI setup, and enforcement preferences — writing a `CLAUDE.md` and `dso-config.conf` tailored to your project. Non-interactive defaults are offered throughout, so you can move quickly or go deep.

Plan for **20–40 minutes** for a typical first run. Re-running `/dso:onboarding` on an existing project is safe; it performs an elevation-only update (never overwrites higher-confidence values).

### PR-Mode Projects

If your project uses GitHub Ruleset enforcement, select **ci-pr** when `/dso:onboarding` asks for your workflow mode. This:
1. Writes `dso.workflow=ci-pr` to `.claude/dso-config.conf`
2. Provisions a GitHub Ruleset via `provision-ruleset.sh`
3. Routes all subsequent merges through `merge-to-main-pr.sh` (PR + CI gate)

To enable PR mode on an existing project: set `dso.workflow=ci-pr` in `.claude/dso-config.conf`, then re-run `/dso:onboarding` (which will detect the existing project and offer to provision the Ruleset) or run the provision script directly via your plugin install path.

**Preferred setup** (add to `.claude/dso-config.conf`):
```conf
# CI-gated PR workflow (recommended for teams with GitHub branch protection)
dso.workflow=ci-pr

# Local direct-merge workflow (simpler, single-developer or no branch protection)
# dso.workflow=local
```

> **Legacy keys**: `merge.strategy`, `enforcement.strategy`, `worktree.isolation_enabled`, and `attribution.enabled` are deprecated. Set `dso.workflow` instead. The legacy keys are still accepted but will be removed in a future release.

Full configuration reference: [`plugins/dso/docs/CONFIGURATION-REFERENCE.md`](plugins/dso/docs/CONFIGURATION-REFERENCE.md)

## GitHub Rulesets for session-* branches {#github-rulesets-for-session-branches}

> **One-time admin setup** — required for `ci-pr` mode. Runtime CI does **not** require admin access after this step.

When `dso.workflow=ci-pr`, Sprint Phase A calls `check-ruleset-preflight.sh` to verify that a GitHub Ruleset exists for `session-*` branches with the correct required status check. Without this Ruleset, direct pushes to session branches are not blocked, and the sub-branch-to-session PR flow is not enforced.

### Purpose

Rulesets on `session-*` branches:
- Reject direct pushes (non-fast-forward rule), enforcing the sub-branch → session PR merge flow
- Require the `Sprint Story Review` (or your configured `dso.review.check_name`) status check to pass before merge

### Prerequisites

- **GitHub admin access** on the repository (one-time setup only)
- GitHub Actions enabled on the repository
- `dso.workflow=ci-pr` set in `.claude/dso-config.conf`

### Creating the Ruleset (GitHub UI)

1. In your repository, go to **Settings → Rules → Rulesets**
2. Click **New ruleset → New branch ruleset**
3. Fill in:
   - **Name**: `Sprint session branch protection`
   - **Enforcement status**: Active
4. Under **Target branches**, add a pattern: `session-*`
5. Under **Branch rules**:
   - Enable **Restrict who can push matching branches** → this blocks direct pushes (non-fast-forward)
   - Enable **Require status checks to pass before merging**
     - Click **Add checks** and enter `Sprint Story Review` (this must match `dso.review.check_name` in `dso-config.conf`)
     - **KNOWN GAP (tracked under remediation epic; post-mortem bug 576b-a6c7-3de3-4eef)**: the `Sprint Story Review` check is currently NOT produced on sub-branch PRs. `ci.yml`'s `llm-review` job is gated to `base_ref == 'main'` and does not fire on `session-*` PRs. Required-check enforcement on `session-*` will succeed-vacuously until the remediation epic restores per-sub-branch LLM review with a workflow that emits this check on sub-branch PRs.
   - **Do NOT** enable **Require linear history** — this breaks the sprint merge strategy
6. Click **Create**

### Creating the Ruleset (gh CLI)

```bash
gh api \
  --method POST \
  -H "Accept: application/vnd.github+json" \
  /repos/{owner}/{repo}/rulesets \
  --input - <<'EOF'
{
  "name": "Sprint session branch protection",
  "target": "branch",
  "enforcement": "active",
  "conditions": {
    "ref_name": {
      "include": ["refs/heads/session/*"],
      "exclude": []
    }
  },
  "rules": [
    { "type": "non_fast_forward" },
    {
      "type": "required_status_checks",
      "parameters": {
        "required_status_checks": [
          { "context": "Sprint Story Review", "integration_id": null }
        ],
        "strict_required_status_checks_policy": false
      }
    }
  ]
}
EOF
```

Replace `{owner}/{repo}` with your repository path. Replace `Sprint Story Review` if `dso.review.check_name` is set to a different value in `dso-config.conf`.

### Verifying the Ruleset

Run the preflight check that Sprint Phase A uses:

```bash
bash .claude/scripts/dso check-ruleset-preflight.sh
```

To inspect the Ruleset directly via the API:

```bash
gh api \
  -H "Accept: application/vnd.github+json" \
  /repos/{owner}/{repo}/rulesets \
  | jq '.[] | select(.name | test("session"; "i")) | {id, name, enforcement}'
```

### Matching check_name

The required status check name must match exactly:
- `dso.review.check_name` in `.claude/dso-config.conf` (defaults to `Sprint Story Review` if unset)
- The Ruleset's required status check configured above

The check is produced by `ci.yml`'s `llm-review` job. If you override `dso.review.check_name`, update the Ruleset's required check to match.

## Integration Setup

Some DSO skills integrate with external tools. Each integration is optional and configured via environment variables or the DSO config file. Skip any integration you don't use.

### Jira

DSO's ticket system can sync to Jira issues. To enable, set:

- `JIRA_URL` — your Jira base URL (e.g., `https://your-org.atlassian.net`)
- `JIRA_USER` — the email address of the Atlassian account used for API access
- `JIRA_API_TOKEN` — an Atlassian API token

Create an API token at: https://support.atlassian.com/atlassian-account/docs/manage-api-tokens-for-your-atlassian-account/

### Figma

DSO's design collaboration features can pull Figma designs into your implementation manifests. To enable, set a Figma personal access token via `FIGMA_PAT` (or the equivalent DSO config key `design.figma_pat`).

Create a personal access token at: https://help.figma.com/hc/en-us/articles/8085703771159-Manage-personal-access-tokens

### Confluence

Confluence integration is planned but not yet available — no setup steps at this time.

## Telemetry Infrastructure

DSO ships an optional review-telemetry pipeline: a Lambda function receives POST events from the emitter shim, stores NDJSON records in S3, and exposes query capability via `query-stats.sh`. All scripts live under `plugins/dso/scripts/telemetry/`.

### Prerequisites

- **AWS credentials** configured — either environment variables (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_PROFILE`) or `~/.aws/credentials`. Verify with `aws sts get-caller-identity`.
- **DuckDB CLI** installed — required for local `query-stats.sh` invocations. Verify with `plugins/dso/scripts/verify-duckdb.sh`.
- **bash 4+** — DSO telemetry scripts require bash 4.0 or later (macOS ships 3.2; upgrade with `brew install bash`).
- **jq** — required for `aws-status.sh` JSON output formatting. Install with `brew install jq` or `apt-get install jq`.
- **AWS Organization SCP must allow public Lambda Function URLs** — the deployed endpoint uses `AuthType=NONE` (per the epic d2f9 design — telemetry endpoints accept POSTs without authentication). If the AWS account is a member of an Organization whose SCP denies `lambda:InvokeFunctionUrl` for Principal `*`, anonymous POSTs to the deployed Function URL will return `403 Forbidden` regardless of the resource-based policy `aws-setup-lambda.sh` attaches. The script will still exit successfully, and the function works via direct AWS SDK / signed invocation, but the "no-auth public POST" surface requires either (a) an SCP exception for the function ARN, or (b) deployment in an account outside the restrictive Organization. Filed as bug `b3ac-1040-eca6-4b78`.

### Setup Sequence (run in order)

All four scripts must be run **in the order listed below** — each step writes config keys read by subsequent steps.

#### 1. Provision the S3 bucket

```bash
plugins/dso/scripts/telemetry/aws-setup-bucket.sh
```

- Provisions an S3 bucket with public-access block, AES256 SSE, and a 90-day GLACIER_IR lifecycle rule.
- Requires `review_telemetry.bucket_name_prefix` and `review_telemetry.lambda_role_arn` in `.claude/dso-config.conf` before running.
- Success marker: `OK: DSO telemetry bucket setup complete: <bucket-name>`
- Writes `review_telemetry.bucket_name` to `.claude/dso-config.conf`.

#### 2. Provision the Lambda function and IAM role

```bash
plugins/dso/scripts/telemetry/aws-setup-lambda.sh
```

- Provisions the IAM execution role, CloudWatch log group (7-day retention), Lambda function (python3.13), Function URL (auth-type NONE), and reserved concurrency (10).
- Requires `review_telemetry.bucket_name` (written by step 1).
- Success marker: `OK: DSO telemetry Lambda setup complete: dso-telemetry-review`
- Writes `review_telemetry.iam_role_name`, `review_telemetry.lambda_function_name`, and `review_telemetry.endpoint_url` to `.claude/dso-config.conf`.

#### 3. Deploy the handler code

```bash
plugins/dso/scripts/telemetry/aws-deploy-handler.sh
```

- Packages `schema.py`, `validator.py`, `privacy.py`, `s3_writer.py`, and `handler.py` from `plugins/dso/scripts/telemetry/lambda-handler/` and deploys them via `lambda update-function-code`.
- Requires `review_telemetry.lambda_function_name` and `review_telemetry.bucket_name` (written by steps 2 and 1 respectively).
- Success marker: `Deploy complete: dso-telemetry-review`

#### 4. Verify live (must pass before sprint closure)

```bash
plugins/dso/scripts/telemetry/aws-verify-live.sh
```

- Runs 7 live checks: Lambda Function URL configured, IAM role trust policy, S3 bucket existence, S3 SSE, S3 lifecycle, IAM simulate-principal-policy for `s3:PutObject`, and end-to-end POST → S3 object visibility.
- Requires `review_telemetry.bucket_name`, `review_telemetry.lambda_function_name`, `review_telemetry.iam_role_name`, and `review_telemetry.lambda_function_url` in `.claude/dso-config.conf`.
- Success marker: all 7 lines print `<check_name>: ok`; exit code 0.

### Operations

**Status check** (read-only JSON of all 5 resources — S3 bucket, Lambda function, IAM role, CloudWatch log group, and last-24h invocation count):

```bash
plugins/dso/scripts/telemetry/aws-status.sh
```

**Teardown** (permanently deletes all AWS resources in IAM-safe order — Lambda first, then IAM role with policy detach, then S3 bucket with version purge, then CloudWatch log group):

```bash
plugins/dso/scripts/telemetry/aws-teardown.sh --user-approved
```

The `--user-approved` flag is required as a safety gate. After teardown, stale `review_telemetry.*` entries remain in `.claude/dso-config.conf` and must be removed manually.
