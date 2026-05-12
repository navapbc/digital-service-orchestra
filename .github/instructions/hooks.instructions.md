---
applyTo: "plugins/dso/hooks/**"
---

# Safety Gate Coverage

These files are safety gates (pre-commit hooks, review gates, test gates).

Coverage area: whether the change weakens a check — lowered threshold,
added bypass, broader skip condition, fail-open path. Flag so a human can
confirm the change is intentional.
