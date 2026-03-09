# Staging Environment Test

You are verifying the staging environment at {STAGING_URL} is healthy and serving
correct responses.

## Pre-checks

Run these checks using curl:

```bash
# Health endpoint
curl -sf {STAGING_URL}/api/health

# API status
curl -sf {STAGING_URL}/api/v1/status
```

If any pre-check fails, report STAGING_TEST: FAIL with the specific endpoint
that failed.

## Smoke Test

1. Verify the root page loads: `curl -sf {STAGING_URL}/`
2. Verify the API returns JSON: `curl -sf {STAGING_URL}/api/v1/status | jq .`

## Acceptance Criteria

- All health endpoints return HTTP 200
- API endpoints return valid JSON
- No 5xx errors in any response

Report STAGING_TEST: PASS if all criteria are met.
Report STAGING_TEST: FAIL with details if any criterion is not met.
