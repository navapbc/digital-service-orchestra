# Contract: aws-status.sh JSON Output Schema

- Status: accepted
- Scope: AWS resource health telemetry (`${CLAUDE_PLUGIN_ROOT}/scripts/telemetry/aws-status.sh`)
- Date: 2026-05-22
- schema_version: 1

## Purpose

This document defines the stable JSON schema emitted by `aws-status.sh` — the script that probes the four core AWS resources (S3 bucket, Lambda function, IAM role, CloudWatch log group) and reports their presence and key configuration attributes as a single JSON object.

Downstream health-check scripts MUST read this contract before parsing `aws-status.sh` output. Scripts MUST check `schema_version` on every parse and refuse to process output whose `schema_version` is unknown (i.e., higher than the latest version documented here). Breaking changes to field names, types, or absent-resource semantics MUST bump `schema_version`.

---

## Emitter

`${CLAUDE_PLUGIN_ROOT}/scripts/telemetry/aws-status.sh`

The script probes each resource independently, writes a single JSON object to stdout, and exits 0 on success. Partial failures (one resource unreachable) must not suppress other resources — those sections are emitted with `present: false`.

---

## Top-Level Fields

| Field | Type | Required | Description |
|---|---|---|---|
| `schema_version` | integer | required | Schema version. Current value: `1`. Consumers MUST check this field and refuse unknown versions. |
| `bucket` | object | required | S3 bucket resource entry. See [bucket](#bucket). |
| `lambda` | object | required | Lambda function resource entry. See [lambda](#lambda). |
| `iam_role` | object | required | IAM role resource entry. See [iam_role](#iam_role). |
| `log_group` | object | required | CloudWatch log group resource entry. See [log_group](#log_group). |
| `metrics` | object | required | Aggregate metrics. See [metrics](#metrics). Always emitted — even when all resources are absent. |

---

## Resource Entry Schemas

Each of the four resource entries follows the same `present`-boolean pattern: when `present` is `false`, the entry contains **only** `{present: false}`. When `present` is `true`, all per-resource attribute fields are included.

### bucket

Represents the S3 bucket used for artifact storage.

| Field | Type | Present-true only? | Description |
|---|---|---|---|
| `present` | boolean | no | `true` when the bucket exists and is accessible; `false` otherwise. |
| `name` | string | yes | Bucket name. |
| `lifecycle_tier` | string | yes | Storage class of the lifecycle rule applied to the bucket. Expected value: `"Glacier-IR"`. |
| `public_access_block_enabled` | boolean | yes | `true` when all four S3 Block Public Access settings are enabled on the bucket. |
| `sse_enabled` | boolean | yes | `true` when server-side encryption (SSE) is enabled on the bucket. |

**When present=false:**
```json
{"present": false}
```

**When present=true:**
```json
{
  "present": true,
  "name": "my-artifact-bucket",
  "lifecycle_tier": "Glacier-IR",
  "public_access_block_enabled": true,
  "sse_enabled": true
}
```

---

### lambda

Represents the Lambda function used for health-check or event processing.

| Field | Type | Present-true only? | Description |
|---|---|---|---|
| `present` | boolean | no | `true` when the function exists and is accessible; `false` otherwise. |
| `name` | string | yes | Function name (not ARN). |
| `function_url` | string or null | yes | The function URL if a URL configuration is attached; `null` when no URL is configured. |
| `reserved_concurrency` | integer or null | yes | Reserved concurrency limit if set; `null` when no reserved concurrency is configured. |

**When present=false:**
```json
{"present": false}
```

**When present=true (with URL and concurrency):**
```json
{
  "present": true,
  "name": "my-health-check-fn",
  "function_url": "https://abc123.lambda-url.us-east-1.on.aws/",
  "reserved_concurrency": 10
}
```

**When present=true (no URL, no reserved concurrency):**
```json
{
  "present": true,
  "name": "my-health-check-fn",
  "function_url": null,
  "reserved_concurrency": null
}
```

---

### iam_role

Represents the IAM role assumed by the Lambda function or related compute.

| Field | Type | Present-true only? | Description |
|---|---|---|---|
| `present` | boolean | no | `true` when the role exists and is accessible; `false` otherwise. |
| `name` | string | yes | Role name (not ARN). |
| `trust_policy_includes_lambda` | boolean | yes | `true` when the role's trust policy contains a principal that allows `lambda.amazonaws.com` to assume the role. |

**When present=false:**
```json
{"present": false}
```

**When present=true:**
```json
{
  "present": true,
  "name": "my-lambda-execution-role",
  "trust_policy_includes_lambda": true
}
```

---

### log_group

Represents the CloudWatch Logs log group used by the Lambda function.

| Field | Type | Present-true only? | Description |
|---|---|---|---|
| `present` | boolean | no | `true` when the log group exists and is accessible; `false` otherwise. |
| `name` | string | yes | Log group name (e.g., `/aws/lambda/my-health-check-fn`). |
| `retention_days` | integer | yes | Retention period in days configured on the log group. |

**When present=false:**
```json
{"present": false}
```

**When present=true:**
```json
{
  "present": true,
  "name": "/aws/lambda/my-health-check-fn",
  "retention_days": 30
}
```

---

### metrics

Aggregate counts collected during the probe run. This object is **always emitted** regardless of resource presence. It is NOT a resource entry and does NOT follow the `present`-boolean pattern.

| Field | Type | Required | Description |
|---|---|---|---|
| `last_24h_event_count` | integer | required | Number of log events in the CloudWatch log group in the last 24 hours. Value is `0` when the log group is absent or has no events in the window. |

**Always emitted — even when log_group.present=false:**
```json
{
  "last_24h_event_count": 0
}
```

**When log group is present and has events:**
```json
{
  "last_24h_event_count": 47
}
```

---

## Complete Example

All resources present:

```json
{
  "schema_version": 1,
  "bucket": {
    "present": true,
    "name": "my-artifact-bucket",
    "lifecycle_tier": "Glacier-IR",
    "public_access_block_enabled": true,
    "sse_enabled": true
  },
  "lambda": {
    "present": true,
    "name": "my-health-check-fn",
    "function_url": "https://abc123.lambda-url.us-east-1.on.aws/",
    "reserved_concurrency": 10
  },
  "iam_role": {
    "present": true,
    "name": "my-lambda-execution-role",
    "trust_policy_includes_lambda": true
  },
  "log_group": {
    "present": true,
    "name": "/aws/lambda/my-health-check-fn",
    "retention_days": 30
  },
  "metrics": {
    "last_24h_event_count": 47
  }
}
```

No resources present (e.g., fresh environment):

```json
{
  "schema_version": 1,
  "bucket": {"present": false},
  "lambda": {"present": false},
  "iam_role": {"present": false},
  "log_group": {"present": false},
  "metrics": {
    "last_24h_event_count": 0
  }
}
```

---

## Evolution Rules

### Additive Changes (no version bump required)

New optional fields may be added to any resource entry when `present=true` without a breaking change. Consumers MUST ignore unknown fields.

### Breaking Changes (MUST bump schema_version)

The following changes require incrementing `schema_version` (e.g., `1` → `2`):

- Removing a field that is currently documented as present when `present=true`
- Changing the type of any existing field
- Changing the semantic meaning of any existing field
- Adding a required field to the `metrics` object
- Changing absent-resource semantics (e.g., emitting anything other than `{present: false}` for an absent resource)

When `schema_version` changes, this contract and all conforming emitters and parsers must be updated atomically in the same commit.

---

## Consumers

| Component | Role | Notes |
|---|---|---|
| `${CLAUDE_PLUGIN_ROOT}/scripts/telemetry/aws-status.sh` | Writer | Emits one JSON object per invocation to stdout |
| Health-check scripts (downstream) | Reader | Must check `schema_version` before parsing; refuse unknown versions |

---

## Versioning

This contract is versioned via the `schema_version` integer field in the JSON document. The current version is **1**.

### Change Log

- **2026-05-22**: Initial version (`schema_version: 1`). Defines top-level structure, four resource entries (`bucket`, `lambda`, `iam_role`, `log_group`), and `metrics` object with `last_24h_event_count`. Documents absent-resource semantics (`present: false` only), per-resource attribute fields, and evolution rules.
