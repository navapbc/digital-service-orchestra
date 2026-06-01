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
- **flock** (macOS): required by `ticket-lib.sh`, `preconditions-record.sh`, and the cycle-ledger for concurrent-writer serialization. macOS does not ship `flock`. Install with:
  ```
  brew install flock
  ```
  (Alternatively, `brew install util-linux` provides the util-linux build. On Linux, `util-linux` typically already provides `flock`; `sudo apt-get install util-linux` if missing.)

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

### Goal-4 containment: non-admin agent identity + credential hygiene (CS-7a)

The override path for a blocked PR (LLM false positive, hotfix) must be a **human via the GitHub web UI**, never the autonomous dev agent. Achieving that requires an **identity-based** control — `bypass_mode: pull_request` does NOT restrict the *tool* (an admin/bypass-actor can still merge a failing PR via the REST API), so the agent must run under an identity that is *not* a bypass actor.

One-time admin setup (do once; runtime CI needs no admin):

1. **Bypass actor = a named human `User`, not `RepositoryRole:admin`.** Set `ruleset.bypass_user_id` in `.claude/dso-config.conf` to that human's numeric GitHub user ID (env override `DSO_RULESET_BYPASS_USER_ID`); `provision-ruleset.sh` emits a `User` bypass actor from it. The admin *role* then no longer bypasses — only the named human, via the web UI.
2. **Run the agent under a non-admin identity.** Verify the OUTCOME, not the actor list: `gh api repos/<owner>/<repo>/rulesets/<id> --jq .current_user_can_bypass` must be `never` for the agent's token (the `ruleset-design-invariants` check enforces this per-PR).
3. **Credential-helper hygiene.** `gh` and `git` can resolve to *different* credentials. Probe BOTH — `gh api user --jq .login` and `printf 'protocol=https\nhost=github.com\n\n' | git credential fill` — and confirm neither resolves to an admin token. Wire git to the gh helper so they agree: `git config credential.https://github.com.helper '!gh auth git-credential'`, and erase any admin token from the OS keychain.

The post-hoc audit sweep (`scripts/ci/fp-recovery-audit-sweep.sh`) and the fail-closed `review-coverage-invariant` (see `CI-INTEGRATION.md` → *Workflow-stability hardening*) backstop any bypass that still reaches `main`.

## Integration Setup

Some DSO skills integrate with external tools. Each integration is optional and configured via environment variables or the DSO config file. Skip any integration you don't use.

### Jira

DSO's ticket system can sync to Jira issues bidirectionally via the **DSO reconciler bridge**. Local tickets are the source of truth; the reconciler mirrors them to a Jira project and pulls back Jira-side edits for already-bound tickets. The bridge runs every 20 minutes in CI via the `reconcile-bridge.yml` workflow and pairs with a `reconcile-bridge-canary.yml` workflow that flags 2h staleness.

#### Required environment variables

For workstation runs AND in the GitHub repo secrets (CI):

- `JIRA_URL` — your Jira base URL (e.g., `https://your-org.atlassian.net`)
- `JIRA_USER` — the service-account email used for ACLI / REST API access
- `JIRA_API_TOKEN` — an Atlassian API token (NEVER commit)
- `JIRA_PROJECT` — Jira project key (e.g., `DIG`); same value as `jira.project` in `.claude/dso-config.conf`
- `BRIDGE_ENV_ID` — UUID identifying this reconciler environment; MUST be set (empty value fails fast). Generate via `uuidgen`. One UUID per logical project.
- `BRIDGE_USER_MAP` — JSON map of email → Jira accountId, e.g. `{"alice@example.com": "5fa..."}`. Required for outbound assignee sync; empty `{}` disables assignee sync.

#### Optional environment variables

- `BRIDGE_BOT_NAME` (default `dso-bridge[bot]`) — git author name on bridge commits
- `BRIDGE_BOT_EMAIL` (default `dso-bridge@users.noreply.github.com`) — git author email on bridge commits

Create an API token at: https://support.atlassian.com/atlassian-account/docs/manage-api-tokens-for-your-atlassian-account/

#### Config keys

- `jira.project=<KEY>` in `.claude/dso-config.conf` — Jira project key

#### Approved sync exceptions (NOT propagated, by design)

