# Acceptance Criteria Template Library

> Composable criteria blocks for sub-agent task verification.
> Read once by `/dso:implementation-plan` Step 3; sub-agents never read this file.

## Universal Criteria (applied to ALL tasks)

- [ ] `make test-unit-only` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel)/app && make test-unit-only
- [ ] `make lint` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel)/app && make lint
- [ ] `make format-check` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel)/app && make format-check

## Category: New Source File

- [ ] `src/{path}/{file}.py` exists
  Verify: cd $(git rev-parse --show-toplevel)/app && test -f src/{path}/{file}.py
- [ ] Class `{ClassName}` is importable from `src.{module}.{file}`
  Verify: cd $(git rev-parse --show-toplevel)/app && python -c "from src.{module}.{file} import {ClassName}"
- [ ] `make lint-mypy` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel)/app && make lint-mypy

## Category: New Test File

- [ ] `tests/unit/test_{file}.py` exists
  Verify: cd $(git rev-parse --show-toplevel)/app && test -f tests/unit/test_{file}.py
- [ ] Test file contains at least {N} test functions
  Verify: cd $(git rev-parse --show-toplevel)/app && grep -c "def test_" tests/unit/test_{file}.py | awk '{exit ($1 < {N})}'

## Category: API Endpoint

- [ ] Route registered for {METHOD} {path}
  Verify: cd $(git rev-parse --show-toplevel)/app && grep -rq "route.*{path}" src/api/
- [ ] Success case test exists
  Verify: cd $(git rev-parse --show-toplevel)/app && grep -q "def test_{endpoint}_success" tests/unit/api/test_{blueprint}_routes.py
- [ ] Error case test exists (422 validation)
  Verify: cd $(git rev-parse --show-toplevel)/app && grep -q "def test_{endpoint}.*error\|def test_{endpoint}.*invalid" tests/unit/api/test_{blueprint}_routes.py
- [ ] Error responses follow RFC 7807 Problem Detail format
  Verify: cd $(git rev-parse --show-toplevel)/app && pytest tests/unit/api/test_{blueprint}_routes.py::test_error_format

## Category: Database Model

- [ ] Migration file exists in `migrations/versions/`
  Verify: cd $(git rev-parse --show-toplevel)/app && ls src/db/migrations/versions/*_{description}.py
- [ ] Model class defined with `created_at` and `updated_at` columns
  Verify: cd $(git rev-parse --show-toplevel)/app && grep -q "created_at\|updated_at" src/db/models/{model}.py
- [ ] Round-trip persistence test exists
  Verify: cd $(git rev-parse --show-toplevel)/app && grep -rq "def test_.*round_trip\|def test_.*persistence" tests/

## Category: Bug Fix

- [ ] Regression test `test_{issue_id}_{description}` exists
  Verify: cd $(git rev-parse --show-toplevel)/app && grep -rq "def test_{issue_id}" tests/unit/
- [ ] Test reproduces the original bug scenario
  Verify: cd $(git rev-parse --show-toplevel)/app && pytest tests/unit/test_{module}.py::test_{issue_id}_{description}

## Category: UI / Template

- [ ] Template file exists at `src/templates/{path}`
  Verify: cd $(git rev-parse --show-toplevel)/app && test -f src/templates/{path}
- [ ] Template extends base layout
  Verify: cd $(git rev-parse --show-toplevel)/app && grep -q "extends" src/templates/{path}
- [ ] `make test-visual` passes (exit 0) — or baselines updated
  Verify: cd $(git rev-parse --show-toplevel)/app && make test-visual

## Category: Refactoring

- [ ] All pre-existing tests pass without modification
  Verify: cd $(git rev-parse --show-toplevel)/app && make test-unit-only
- [ ] No public interface signatures changed (or migration documented)
  Verify: git diff HEAD -- 'src/**/__init__.py' | grep -c "^-.*def \|^-.*class " | awk '{exit ($1 > 0)}'

## Category: Pipeline Agent

- [ ] Agent class in `src/agents/{name}.py` implements `BaseAgent`
  Verify: cd $(git rev-parse --show-toplevel)/app && python -c "from src.agents.{name} import {AgentClass}; from src.agents.base import BaseAgent; assert issubclass({AgentClass}, BaseAgent)"
- [ ] Agent registered in pipeline configuration
  Verify: cd $(git rev-parse --show-toplevel)/app && grep -q "{name}" src/agents/pipeline.py
