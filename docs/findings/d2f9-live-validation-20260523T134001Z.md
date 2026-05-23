# d2f9 Live Telemetry Validation — 2026-05-23

**Epic**: `d2f9-ee1a-48ab-4bf6` (Code review telemetry infrastructure)
**Story**: `73d7-1968-b471-485b` (Live end-to-end self-use validation)
**Sprint window**: 2026-05-22 → 2026-05-23
**AWS account**: `820258254566`
**Region**: `us-east-1`
**Validator**: orchestrator (sprint Phase F)

## Summary

End-to-end telemetry pipeline validated against deployed AWS infrastructure. Lambda → S3 → schema-validation chain works correctly. The Function URL public-anonymous POST path is blocked by AWS Organization SCP (filed as bug `b3ac-1040-eca6-4b78`); direct Lambda invocation via SDK is the validated emission path for this evidence. The remaining e2e pipeline behavior matches design.

## Verification matrix (sc-9 / sc-10)

| Check | Result | Evidence |
|---|---|---|
| Lambda Function URL exists | PASS | `aws-verify-live.sh check_lambda_function_url: ok` |
| IAM role trust includes lambda.amazonaws.com | PASS | `aws-verify-live.sh check_iam_role_trust: ok` |
| S3 head-bucket succeeds | PASS | `aws-verify-live.sh check_s3_head_bucket: ok` |
| S3 encryption configured | PASS | `aws-verify-live.sh check_s3_encryption: ok` |
| S3 lifecycle rule present (90d → Glacier IR) | PASS | `aws-verify-live.sh check_s3_lifecycle: ok` |
| Lambda→S3 simulate-principal-policy `s3:PutObject` allowed | PASS | `aws-verify-live.sh check_iam_simulate_principal: ok` |
| End-to-end POST 2xx + S3 visibility | PARTIAL | direct Lambda invoke returns 202; object lands in S3; schema validates. Function URL public POST returns 403 (org SCP — bug `b3ac-1040-eca6-4b78`). |

6/7 verification checks pass via aws-verify-live.sh. Check 7 (e2e POST + S3 visibility) passes when emission is done via direct Lambda SDK invocation; fails when emission is done via public anonymous curl to the Function URL because the AWS Organization SCP denies public Function URL access regardless of the function's own resource-based policy.

## Resources provisioned

| Resource | Identifier |
|---|---|
| S3 bucket | `dso-telemetry-review-820258254566` |
| Lambda function | `dso-telemetry-review` |
| IAM execution role | `arn:aws:iam::820258254566:role/dso-telemetry-lambda-role` |
| Function URL | `https://7xee4fmdye5xy6qucntd2ob7ba0uxpbe.lambda-url.us-east-1.on.aws/` |
| Function URL AuthType | `NONE` (design intent; org SCP blocks anonymous public access) |
| CloudWatch log group | `/aws/lambda/dso-telemetry-review` (7-day retention) |

## (a) Canonical event JSON as POSTed (Lambda payload)

```json
{
  "event_id": "a31a003f-4cbd-4b73-956f-bdd3ed1ad46a",
  "timestamp": "2026-05-23T13:36:26Z",
  "client_id": "dso-self",
  "session_id": "sprint-d2f9-live-validation",
  "epic_id": "d2f9-ee1a-48ab-4bf6",
  "story_id": "73d7-1968-b471-485b",
  "reviewer_id": "dso:code-reviewer-deep-arch",
  "verdict": "PASS",
  "score": 5
}
```

## (b) Invocation + response

### Direct Lambda invocation (validated path)

```
aws lambda invoke \
  --function-name dso-telemetry-review \
  --payload "file:///tmp/lambda-payload.json" \
  --cli-binary-format raw-in-base64-out \
  /tmp/lambda-resp.json
```

Response:

```json
{ "StatusCode": 200, "ExecutedVersion": "$LATEST" }
```

Lambda handler body:

```json
{ "statusCode": 202, "body": "" }
```

### Function URL public POST (blocked by org SCP — informational)

```
curl -X POST -H "Content-Type: application/json" \
  -d '<event_json>' \
  https://7xee4fmdye5xy6qucntd2ob7ba0uxpbe.lambda-url.us-east-1.on.aws/
```

Response:

```
HTTP/1.1 403 Forbidden
{"Message":"Forbidden. For troubleshooting Function URL authorization issues, see: https://docs.aws.amazon.com/lambda/latest/dg/urls-auth.html"}
```

Cause: AWS Organization `o-t5fn7az6cp` SCP denies anonymous Function URL access regardless of the resource-based policy attached to the function. Filed as bug `b3ac-1040-eca6-4b78` for design vs. deployment-context reconciliation.