- **`ticket_type` / `issuetype`** — not synced in either direction. Local types (`epic`/`story`/`task`/`bug`) don't map cleanly to Jira's type taxonomy and cross-hierarchy transitions are often rejected by Jira workflows. Set the type once on create; changes after that are local-only.
- **Local ticket deletions** — not propagated to Jira. Delete locally and, if desired, close/delete the Jira issue manually.
- **Assignees that don't map to a real Jira user** — soft-failed per mutation: logged to `bridge_state/bridge_alerts/<date>.jsonl` with kind `outbound-update-assignee-unresolved`; the pass continues. Resolve by clearing the local assignee or mapping the user via `BRIDGE_USER_MAP`.

#### Bidirectional flow (Jira-side ticket creation is a first-class entry point)

The bridge is fully bidirectional. Either side can originate work:

- **Local → Jira**: a local ticket created via `dso ticket create` is pushed outbound on the next reconcile pass; the reconciler writes a `dso-id:<local_uuid>` marker label on the new Jira issue to dedupe future passes.
- **Jira → local**: a Jira issue created directly in the Jira UI (or via Linear sync, automation, etc.) that lacks the `dso-id:<local_uuid>` marker is picked up by the snapshot-diff differ on the next pass and materialized locally as `jira-dig-<NNNN>` with the `imported:reconciler-bootstrap` tag. The reconciler writes the dso-id marker back to Jira so the issue is recognized as bound on subsequent passes.

Expect ~20-minute end-to-end latency in either direction (the cron cadence).

#### Verification

```bash
# Read-only audit (safe to run before first bootstrap):
python3 ${CLAUDE_PLUGIN_ROOT}/scripts/ticket-bridge-fsck.py  # shim-exempt: doc example, explicit plugin-root invocation

# Live end-to-end check (writes to Jira):
gh workflow run reconcile-bridge.yml -F mode=validate

# Or trigger a non-write dry-run pass:
gh workflow run reconcile-bridge.yml -F mode=dry-run
```

Rollout-safety modes available via `workflow_dispatch`: `dry-run` (no writes), `bootstrap-strict` (cap=10 mutations/pass), `bootstrap-throttle` (cap=100), `live` (default; uncapped), `validate` (full e2e probe + cleanup).

#### Operational gaps to know about

- No in-pass kill switch yet — pause by disabling the workflow in GitHub Actions.
- `bridge_state/bridge_alerts/<date>.jsonl` is on-disk only; no Slack / dashboard / PR-comment routing.
- `live` mode is uncapped; use `bootstrap-throttle` for the most conservative cap if you need a per-pass blast-radius bound.

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
- **AWS Organization SCP and anonymous POST** — the Lambda Function URL is provisioned with `AuthType=NONE` (per the epic d2f9 design). In some AWS Organizations an SCP denies `lambda:InvokeFunctionUrl` for Principal `*`, causing anonymous POSTs straight to the Function URL to return `403 Forbidden` regardless of the resource-based policy `aws-setup-lambda.sh` attaches (bug `b3ac-1040-eca6-4b78`). For organisations where this SCP applies, **step 5 below provisions an API Gateway HTTP API that fronts the Lambda** — API Gateway invokes via `lambda:InvokeFunction` (a different IAM action not covered by the SCP), so anonymous client POSTs reach S3 as designed. In SCP-restricted accounts step 5 is required; otherwise it is optional.

### Setup Sequence (run in order)

Steps 1–4 are scripts that must run **in the order listed below** — each step writes config keys read by subsequent steps. Step 5 is an additional manual provisioning step required only in SCP-restricted accounts (see Prerequisites).

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

#### 5. (Required for SCP-restricted accounts) Provision an API Gateway HTTP API in front of the Lambda

The Function URL provisioned in step 2 uses `AuthType=NONE`, but if the AWS Organization SCP denies `lambda:InvokeFunctionUrl` for Principal `*` (the b3ac case described in the Prerequisites), anonymous client POSTs to that URL will 403. Fronting the Lambda with an API Gateway HTTP API restores anonymous submission because API Gateway invokes the Lambda via the `lambda:InvokeFunction` action (using its own service principal), which is not covered by the SCP.

