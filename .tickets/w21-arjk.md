---
id: w21-arjk
status: open
deps: [w21-l9r7]
links: []
created: 2026-03-20T00:29:44Z
type: task
priority: 1
assignee: Joe Oakhart
parent: dso-r2es
---
# IMPL-CORE: Create project-detect.sh with schema, stack delegation, and file presence detection

## Implementation — Core scaffold and first two detection categories

Create plugins/dso/scripts/project-detect.sh as an executable bash script that outputs structured key=value detection results.

## Deliverables

### 1. Script scaffold (plugins/dso/scripts/project-detect.sh)

Script header must include:
- Usage: project-detect.sh [project-dir]  defaults to pwd
- Output schema documentation comment block listing every key emitted, its type, and valid values
- set -uo pipefail
- Argument parsing: PROJECT_DIR from $1 or pwd, validate it is a directory
- SCRIPT_DIR resolution via BASH_SOURCE[0]
- Source or delegate to detect-stack.sh for stack detection

### 2. Detection category: stack (key=stack)

Delegate to detect-stack.sh:
```bash
DETECT_STACK="$SCRIPT_DIR/detect-stack.sh"
stack=$(bash "$DETECT_STACK" "$PROJECT_DIR")
echo "stack=$stack"
```

### 3. Detection category: existing file presence (key=files_present)

Check for presence of these files in PROJECT_DIR and output a comma-separated list of present file names:
- CLAUDE.md
- .claude/docs/KNOWN-ISSUES.md
- .pre-commit-config.yaml
- workflow-config.conf

```bash
files_present=""
for f in CLAUDE.md .pre-commit-config.yaml workflow-config.conf; do
  if [[ -f "$PROJECT_DIR/$f" ]]; then
    files_present+="$f,"
  fi
done
# strip trailing comma
files_present="${files_present%,}"
echo "files_present=${files_present}"
```

Also emit individual boolean keys for downstream consumer convenience:
- claude_md_present=true|false
- pre_commit_config_present=true|false
- workflow_config_present=true|false
- known_issues_present=true|false

### Output schema header comment block

The top of the script MUST include a comment block documenting ALL keys the script emits, their types, and valid values. This is the cross-story integration contract referenced in the story done definitions. Format:

```bash
# OUTPUT SCHEMA (key=value, one per line)
# stack=<string>             — one of: python-poetry|rust-cargo|golang|node-npm|convention-based|unknown
# files_present=<csv>        — comma-separated list of detected config files
# claude_md_present=<bool>   — true|false
# ...etc for all keys
```

### 4. TDD requirement

The RED task (w21-l9r7) writes tests for script existence, stack delegation, and file presence. This task turns those tests GREEN. Run bash tests/scripts/test-project-detect.sh before committing to verify the relevant test functions pass.

## File paths
- Create: plugins/dso/scripts/project-detect.sh (executable)

## Deployed state (independently green)

After committing this task alone:
- project-detect.sh exists and is executable
- Tests for script existence, stack delegation, and file presence pass (GREEN)
- Tests for categories not yet implemented (target enumeration, CI workflows, etc.) still FAIL
- No other tests in suite are broken

## Acceptance Criteria

- [ ] plugins/dso/scripts/project-detect.sh exists and is executable
  Verify: test -x /Users/joeoakhart/digital-service-orchestra/plugins/dso/scripts/project-detect.sh
- [ ] Script emits stack= key matching detect-stack.sh output for a python-poetry fixture
  Verify: TMPD=$(mktemp -d) && touch "$TMPD/pyproject.toml" && bash /Users/joeoakhart/digital-service-orchestra/plugins/dso/scripts/project-detect.sh "$TMPD" | grep -q 'stack=python-poetry' && rm -rf "$TMPD"
- [ ] Script emits files_present= key listing detected config files
  Verify: TMPD=$(mktemp -d) && touch "$TMPD/CLAUDE.md" && bash /Users/joeoakhart/digital-service-orchestra/plugins/dso/scripts/project-detect.sh "$TMPD" | grep -q 'files_present=.*CLAUDE.md' && rm -rf "$TMPD"
- [ ] Script emits claude_md_present=true when CLAUDE.md present
  Verify: TMPD=$(mktemp -d) && touch "$TMPD/CLAUDE.md" && bash /Users/joeoakhart/digital-service-orchestra/plugins/dso/scripts/project-detect.sh "$TMPD" | grep -q 'claude_md_present=true' && rm -rf "$TMPD"
- [ ] Script emits claude_md_present=false when CLAUDE.md absent
  Verify: TMPD=$(mktemp -d) && bash /Users/joeoakhart/digital-service-orchestra/plugins/dso/scripts/project-detect.sh "$TMPD" | grep -q 'claude_md_present=false' && rm -rf "$TMPD"
- [ ] Script exits 0 on an empty directory (graceful degradation)
  Verify: TMPD=$(mktemp -d) && bash /Users/joeoakhart/digital-service-orchestra/plugins/dso/scripts/project-detect.sh "$TMPD"; STATUS=$?; rm -rf "$TMPD"; test "$STATUS" -eq 0
- [ ] Script contains OUTPUT SCHEMA comment block with key documentation
  Verify: grep -q 'OUTPUT SCHEMA' /Users/joeoakhart/digital-service-orchestra/plugins/dso/scripts/project-detect.sh
- [ ] bash tests/scripts/test-project-detect.sh passes for script_existence and file_presence test functions
  Verify: bash /Users/joeoakhart/digital-service-orchestra/tests/scripts/test-project-detect.sh 2>&1 | grep -E 'test_project_detect_(exists|file_presence|stack)' | grep -v FAIL

