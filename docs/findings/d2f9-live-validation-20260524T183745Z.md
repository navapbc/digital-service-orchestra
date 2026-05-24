# d2f9 telemetry pipeline — live validation evidence (recovery PR refresh)

**Timestamp:** 2026-05-24T18:37:45Z
**Trigger:** Pre-PR verification for `feat/d2f9-telemetry-recovery` (the recovery PR that merges the paused d2f9 sprint into main).
**Prior evidence:** `docs/findings/d2f9-live-validation-20260523T134001Z.md` and `docs/findings/d2f9-live-validation-canonical-20260523T160846Z.md` (2026-05-23 sprint-time evidence — preserved as historical record).

## Summary

End-to-end telemetry pipeline re-validated against the deployed AWS infrastructure 1 day after the sprint-time evidence. Lambda → schema-validation → privacy → S3 chain confirmed working via direct SDK invocation. Anonymous Function URL POST remains blocked by AWS Organization SCP `o-t5fn7az6cp` (bug `b3ac-1040-eca6-4b78`, environmental constraint, not a code defect). One config-drift finding noted (Lambda Function URL rotated since 2026-05-23) — corrected on this branch.

## Account / resource inventory

| Item | Value |
|---|---|
| AWS account | `820258254566` |
| Region | `us-east-1` |
| Lambda function | `dso-telemetry-review` (Active, runtime python3.13, handler `handler.lambda_handler`) |
| Lambda Function URL | `https://lxpst36qem2kxzbblgm73xvmam0bglnv.lambda-url.us-east-1.on.aws/` (AuthType `NONE`) |
| IAM role | `arn:aws:iam::820258254566:role/dso-telemetry-lambda-role` |
| S3 bucket | `dso-telemetry-review-820258254566` (encryption + lifecycle ok) |
| TELEMETRY_BUCKET env | `dso-telemetry-review-820258254566` |
| Resource-based policy | Public principal allow `lambda:InvokeFunctionUrl` with `FunctionUrlAuthType=NONE` condition |

## aws-verify-live.sh results

| Check | Result | Detail |
|---|---|---|
| check_lambda_function_url | OK | Function URL exists, AuthType NONE matches design |
| check_iam_role_trust | OK | Role trusts lambda.amazonaws.com |
| check_s3_head_bucket | OK | Bucket reachable |
| check_s3_encryption | OK | Server-side encryption configured |
| check_s3_lifecycle | OK | Lifecycle rules applied |
| check_iam_simulate_principal | OK | Lambda role has s3:PutObject simulated allow |
| check_e2e_post_visibility | BLOCKED-BY-ENV | Anonymous curl POST returns 403; AWS Organization SCP `o-t5fn7az6cp` blocks anonymous Function URL invocations regardless of the resource-based policy. Documented as bug `b3ac-1040-eca6-4b78` (open — design-vs-deployment-context reconciliation required, not a code defect). |

## Direct SDK invocation E2E test

The d2f9 sprint's validated emission path (per `docs/findings/d2f9-live-validation-20260523T134001Z.md` lines 24, 26, 152) is `aws lambda invoke` with a Function-URL-shape event payload. Re-run today:

**Payload posted:**
```json
{"schema_version": 1, "event_id": "recovery-pr-verify-20260524", "event_type": "review_cycle", "client_id": "dso-self", "tool_id": "d2f9-recovery-pr", "tool_version": "1.0.0", "timestamp": "2026-05-24T18:37:45Z", "cycle_number": 1, "tier": "deep", "finding_count": 0, "critical_count": 0, "important_count": 0, "minor_count": 0, "pass": true, "resolution_attempts": 0, "diff_hash": "d2f9-recovery-pr-evidence"}
```

**Lambda response:** `{"statusCode": 202, "body": ""}` (StatusCode 200 from the Lambda SDK envelope).

**S3 object written:** `s3://dso-telemetry-review-820258254566/dso-self/2026-05-24/recovery-pr-verify-20260524.jsonl` (410 bytes, visible within 3 seconds of the invoke). Object body is byte-identical to the posted payload — schema validation accepted the event, privacy stripping was a no-op (no `cited_excerpt` field), and S3 write produced the canonical `${client_id}/${YYYY-MM-DD}/${event_id}.jsonl` key.

## Config drift correction

The sprint-time `dso-config.conf` carried Function URL `https://7xee4fmdye5xy6qucntd2ob7ba0uxpbe.lambda-url.us-east-1.on.aws/`. The Lambda was re-created at some point between 2026-05-23 and 2026-05-24 and got a new Function URL (`lxpst36qem2kxzbblgm73xvmam0bglnv`). Both `review_telemetry.endpoint_url` and `review_telemetry.lambda_function_url` updated on this branch to match the current live URL. Downstream users running `aws-setup-lambda.sh` will also have these values rewritten by the script when re-deploying.

## Open bugs (unchanged from 2026-05-23)

| ID | Severity | Subsystem | Description | Status |
|---|---|---|---|---|
| `b3ac-1040-eca6-4b78` | P3 | aws-setup-lambda.sh | Function URL `AUTH=NONE` blocked by AWS Organization SCP → anonymous public POST returns 403 | OPEN — design-vs-deployment-context reconciliation required; not a code defect |

## Conclusion

Live deployment functions end-to-end via direct SDK invocation. The org-SCP block on anonymous Function URL POST is unchanged and documented in `INSTALL.md` ("Telemetry Infrastructure" prerequisites), in `plugins/dso/scripts/telemetry/aws-setup-lambda.sh` (`ensure_function_url` comment block), and in this evidence file. The recovery PR ships the d2f9 telemetry pipeline plus the URL-drift correction.
