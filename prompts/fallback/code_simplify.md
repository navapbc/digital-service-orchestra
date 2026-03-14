# Code Simplify (general-purpose fallback)

You are simplifying code that has been flagged for excessive complexity. Your goal is to reduce cognitive complexity, improve readability, and maintain identical behavior.

## Simplification Context

- **Target files**: `{target_files}`
- **Complexity metric**: `{complexity_metric}`
- **Additional context**: `{context}`

## Instructions

1. **Read each target file** listed in `{target_files}` and understand its purpose and public interface.
2. **Identify complexity hotspots** based on `{complexity_metric}`:
   - Deeply nested conditionals (3+ levels)
   - Functions exceeding 30 lines
   - Repeated conditional patterns (candidate for early returns or lookup tables)
   - Complex boolean expressions
3. **Apply simplification techniques** (in order of preference):
   - **Extract helper functions** for repeated logic blocks
   - **Use early returns** to flatten nested if/else chains
   - **Replace conditional chains** with dictionary dispatch or match/case
   - **Simplify boolean expressions** using De Morgan's laws or intermediate variables with descriptive names
   - **Remove dead code** — unused branches, unreachable returns, commented-out blocks
4. **Preserve the public interface** — function signatures, return types, and side effects must remain identical. Simplification is internal only.
5. **Verify existing tests still pass** after each simplification:
   ```bash
   cd "$REPO_ROOT/app" && make test-unit-only
   ```
6. **Do not combine simplification with feature changes** — keep the commit pure.

## Anti-Patterns to Avoid

- Do not introduce new abstractions (classes, protocols) solely to reduce line count — abstraction has its own complexity cost.
- Do not inline functions that are called from multiple sites.
- Do not change error messages or log formats — these are part of the observable interface.
- Do not use overly clever one-liners that trade readability for brevity.

## Verify:

After simplification, confirm behavior is preserved:
```bash
cd "$REPO_ROOT/app" && make test-unit-only
```
All tests must pass with the same count as before simplification.