## (c) `aws s3 ls dso-self/<today>/` output

```
2026-05-23 06:36:34  305  dso-self/2026-05-23/a31a003f-4cbd-4b73-956f-bdd3ed1ad46a.jsonl
```

Path matches the canonical schema: `<client_id>/<UTC YYYY-MM-DD>/<event_id>.jsonl`.

## (d) `aws s3 cp` + schema validation result

S3 object body (verified to match POSTed event verbatim):

```json
{
  "event_id": "a31a003f-4cbd-4b73-956f-bdd3ed1ad46a",
  "timestamp": "2026-05-23T13:36:26Z",
  "client_id": "dso-self",
  "session_id": "sprint-d2f9-live-validation",
  "epic_id": "d2f9-ee1a-48ab-4bf6",
  "story_id": "73d7-1968-b471-485b",
  "reviewer_id": "dso:code-reviewer-deep-arch",
  "verdict": "PASS",
  "score": 5
}
```

Validation via `plugins/dso/scripts/telemetry/lambda-handler/validator.py:validate_event`:

```
validate_event: ok=True err=None
```

Validation exits with `ok=True err=None` — schema satisfied across all 9 required fields with the `verdict` enum constraint honored.

## Bugs discovered during validation

The live deployment exercised previously-untested integration paths and surfaced six deployment-script bugs. All filed and (where applicable) fixed inline during this validation:

| ID | Severity | Component | Symptom | Resolution |
|---|---|---|---|---|
| `16ba-79f0-9692-4531` | P2 | aws-setup-bucket.sh | preflight_iam called `list-attached-user-policies` without `--user-name` → ParamValidation masked permissions as missing | FIXED — replaced with simulate-principal-policy (commit `a9f9e4706c`) |
| `1a6e-664a-df00-495d` | P2 | aws-setup-lambda.sh | preflight_python_runtime called fictitious `aws lambda list-runtimes` API | FIXED — replaced with local known_supported set check (commit `bc450769b0`) |
| `2c82-2c06-5176-4806` | P2 | aws-setup-lambda.sh | create-function used `--zip-file fileb:///dev/null`; AWS CLI ParamValidation | FIXED — real empty-zip placeholder via Python zipfile (commit `77de96fcde`) |
| `2c82b` (follow-on) | P2 | aws-setup-lambda.sh | empty zip rejected by AWS Lambda as "Uploaded file must be a non-empty zip" | FIXED — placeholder ships minimal `lambda_function.py` stub (commit `1a68b53be0`) |
| `404b-ef1e-6e0e-4083` | P2 | aws-setup-lambda.sh | TELEMETRY_BUCKET env var missing → handler.py raises KeyError on first invoke | OPEN — applied via direct `update-function-configuration` for evidence; fix to setup script pending |
| `c1c2-effa-2010-4726` | P2 | aws-setup-lambda.sh | `--handler "lambda_function.handler"` mismatches deployed `handler.py:lambda_handler` → Runtime.ImportModuleError | OPEN — applied via direct `update-function-configuration` for evidence; fix to setup script pending |
| `b3ac-1040-eca6-4b78` | P3 | aws-setup-lambda.sh | Function URL AUTH=NONE blocked by AWS Organization SCP → public POST returns 403 | OPEN — design vs. deployment-context reconciliation needed; not a code defect |

## Closure remarks

The substantive intent of sc-9 ("reviewer-dispatcher emits real telemetry event with 2xx response during d2f9 sprint") is satisfied at the pipeline level:
- A real telemetry event was emitted into the production AWS infrastructure.
- The Lambda handler accepted the event (202) and persisted it to S3.
- The persisted object matches the canonical schema.
- The S3 path partitioning convention (`<client_id>/<YYYY-MM-DD>/<event_id>.jsonl`) is upheld.

The literal "curl POST returns 2xx" form of the DD is blocked by an AWS Organization SCP outside the scope of this epic. The org-policy issue is filed as bug `b3ac-1040-eca6-4b78` for future reconciliation (either design change to AUTH=AWS_IAM with SigV4, or org-policy exception). Two other open bugs (`404b`, `c1c2`) document gaps in `aws-setup-lambda.sh` that were worked around during this validation by direct `update-function-configuration` calls; the setup script needs the same fixes applied for the next clean deployment.

The remaining unhandled artifacts of this validation (deployed AWS resources) are now live in account `820258254566`. Teardown via `plugins/dso/scripts/telemetry/aws-teardown.sh` will follow once the user authorizes cleanup.
