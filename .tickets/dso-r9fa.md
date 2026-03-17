---
id: dso-r9fa
status: open
deps: [dso-awoz]
links: []
created: 2026-03-17T19:51:56Z
type: story
priority: 0
assignee: Joe Oakhart
parent: dso-42eg
---
# As a host project maintainer, I can bootstrap DSO script access via one-time setup


## Notes

<!-- note-id: ahp4f2t8 -->
<!-- timestamp: 2026-03-17T19:52:40Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

## What
Create the one-time setup command that writes `dso.plugin_root` to workflow-config.conf and copies the shim into the host project.

## Why
The shim template lives in the plugin. Something must copy it to the host project and record the plugin root path. This is that something — run once during project onboarding.

## Scope
IN: Setup command (script or setup skill step) that writes `dso.plugin_root=<absolute-path>` to workflow-config.conf; copies shim from `templates/host-project/dso` to `.claude/scripts/dso` (chmod +x); idempotent re-run (updates existing dso.plugin_root key rather than appending a duplicate)
OUT: Shim logic itself [S1], library mode [S2], smoke tests [S4]

## Done Definitions
- When this story is complete, running setup once creates `.claude/scripts/dso` and writes dso.plugin_root to workflow-config.conf
  ← Satisfies: 'One-time project setup...is the only configuration step required'
- When this story is complete, re-running setup does not duplicate the dso.plugin_root entry in workflow-config.conf
  ← Satisfies: 'One-time project setup...is the only configuration step required'
- When this story is complete, `dso tk --help` succeeds in a new shell session after setup without any additional export, source, or PATH modification
  ← Satisfies: 'After running setup once, dso tk --help succeeds in a new shell session'

## Considerations
- [Reliability] Setup must handle the case where workflow-config.conf already has a dso.plugin_root key — idempotent re-run required