- [ ] Unit tests cover: happy path, empty input, malformed input
  Verify: cd $(git rev-parse --show-toplevel)/app && grep -c "def test_" tests/unit/agents/test_{name}.py | awk '{exit ($1 < 3)}'

## Category: Script / Tooling

- [ ] Script file exists and is executable
  Verify: test -x {script_path}
- [ ] Script outputs expected format (single-line structured output)
  Verify: {script_path} --help 2>&1 | head -1
- [ ] Script handles missing arguments gracefully (non-zero exit)
  Verify: { {script_path} 2>/dev/null; test $? -ne 0; }

## Category: Command / Skill / Artifact Migration

Use when a task removes, moves, or replaces a command, skill, script, or other workflow artifact.

- [ ] Old artifact no longer exists at original path
  Verify: ! test -f {old_path}
- [ ] Replacement artifact exists at new path
  Verify: test -f {new_path}
- [ ] Replacement contains project-specific workflow reference (not a generic stub)
  Verify: grep -q '{workflow_keyword}' {new_path}
- [ ] No external plugin silently masks the migrated artifact
  Verify: ! grep -q '"{artifact_name}.*claude-plugins-official.*true' .claude/settings.json || test -f {project_artifact_path}
- [ ] Behavioral smoke test: invoking the artifact produces project-specific behavior
  Verify: {behavioral_command}  # e.g., grep -q 'COMMIT-WORKFLOW' {new_path}

## Category: Skill / Workflow Modification

- [ ] Skill file is valid markdown
  Verify: test -f {skill_path}
- [ ] No broken internal references (file paths in skill exist)
  Verify: grep -oE '\$REPO_ROOT/[^ )`]+' {skill_path} | while read p; do test -e "$(git rev-parse --show-toplevel)/${p#\$REPO_ROOT/}" || echo "MISSING: $p"; done | grep -c MISSING | awk '{exit ($1 > 0)}'

## Category: RED Test Task

- [ ] Test file exists at expected path
  Verify: test -f {test_path}
- [ ] Test function exists by name
  Verify: grep -q 'def {test_name}' {test_path}
- [ ] Running the test returns non-zero exit pre-implementation
  Verify: python -m pytest {test_path}::{test_name} 2>&1; test $? -ne 0
- [ ] Test is behavioral: executes the code under test (calls a function, runs a script, or exercises a code path with inputs and asserts on outputs/side effects) — not a grep/sed scan of the source file for implementation strings. Structural tests (negative constraints, metadata validation, syntax checks) are exempt.
  Verify: manual review — test approach in task description describes what is executed and what output is asserted

## Category: Test-Exempt Task

Use when a task has no testable implementation artifact (e.g., documentation, configuration, skill files). Must include a justification citing one of the defined exemption criteria.

- [ ] Task description contains test-exempt justification citing one of the defined criteria
  Verify: grep -q 'test-exempt:' {ticket_path}

## Category: Security Boundary

Use when a task touches user input, authentication/authorization, or data access. Aligns with the security overlay (red team / blue team reviewer agents).

> **ARCH_ENFORCEMENT.md precedence**: This category provides project-agnostic baseline checks. If the host project's `ARCH_ENFORCEMENT.md` defines stricter security rules (e.g., mandatory parameterized queries, specific auth decorators, allowlist patterns), those project-specific rules take precedence over the criteria below.

- [ ] User input is validated/sanitized before use (no direct interpolation into queries, shells, or templates)
  Verify: grep -nE '(execute|eval|system|popen|render_template_string)\(.*\b(request|input|argv|params)\b' {changed_files} && echo "POTENTIAL UNSAFE INPUT" || echo "OK"
- [ ] Authentication/authorization check present on protected entry points
  Verify: grep -nE '(@login_required|@requires_auth|@permission|check_auth|verify_token)' {changed_files}
- [ ] Data access uses parameterized queries / ORM bindings (no string-concatenated SQL)
  Verify: grep -nE '(execute|executemany)\(.*[%+].*(request|input|user|args)' {changed_files} && echo "POTENTIAL SQLi" || echo "OK"
- [ ] Output rendered to HTML/JSON contexts is escaped or uses safe templating (no XSS sinks)
  Verify: grep -nE '(innerHTML|dangerouslySetInnerHTML|\|safe|Markup\(|mark_safe)' {changed_files}
- [ ] State-changing endpoints enforce CSRF protection (token, SameSite cookie, or equivalent)
  Verify: grep -nE '(csrf|CSRFProtect|SameSite|@csrf_exempt)' {changed_files}
