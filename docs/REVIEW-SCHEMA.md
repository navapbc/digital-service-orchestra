# Review Output Schema

Standard JSON schema for structured reviews produced by `/review-protocol`.

## Schema

```json
{
  "subject": "<string: brief description of what was reviewed>",
  "reviews": [
    {
      "perspective": "<string: short label, e.g. 'Security', 'Product Management'>",
      "status": "<'reviewed' | 'not_applicable'>",
      "rationale": "<string: required when status is 'not_applicable', omit otherwise>",
      "dimensions": {
        "<dimension_name>": "<integer 1-5 | null for N/A>"
      },
      "findings": [
        {
          "dimension": "<string: which dimension this finding applies to>",
          "severity": "<'critical' | 'major' | 'minor'>",
          "description": "<string: what is wrong or missing>",
          "suggestion": "<string: specific change to make>"
        }
      ]
    }
  ],
  "conflicts": [
    {
      "perspectives": ["<perspective A>", "<perspective B>"],
      "target": "<string: component, file, or section both findings address>",
      "finding_a": "<string: suggestion from perspective A>",
      "finding_b": "<string: suggestion from perspective B>",
      "pattern": "<'add_vs_remove' | 'more_vs_less' | 'strict_vs_flexible' | 'expand_vs_reduce'>"
    }
  ]
}
```

## Field Reference

### `reviews[]`

| Field | Required | Description |
|-------|----------|-------------|
| `perspective` | Yes | Short label identifying the review angle |
| `status` | Yes | `"reviewed"` or `"not_applicable"` |
| `rationale` | Only when `not_applicable` | Why this perspective doesn't apply |
| `dimensions` | Yes | Map of dimension names to scores (1-5) or `null` (N/A). Empty `{}` when `not_applicable` |
| `findings` | Yes | Array of issues found. Empty `[]` when no issues or `not_applicable` |

### `findings[]`

| Field | Required | Description |
|-------|----------|-------------|
| `dimension` | Yes | Which dimension this finding relates to |
| `severity` | Yes | `"critical"` (blocks approval), `"major"` (should fix), `"minor"` (nice to fix) |
| `description` | Yes | What is wrong or missing |
| `suggestion` | Yes | Specific actionable change to make |

Domain-specific fields MAY be added alongside the standard fields. Example: accessibility findings may include `"wcag_criterion": "4.1.2 Name Role Value"`. Consumers should ignore unrecognized fields.

### `conflicts[]`

| Field | Required | Description |
|-------|----------|-------------|
| `perspectives` | Yes | The two perspectives whose suggestions contradict |
| `target` | Yes | What both findings are trying to change |
| `finding_a` | Yes | Suggestion from the first perspective |
| `finding_b` | Yes | Suggestion from the second perspective |
| `pattern` | Yes | Contradiction type (see patterns below) |

## Pass/Fail Derivation

Callers define their own pass threshold. The standard rule:

- **Pass**: ALL dimension scores across ALL reviewed perspectives are >= threshold (typically 4) or `null`
- **Fail**: Any dimension score below threshold

Callers derive pass/fail from the schema — it is not included in the output.

## Conflict Patterns

| Pattern | Signal |
|---------|--------|
| `add_vs_remove` | One says "add X"; another says "remove/reduce elements" |
| `more_vs_less` | One says "add detail/guidance"; another says "reduce clutter/complexity" |
| `strict_vs_flexible` | One says "enforce constraint"; another says "allow flexibility" |
| `expand_vs_reduce` | One says "incomplete, add more"; another says "too much, reduce scope" |
