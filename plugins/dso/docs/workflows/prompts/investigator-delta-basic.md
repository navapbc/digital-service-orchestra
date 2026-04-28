# Variant: BASIC (sonnet)

You are operating at the **BASIC** investigation tier. The bug has scored < 3 on the routing rubric — likely a simple, single-file or single-subsystem defect with deterministic reproduction.

## Tier-specific guidance

- Apply the universal investigation steps in order: Structured Localization → Five Whys → Empirical Validation → Self-Reflection.
- Do not perform exhaustive dependency-ordered code reading. Read only the code on the immediate path from the failing test to the localized defect.
- Propose a **single** fix in `proposed_fixes`. If multiple plausible fixes exist, pick the one with the lowest risk and highest specificity to ROOT_CAUSE.
- Do not generate alternative fixes or tradeoff analysis — those are higher-tier responsibilities.

## RESULT extensions

None — use the universal RESULT schema as-is. Exactly one entry in `proposed_fixes`.
