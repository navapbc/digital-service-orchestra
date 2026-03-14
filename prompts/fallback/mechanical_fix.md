# Mechanical Fix (general-purpose fallback)

You are fixing a mechanical code quality issue — linting errors, formatting violations, type check failures, or similar automated tooling failures. Apply precise, targeted fixes.

## Failure Context

- **Lint/tool command**: `{lint_command}`
- **Exit code**: `{exit_code}`
- **Stderr (tail)**: `{stderr_tail}`
- **Recently changed files**: `{changed_files}`
- **Additional context**: `{context}`

## Instructions

1. **Parse the error output** from `{stderr_tail}` to identify each distinct violation (file, line number, rule code).
2. **Categorize the violations**:
   - Auto-fixable (formatting, import sorting) — run the auto-fixer
   - Manual fix required (type errors, unused imports, undefined names) — fix by hand
3. **For auto-fixable issues**, run the project formatter:
   ```bash
   cd "$REPO_ROOT/app" && make format
   ```
4. **For type errors (mypy)**, read the flagged line and fix the type annotation or add a type-narrowing guard. Do not use `# type: ignore` unless the error is a known false positive.
5. **For lint violations (ruff)**, apply the fix suggested by the rule code. Common fixes:
   - `F401` (unused import): Remove the import
   - `F841` (unused variable): Remove or use the variable
   - `E501` (line too long): Break the line or shorten expressions
   - `I001` (import sorting): Run `make format`
6. **Re-run the failing command** to confirm all violations are resolved:
   ```bash
   {lint_command}
   ```
7. **Run the unit test suite** to ensure fixes did not introduce regressions:
   ```bash
   cd "$REPO_ROOT/app" && make test-unit-only
   ```

## Guidelines

- Fix only the reported violations — do not refactor surrounding code.
- If a fix requires understanding business logic (e.g., a type error in a complex generic), read the surrounding code before changing types.
- Prefer removing dead code over suppressing warnings about it.
- Use `$CLAUDE_PLUGIN_ROOT/scripts/` for any workflow-specific scripts referenced by the project.

## Verify:

After applying all fixes, confirm:
```bash
{lint_command}
```
The command must exit with code 0.
