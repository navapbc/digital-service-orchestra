---
applyTo: "**/*.sh"
---

# Bash Coverage Areas

Coverage areas for bash:

- Quoting of variables in conditionals and command arguments.
- Shell options (`set -euo pipefail`) and pipeline exit handling.
- Exit codes on error paths, especially in hook scripts that must block an
  operation.
- Concurrency and temp-file handling.

Project conventions (facts, not severity guidance):

- Hook and plugin scripts prefer `parse_json_field`, `json_build`, or
  `python3` over `jq` for JSON parsing. Flag `jq` use in hook/plugin
  scripts where a jq-free alternative exists.
- `/tmp` writes go through `mktemp`.
