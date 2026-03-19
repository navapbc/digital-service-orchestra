---
id: w21-c8hi
status: open
deps: [w21-ghbu, w21-sjie, w21-jy5s]
links: []
created: 2026-03-19T06:05:56Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-ahok
---
# Update INSTALL.md to note error-debugging enhances fix-bug investigation

Update plugins/dso/docs/INSTALL.md to explicitly note that the error-debugging plugin enhances the INTERMEDIATE investigation tier in dso:fix-bug.

Current text (line ~178):
| **error-debugging** | Error pattern detection (`error-detective`), structured debugging (`debugger`) |

Required change: Update the error-debugging row description to mention its role in dso:fix-bug investigation. The Done Definition requires: 'INSTALL.md lists error-debugging as a recommended plugin for enhanced investigation.'

Consider adding a note like: '...enhances INTERMEDIATE investigation in `/dso:fix-bug`' to the existing row description.

No new section needed — just update the existing Optional Plugins table row.

TDD Requirement: No new test required — the Done Definition is verified by reading the file. Acceptance criteria verify the content is present.

