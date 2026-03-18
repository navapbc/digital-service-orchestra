---
id: dso-472x
status: closed
deps: []
links: []
created: 2026-03-18T04:41:08Z
type: bug
priority: 2
assignee: Joe Oakhart
parent: dso-igoj
---
# preplanning: tk create calls omit story description and done definition

During Phase 4 (Create Stories), the preplanning skill instructs the agent to run tk create with only a title. The done definition, user story narrative, and adversarial review considerations assembled during Phases 2–3 are never passed to tk create via --description or --acceptance. Story tickets are created as bare titles with no body, requiring manual backfill after the fact.

## Acceptance Criteria

- [ ] `skills/preplanning/SKILL.md` Phase 4 Create Stories step includes `--description` and/or `--acceptance` flags on the `tk create` call
  Verify: grep -A5 "tk create" /Users/joeoakhart/digital-service-orchestra/skills/preplanning/SKILL.md | grep -q "\-\-description\|\-\-acceptance"
- [ ] Story tickets created by preplanning contain the user story body in their description field (not empty)
  Verify: bash tests/run-all.sh 2>&1 | grep -q "Results:.*0 failed"

