---
id: dso-1aaa
status: in_progress
deps: []
links: []
created: 2026-03-18T18:03:10Z
type: bug
priority: 3
assignee: Joe Oakhart
jira_key: DIG-52
parent: dso-9xnr
---
# Bug: tk create rejects --parent=id flag (only --parent id works)


## Notes

**2026-03-18T18:03:17Z**

Running `tk create "title" -t story --parent=dso-l2ct` returns "Unknown option: --parent=dso-l2ct". The = form fails. The space form `--parent dso-l2ct` likely works (consistent with the code at scripts/tk line 443-444). The = form handler is at line 443: `--parent=*) parent="${1#--parent=}"; shift ;;` which should work. Possible that the tk alias/plugin wrapper intercepts the flag before it reaches the built-in. Verify: tk create "test" --parent=dso-l2ct vs tk create "test" --parent dso-l2ct

<!-- note-id: jqte3tft -->
<!-- timestamp: 2026-03-21T01:41:50Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

Investigation: The --parent=id equals form was already handled correctly in plugins/dso/scripts/tk line 443 (--parent=*) handler. The bug could not be reproduced — tk create --parent=id works correctly. Root cause: missing regression test coverage. Fix: added tests/scripts/test-tk-create-parent-equals.sh with 4 tests covering --parent=id form, --parent id space form, parent field stored in frontmatter, and invalid parent rejection.
