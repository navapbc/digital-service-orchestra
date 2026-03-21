---
id: w21-u3op
status: open
deps: []
links: []
created: 2026-03-20T18:40:15Z
type: bug
priority: 2
assignee: Joe Oakhart
parent: dso-9xnr
---
# Investigate inconsistency between 'Acceptance criteria:' and '## ACCEPTANCE CRITERIA' formats in ticket creation

During sprint dso-zu4o, the orchestrator repeatedly had to replace inline 'Acceptance criteria:' blocks (lowercase, no heading) with '## ACCEPTANCE CRITERIA' blocks (H2 heading, uppercase) to pass the check-acceptance-criteria.sh gate.

This suggests a disconnect in the implementation-plan skill's task creation: it writes acceptance criteria in a format that the sprint's AC gate does not recognize.

## Investigation scope
1. Where does /dso:implementation-plan write acceptance criteria? Does it use 'Acceptance criteria:' (inline) or '## ACCEPTANCE CRITERIA' (heading)?
2. What does check-acceptance-criteria.sh look for? Does it require the H2 heading format?
3. Should implementation-plan be updated to use the format that check-acceptance-criteria.sh expects, or should check-acceptance-criteria.sh be more flexible?
4. Check if tk create --acceptance flag produces the right format

## Impact
Every task created by /dso:implementation-plan requires manual AC reformatting during sprint execution, adding overhead to every batch.

