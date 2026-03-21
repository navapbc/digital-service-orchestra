---
id: dso-lli8
status: open
deps: []
links: []
created: 2026-03-19T18:19:56Z
type: bug
priority: 2
assignee: Joe Oakhart
jira_key: DIG-83
parent: dso-9xnr
---
# Bug: tk sync windowed pull uses UTC but Jira reads JQL datetimes as user-local timezone

tk sync stores last_pull_timestamp in UTC but passes it to JQL without timezone conversion.
Jira interprets bare datetimes in the user's profile timezone. When the user is in PDT,
a UTC timestamp like 16:44 is read as 16:44 PDT = 23:44 UTC (in the future). Result:
windowed pull returns 0 issues.

Fix: convert UTC timestamp to local timezone before formatting for JQL in the Python
one-liner at plugins/dso/scripts/tk lines 4252-4283.

Workaround: tk sync --full bypasses the windowed pull.
