!`bash -c 'timeout 3 claude plugin list 2>/dev/null | grep -q "digital-service-orchestra" && echo "PLUGIN_DETECTED" || echo "LOCAL_FALLBACK"'`

If the line above shows PLUGIN_DETECTED: Use the Skill tool to invoke `/dso:interface-contracts` with arguments: $ARGUMENTS

If the Skill tool fails or returns an error (e.g., "Unknown skill"): Read the skill file at `plugins/dso/skills/interface-contracts/SKILL.md` and follow its instructions with arguments: $ARGUMENTS

If the line above shows LOCAL_FALLBACK: Read the skill file at `plugins/dso/skills/interface-contracts/SKILL.md` and follow its instructions with arguments: $ARGUMENTS
