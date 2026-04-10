!`bash -c 'timeout 3 claude plugin list 2>/dev/null | grep -q "digital-service-orchestra" && echo "PLUGIN_DETECTED" || echo "LOCAL_FALLBACK"'`

If the line above shows PLUGIN_DETECTED: Use the Skill tool to invoke `/dso:preplanning` with arguments: $ARGUMENTS. When the Skill tool succeeds, do NOT also read the skill file — the content is already in your context; proceed to follow it directly.

If the Skill tool fails or returns an error (e.g., "Unknown skill"): Read the skill file at `plugins/dso/skills/preplanning/SKILL.md` and follow its instructions with arguments: $ARGUMENTS

If the line above shows LOCAL_FALLBACK: Read the skill file at `plugins/dso/skills/preplanning/SKILL.md` and follow its instructions with arguments: $ARGUMENTS
