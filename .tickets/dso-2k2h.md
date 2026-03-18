---
id: dso-2k2h
status: closed
deps: []
links: []
created: 2026-03-18T08:03:24Z
type: task
priority: 2
assignee: Joe Oakhart
parent: dso-0cjl
---
# Create skills/project-setup/SKILL.md with dso-setup.sh invocation and interactive wizard

Create the /dso:project-setup skill from scratch.

TDD: No unit tests possible for skill SKILL.md, but define pass criteria BEFORE writing:
- Criteria 1: skills/project-setup/SKILL.md exists
- Criteria 2: bash scripts/check-skill-refs.sh exits 0 on the new file
- Criteria 3: The skill invokes dso-setup.sh and handles exit codes 0/1/2
- Criteria 4: The wizard references docs/CONFIGURATION-REFERENCE.md as the authoritative key source (not hardcoded inline)
Verify criteria FAIL before writing (file doesn't exist yet = criteria 1 fails = RED).

IMPLEMENTATION — create skills/project-setup/SKILL.md with these sections:

1. YAML frontmatter: name: project-setup, description: ..., user-invocable: true

2. ## Overview — one paragraph explaining this replaces /dso:init as the primary entry point

3. ## Step 1: Run dso-setup.sh
   - Run: bash "$CLAUDE_PLUGIN_ROOT/scripts/dso-setup.sh" "$TARGET_REPO"
   - TARGET_REPO defaults to: git rev-parse --show-toplevel (or current dir if not a git repo yet)
   - Exit code handling:
     * Exit 1 (fatal): Print error, stop, do NOT proceed to wizard
     * Exit 2 (warnings-only): Print warnings to user, ask if they want to continue. If yes, proceed.
     * Exit 0 (success): Proceed to Step 2

4. ## Step 2: Detect Stack
   - Run: STACK=$(bash ".claude/scripts/dso detect-stack.sh" "$TARGET_REPO")
   - Show user the detected stack (or 'unknown')

5. ## Step 3: Interactive Configuration Wizard
   - Tell Claude: 'Read docs/CONFIGURATION-REFERENCE.md for the authoritative list of workflow-config.conf keys and their defaults.'
   - For each config section that matters to initial setup (commands.*, jira.*, dso.*):
     * Present the key with its description and default value (from CONFIGURATION-REFERENCE.md)
     * Ask the user to confirm default or provide a custom value
     * Apply stack-detected defaults where relevant (e.g., commands.test from detect-stack.sh output)
   - Jira integration: ask if they use Jira. If yes, prompt for JIRA_URL, JIRA_USER, JIRA_API_TOKEN (explain these are env vars for their shell profile, not written to config file)
   - Optional deps: inform about acli (enables Jira integration in Claude Code) and PyYAML (enables YAML config format). Offer to show install instructions. Never block setup if declined.

6. ## Step 4: Write workflow-config.conf
   - Write confirmed key=value pairs to workflow-config.conf in TARGET_REPO
   - If file exists: only ADD/UPDATE keys the user confirmed; do not overwrite other keys
   - dso.plugin_root is already written by dso-setup.sh — do not duplicate

7. ## Step 5: Copy DSO Templates (optional)
   - If TARGET_REPO/CLAUDE.md does not exist: offer to copy templates/CLAUDE.md.template
   - If TARGET_REPO/.claude/docs/ does not exist: offer to copy templates/KNOWN-ISSUES.example.md

8. ## Step 6: Success Summary
   - Print what was configured
   - Tell user to set env vars (JIRA_URL etc.) in their shell profile if they want Jira integration
   - Link to docs/INSTALL.md for full documentation

Skill invocations: Use /dso:project-setup (fully qualified, NOT /project-setup).

IMPORTANT: All skill references in the file must use /dso: prefix. bash scripts/check-skill-refs.sh will verify this.

ESCALATION POLICY: If you are unsure about any part of the wizard flow, the correct behavior for an edge case, or how a config key should be prompted — stop, add a note to ticket dso-0cjl describing the uncertainty, and report STATUS: fail with ESCALATION_REASON. Do NOT guess.

## Acceptance Criteria

- [ ] skills/project-setup/SKILL.md exists
  Verify: test -f /Users/joeoakhart/digital-service-orchestra/skills/project-setup/SKILL.md
- [ ] check-skill-refs.sh exits 0 on new file
  Verify: bash /Users/joeoakhart/digital-service-orchestra/scripts/check-skill-refs.sh 2>&1; test $? -eq 0
- [ ] Skill handles dso-setup.sh exit code 1 with abort
  Verify: grep -q 'Exit 1\|exit 1\|fatal' /Users/joeoakhart/digital-service-orchestra/skills/project-setup/SKILL.md
- [ ] Skill references CONFIGURATION-REFERENCE.md as authoritative source
  Verify: grep -q 'CONFIGURATION-REFERENCE' /Users/joeoakhart/digital-service-orchestra/skills/project-setup/SKILL.md
- [ ] Skill invocable as /dso:project-setup (no unqualified refs)
  Verify: bash /Users/joeoakhart/digital-service-orchestra/scripts/check-skill-refs.sh 2>&1 | grep -q '0 unqualified'

## Notes

**2026-03-18T08:04:03Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-18T08:04:23Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-18T08:04:23Z**

CHECKPOINT 3/6: Tests written (RED verified — SKILL.md does not exist) ✓

**2026-03-18T08:05:11Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-18T08:05:26Z**

CHECKPOINT 5/6: Validation passed ✓

**2026-03-18T08:06:06Z**

CHECKPOINT 6/6: Done ✓ — AC1 pass (file exists), AC2 pass (check-skill-refs exits 0), AC3 pass (exit 1 / fatal handling present), AC4 pass (CONFIGURATION-REFERENCE.md referenced), AC5: check-skill-refs exits 0 with no violations (the grep '0 unqualified' verify command returns false-negative on success because the script only prints that string on failure, but exit 0 from AC2 confirms no unqualified refs)