- [ ] Secrets/credentials are not embedded in source (read from env or secret store)
  Verify: grep -nEi '(api[_-]?key|secret|password|token)\s*=\s*["\x27][A-Za-z0-9/_+=-]{12,}' {changed_files} && echo "POTENTIAL HARDCODED SECRET" || echo "OK"

## Category: Architectural Integrity

Use when a task modifies a public interface, schema, or shared model that other code consumes. Verifies downstream callers are accounted for and invariants are preserved.

> **ARCH_ENFORCEMENT.md precedence**: This category provides project-agnostic baseline checks. If the host project's `ARCH_ENFORCEMENT.md` defines stricter architectural rules (e.g., layering boundaries, allowed cross-module imports, interface stability tiers), those project-specific rules take precedence.

- [ ] Caller-list audit performed for every modified public symbol (signature, return type, or contract change)
  Verify: for sym in {modified_symbols}; do echo "=== $sym ==="; grep -rn "\b$sym\b" --include='*.py' --include='*.sh' --include='*.js' --include='*.ts' "$(git rev-parse --show-toplevel)" | grep -v "$(git diff --name-only HEAD | tr '\n' '|' | sed 's/|$//')"; done
- [ ] All downstream consumers of a changed interface are updated in the same commit (or migration path documented)
  Verify: git diff --name-only HEAD | xargs -I{} grep -l "{old_symbol}\|{new_symbol}" {} ; echo "Confirm caller list above matches files in diff"
- [ ] Schema migration is forward-compatible (additive change, default values, or explicit migration script)
  Verify: ls "$(git rev-parse --show-toplevel)"/migrations/ 2>/dev/null && git diff HEAD -- '*.sql' '*/migrations/*' | grep -E '^\+.*(DROP|ALTER.*DROP|RENAME)' && echo "POTENTIAL BREAKING MIGRATION" || echo "OK"
- [ ] Shared model invariants (required fields, value ranges, referential integrity) preserved or explicitly versioned
  Verify: grep -nE '(NOT NULL|CHECK|FOREIGN KEY|UNIQUE|@validator|Field\(.*required)' {changed_model_files}
- [ ] Public API/contract documentation updated alongside the change (if interface is documented)
  Verify: git diff --name-only HEAD | grep -qE '(docs/|README|CHANGELOG|openapi|schema)' && echo "DOCS UPDATED" || echo "REVIEW: docs may need update"

## Category: Internal Pattern Compliance

Use when a task has low pattern familiarity (new contributor, unfamiliar subsystem, or LLM-generated code). Guards against hallucinated patterns and reinvented utilities.

> **ARCH_ENFORCEMENT.md precedence**: This category provides project-agnostic baseline checks. If the host project's `ARCH_ENFORCEMENT.md` defines stricter pattern rules (e.g., mandatory use of specific helpers, banned stdlib modules, prescribed error types), those project-specific rules take precedence.

- [ ] Prior-art search performed before introducing a new pattern, helper, or abstraction
  Verify: grep -rnE '(class|def|function)\s+{new_symbol_pattern}' "$(git rev-parse --show-toplevel)" --include='*.py' --include='*.js' --include='*.ts' | head -20 ; echo "Confirm no existing equivalent"
- [ ] New code uses internal utilities/helpers where they exist (not stdlib reinventions)
  Verify: grep -nE '^(import|from) ' {changed_files} | grep -vE '(^(import|from) (src|app|lib|utils|common|internal)\.)' ; echo "Review imports above for missed internal equivalents"
- [ ] References to internal pattern catalog or convention docs match repository reality
  Verify: grep -oE '(docs/|\$REPO_ROOT/[^ )`]+|README[^ )`]*)' {changed_files} | while read p; do test -e "$(git rev-parse --show-toplevel)/${p#\$REPO_ROOT/}" 2>/dev/null || test -e "$(git rev-parse --show-toplevel)/$p" || echo "MISSING: $p"; done | grep -c MISSING | awk '{exit ($1 > 0)}'
- [ ] No fabricated module/function names (every imported symbol resolves)
  Verify: grep -nE '^(import|from) ' {changed_files} | awk '{print $2}' | sort -u ; echo "Spot-check each module exists in repo or installed deps"
- [ ] Generated code does not introduce a new dependency without justification (see CLAUDE.md "Prefer stdlib/existing dependencies")
  Verify: git diff HEAD -- pyproject.toml package.json requirements.txt Cargo.toml go.mod 2>/dev/null | grep -E '^\+' && echo "NEW DEPENDENCY — confirm justification" || echo "OK"
