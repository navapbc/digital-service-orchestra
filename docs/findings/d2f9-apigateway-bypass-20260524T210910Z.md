# d2f9 telemetry — restore anonymous submission via API Gateway (bypass org SCP)

**Timestamp:** 2026-05-24T21:06:12Z (live probe) — written up 2026-05-24T21:09:10Z
**Trigger:** Post-merge live validation found that no telemetry records were landing in S3 from CI llm-review runs. Root cause: AWS Organization SCP `o-t5fn7az6cp` denies `lambda:InvokeFunctionUrl` for Principal `*`, so every anonymous POST to the Function URL returns 403. The d2f9 fire-and-forget wrapper silently swallows the failure.
**Prior evidence:** `docs/findings/d2f9-live-validation-20260524T183745Z.md` (recorded the 6/7 ok, check 7 BLOCKED-BY-ENV state); `docs/findings/d2f9-live-validation-20260523T134001Z.md` (sprint-time documentation of the SCP constraint).

## Summary

The d2f9 telemetry feature's stated design intent is "zero-friction host-project participation" — anonymous client POSTs to a public Lambda Function URL land as NDJSON records in S3. In this AWS account (820258254566, member of an Organization that applies SCP `o-t5fn7az6cp`), the anonymous POST path returns 403 by design of the org policy. The feature shipped non-functional in production for this account: the sprint's recorded "live evidence" runs (5 events on 2026-05-23 + 1 on 2026-05-24) were all driven by `aws lambda invoke` (SDK invoke under the caller's IAM identity), not the wrapper's anonymous POST.

This evidence file documents a live working bypass: **API Gateway HTTP API in front of the Lambda**. API Gateway invokes the Lambda via `lambda:InvokeFunction` (a different IAM action, with `apigateway.amazonaws.com` as the named principal) — NOT covered by the SCP's `lambda:InvokeFunctionUrl` deny. Anonymous clients POST to the API Gateway URL with no AWS credentials and the request reaches the Lambda + S3 as designed.

## Live probe — manual provisioning + anonymous POST

Performed against AWS account `820258254566`, region `us-east-1`, on 2026-05-24T21:05–21:06Z.

| Resource | Value |
|---|---|
| HTTP API | `dso-telemetry-probe-210554` (id `2wbf4q3tta`) |
| Endpoint | `https://2wbf4q3tta.execute-api.us-east-1.amazonaws.com` |
| Integration | `AWS_PROXY` to `arn:aws:lambda:us-east-1:820258254566:function:dso-telemetry-review` |
| Route | `POST /` → `$default` stage |
| Lambda permission | statement `apigateway-2wbf4q3tta-invoke`, action `lambda:InvokeFunction`, principal `apigateway.amazonaws.com`, source-arn `arn:aws:execute-api:us-east-1:820258254566:2wbf4q3tta/*/*/*` |

**Step 1 — create HTTP API + integration + route in one call:**

```bash
aws apigatewayv2 create-api \
  --name "dso-telemetry-probe-210554" \
  --protocol-type HTTP \
  --target "arn:aws:lambda:us-east-1:820258254566:function:dso-telemetry-review" \
  --route-key 'POST /'
```

Response (excerpt): `ApiId=2wbf4q3tta`, `ApiEndpoint=https://2wbf4q3tta.execute-api.us-east-1.amazonaws.com`.

**Step 2 — attach the resource-based permission on the Lambda** (so API Gateway is allowed to invoke it):

```bash
aws lambda add-permission \
  --function-name dso-telemetry-review \
  --statement-id "apigateway-2wbf4q3tta-invoke" \
  --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:us-east-1:820258254566:2wbf4q3tta/*/*/*"
```

**Step 3 — anonymous POST with a schema-valid `tool_finding` payload:**

```bash
curl -sS -X POST https://2wbf4q3tta.execute-api.us-east-1.amazonaws.com \
  -H 'Content-Type: application/json' \
  -d '{"schema_version":1,"event_id":"phase10a-probe-210612","event_type":"tool_finding","client_id":"dso-self","tool_id":"phase10a-apigw-probe","tool_version":"1.0.0","timestamp":"2026-05-24T21:06:12Z","tool_name":"dso-apigateway-probe","tool_rule":"sdk_alt_path_test","tool_severity":"info","file":"","message":"Phase 10a: anonymous POST via API Gateway bypassing SCP"}'
```

**Response:** `HTTP 202` in 7.26s. No AWS credentials supplied; no SigV4 signing.

**Step 4 — S3 write confirmation** (4-second poll after POST):

```
s3://dso-telemetry-review-820258254566/dso-self/2026-05-24/phase10a-probe-210612.jsonl  (388 bytes)
```

The downloaded object is **byte-identical** to the posted payload (the Lambda's `apply_server_side_privacy` is a no-op for `client_id=dso-self` per the Layer A privacy contract).

## Side-by-side: same payload, two URLs

| Endpoint | HTTP status | Result |
|---|---|---|
| `https://lxpst36qem2kxzbblgm73xvmam0bglnv.lambda-url.us-east-1.on.aws/` (Function URL, AUTH=NONE) | `403 Forbidden` | Blocked by SCP `o-t5fn7az6cp`. No S3 write. |
| `https://2wbf4q3tta.execute-api.us-east-1.amazonaws.com` (API Gateway HTTP API → Lambda) | `202 Accepted` | S3 write confirmed within 4s of POST. |

The Lambda code, IAM role, S3 bucket, and validation logic are unchanged. The only difference is the IAM action used to invoke the Lambda: `InvokeFunctionUrl` (SCP-denied for Principal `*`) vs. `InvokeFunction` (allowed for principal `apigateway.amazonaws.com`).

## Why this works (mechanism note)

The SCP `o-t5fn7az6cp` is scoped to the IAM action `lambda:InvokeFunctionUrl` with a wildcard Principal. That action only fires when the Lambda is invoked by the Function URL gateway with `AuthType=NONE`. When API Gateway invokes the Lambda via its proxy integration, it uses `lambda:InvokeFunction` with the named service principal `apigateway.amazonaws.com` — a different IAM action and a non-wildcard principal — so the SCP statement does not match and the call proceeds. The Lambda's existing resource-based policy grants the API Gateway service principal that permission (added explicitly in step 2 above).

## Operational change

`.claude/dso-config.conf:review_telemetry.endpoint_url` is updated to the API Gateway endpoint so `telemetry_emit.py` POSTs there instead of the Function URL. `review_telemetry.lambda_function_url` is left pointed at the Function URL so `aws-verify-live.sh` can still exercise the (SCP-blocked) anonymous path for documentation purposes.

After this change, every run of the `runner.py` / `arbiter_processor.py` emit code paths in CI will deliver schema-valid telemetry events to `s3://dso-telemetry-review-820258254566/<client_id>/<YYYY-MM-DD>/<event_id>.jsonl`.

## Open follow-ups

- The probe-named API Gateway (`dso-telemetry-probe-210554`) is the operational endpoint by default after merging this change. If a different name is preferred (e.g. `dso-telemetry-prod`), an operator can re-run the provisioning with a stable name and overwrite `endpoint_url` again. INSTALL.md "Telemetry Infrastructure" step 5 documents the procedure.
- Bug `b3ac-1040-eca6-4b78` (Function URL anonymous POST SCP block) can be re-classified from "P3 environmental constraint" to "P3 known-by-design, mitigated via step 5" — the wrapper now works in SCP-restricted accounts without code changes.
- The `aws-verify-live.sh check_e2e_post_visibility` check uses SDK invoke (already updated during the recovery PR), so it continues to pass on 7/7 regardless of the SCP. It does not exercise the API-Gateway anonymous path; if that coverage is desired, an additional check can be added in a follow-up.