There is **no automation script** for this step — provisioning is manual. The following AWS CLI sequence creates the HTTP API, wires it to the Lambda, attaches the required invoke permission, and verifies anonymous POST → S3 end-to-end.

**A. Create the HTTP API targeting the Lambda** (`--target` auto-creates the `$default` stage, an `AWS_PROXY` integration, and a `$default` route):

```bash
API_NAME="dso-telemetry-apigateway"  # pick a stable name
LAMBDA_ARN=$(aws lambda get-function \
  --function-name "$(.claude/scripts/dso read-config.sh review_telemetry.lambda_function_name)" \
  --query 'Configuration.FunctionArn' --output text)

aws apigatewayv2 create-api \
  --name "$API_NAME" \
  --protocol-type HTTP \
  --target "$LAMBDA_ARN" \
  --route-key 'POST /' \
  --output json
```

Record the `ApiId` and `ApiEndpoint` from the response.

**B. Grant API Gateway permission to invoke the Lambda** (a resource-based policy statement on the Lambda — scoped to this specific API by `SourceArn`). Re-running this command will fail with `ResourceConflictException` if a statement with the same id already exists; remove it first via `aws lambda remove-permission --statement-id "apigateway-${API_ID}-invoke" --function-name <name>` or pick a unique statement-id. The `--source-arn` uses the region of the Lambda (derived from the Lambda ARN; if you replaced `us-east-1` during step 2 update the substitution below):

```bash
API_ID="<from-step-A>"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION=$(aws lambda get-function \
  --function-name "$(.claude/scripts/dso read-config.sh review_telemetry.lambda_function_name)" \
  --query 'Configuration.FunctionArn' --output text | awk -F: '{print $4}')

aws lambda add-permission \
  --function-name "$(.claude/scripts/dso read-config.sh review_telemetry.lambda_function_name)" \
  --statement-id "apigateway-${API_ID}-invoke" \
  --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:${REGION}:${ACCOUNT_ID}:${API_ID}/*/*/*"
```

**C. Anonymous POST → S3 end-to-end smoke test**:

```bash
API_ENDPOINT="<from-step-A>"  # e.g. https://<id>.execute-api.<region>.amazonaws.com
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EID="apigw-smoke-$(date -u +%H%M%S)"

PAYLOAD=$(jq -nc \
  --arg eid "$EID" \
  --arg ts "$TS" \
  '{schema_version:1, event_id:$eid, event_type:"tool_finding",
    client_id:"dso-self", tool_id:"apigateway-smoke",
    tool_version:"1.0.0", timestamp:$ts,
    tool_name:"apigateway-smoke", tool_rule:"setup_verify",
    tool_severity:"info", file:"",
    message:"API Gateway anonymous submission smoke test"}')

curl -sS -w '\n  HTTP %{http_code} in %{time_total}s\n' \
  -X POST "$API_ENDPOINT" \
  -H 'Content-Type: application/json' \
  -d "$PAYLOAD"

# Expect HTTP 202 (Lambda accepted). Then confirm the S3 write:
sleep 4
aws s3 ls "s3://$(.claude/scripts/dso read-config.sh review_telemetry.bucket_name)/dso-self/$(date -u +%Y-%m-%d)/"
# Expect to see <EID>.jsonl in the listing.
```

**D. Wire the API Gateway URL into `dso-config.conf`** so the emitter (`telemetry_emit.py`) sends events through the bypass path:

```bash
.claude/scripts/dso read-config.sh review_telemetry.endpoint_url
# was: https://<function-url-id>.lambda-url.us-east-1.on.aws/
# update to the API Gateway endpoint from step A — manual edit of
# .claude/dso-config.conf, or via your config-management tool of choice.
```

After step D, all subsequent emits from `telemetry_emit.py` will POST to API Gateway, which is not subject to the org SCP. The Function URL remains provisioned (it is still callable via signed SDK invoke / SigV4 if you prefer authenticated submission for some clients) but no longer the primary write path.

**Teardown of the API Gateway** (when no longer needed):

```bash
aws apigatewayv2 delete-api --api-id "<API_ID>"
aws lambda remove-permission \
  --function-name "<lambda-name>" \
  --statement-id "apigateway-<API_ID>-invoke"
```

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
