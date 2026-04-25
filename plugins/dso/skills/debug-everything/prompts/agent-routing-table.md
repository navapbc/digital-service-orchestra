# Sub-Agent Routing Table (Phase G fix dispatch)

Resolve `subagent_type` via `discover-agents.sh` using the routing category from `agent-routing.conf`. Run `$PLUGIN_SCRIPTS/discover-agents.sh` and use the resolved agent for each category.

| Fix Category | Routing Category | `model` |
|---|---|---|
| Type errors (mypy) | `mechanical_fix` | `sonnet` |
| Unit test failures | `test_fix_unit` | `sonnet` |
| E2E test failures | `test_fix_e_to_e` | `sonnet` |
| Lint violations (manual) | `code_simplify` | `sonnet` |
| Complex multi-file bugs | `complex_debug` | `opus` |
| Migration / DB issues | `database-design:database-architect` | `sonnet` |
| Infrastructure (Tier 6) | `complex_debug` | `opus` |
| Ticket bugs — known fix (SAFEGUARD APPROVED) | `code_simplify` | `sonnet` |
| Ticket bugs — code fixes (Tier 7) | `mechanical_fix` | `sonnet` |
| Ticket bugs — tooling/scripts (Tier 7) | `code_simplify` | `sonnet` |
| Ticket bugs — investigation (Tier 7) | `complex_debug` | `opus` |
| TDD test writing (non-test bugs) | `test_write` | `sonnet` |
| Post-fix critic review | `feature-dev:code-reviewer` | `sonnet` |

`database-design:database-architect` and `feature-dev:code-reviewer` are direct references (core agents that don't require routing). All other categories resolve dynamically via `discover-agents.sh` + `agent-routing.conf`, falling back to `general-purpose` when the preferred plugin is not installed.

**Tier 6 infra sub-agents** receive additional prompt context:
```
### AWS CLI Access
Full AWS CLI access for diagnosing/resolving infrastructure issues. Useful:
- aws elasticbeanstalk describe-environment-health --environment-name $EB_STAGING_ENV --attribute-names All
- aws logs tail /aws/elasticbeanstalk/$EB_STAGING_ENV --since 1h
- aws sts get-caller-identity
If AWS auth is not configured, report this and recommend: aws sso login
```

**Escalation**: if a sub-agent fails, retry with `model="opus"` before investigating manually.
