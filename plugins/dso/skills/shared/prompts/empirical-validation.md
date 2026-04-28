# Empirical Validation Directive

**Core principle: validate assumptions — never assume unobserved behavior.**

Every investigation step that forms a belief about how a tool, API, command, or external system behaves must be backed by empirical evidence before that belief informs a proposed fix. The distinction between "the documentation claims X" and "I tested and confirmed X actually works" is critical.

Required practices at every investigation tier:

1. **Run actual commands before proposing fixes** — when the bug involves a CLI tool, API, or external system, run the actual command (`--help`, `--generate-json`, a test invocation) to confirm assumed behavior. Do not propose a fix based on documentation alone.
2. **Distinguish documented vs. observed behavior** — label evidence as "stated in docs" vs. "tested and confirmed". Only "tested and confirmed" evidence supports a high-confidence fix proposal.
3. **Search for real-world usage** — when facing an unfamiliar tool or API, search GitHub or other code repositories for how other projects solve the same problem, rather than relying solely on official documentation.
4. **Test proposed approaches in isolation** — before committing to a fix approach, test the key assumption in isolation (a throwaway API call, a minimal reproduction script) to confirm it works as expected.

These practices apply to all investigation tiers. Investigation prompts and agents reference this directive instead of restating it inline.
