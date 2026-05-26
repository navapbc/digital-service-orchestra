# Empirical Validation Directive

**Core principle: validate assumptions — never assume unobserved behavior.**

Every investigation step that forms a belief about how a tool, API, command, or external system behaves must be backed by empirical evidence before that belief informs a proposed fix. The distinction between "the documentation claims X" and "I tested and confirmed X actually works" is critical.

## Evidence Taxonomy

Not all evidence is empirical in the same way. Classify each hypothesis test before recording it:

**empirical-static** — The hypothesis is about the *content* of an artifact: a file exists, a config value is X, a field is present, a string appears in a file. Static tools (`grep`, `cat`, `Read`, `head`, `wc`) are valid for static hypotheses.

**empirical-dynamic** — The hypothesis is about *runtime behavior*: what happens when a workflow runs, whether a cleanup step fires, whether a script triggers on a lifecycle event, how the system responds to an input. Dynamic hypotheses REQUIRE executing the actual code path. `grep`, `cat`, `Read`, `head`, and `wc` are NOT valid for dynamic hypotheses — they observe source text, not behavior.

**Behavioral hypotheses require dynamic evidence.** A hypothesis that uses runtime keywords — "runs", "fires", "triggers", "cleans up", "executes", "emits", "skips", "handles" — is a dynamic hypothesis. Reading source code cannot confirm what code does at runtime. Even if the code reads as though it would produce behavior X, only executing the code path confirms that it does.

**Static evidence for a dynamic hypothesis** — a grep/Read of source files that returns output matching the expected behavior — is NOT confirmation. It is documentation evidence. Record it as "stated in source code" and mark the verdict `inconclusive`, not `confirmed`.

## Required practices at every investigation tier:

1. **Classify each hypothesis before testing** — identify whether it is static (about artifact content) or dynamic (about runtime behavior). Record the classification in the hypothesis_test entry.
2. **Run actual commands before proposing fixes** — when the bug involves a CLI tool, API, external system, or internal workflow/script behavior, execute the actual code path to confirm assumed behavior. Do not propose a fix based on documentation or source-code reading alone.
3. **Distinguish documented vs. observed behavior** — label evidence as "stated in docs/source" vs. "tested and confirmed". Only "tested and confirmed by execution" evidence supports a high-confidence fix proposal.
4. **Search for real-world usage** — when facing an unfamiliar tool or API, search GitHub or other code repositories for how other projects solve the same problem, rather than relying solely on official documentation.
5. **Test proposed approaches in isolation** — before committing to a fix approach, test the key assumption in isolation (a throwaway API call, a minimal reproduction script, executing the relevant script with test inputs) to confirm it works as expected.

These practices apply to all investigation tiers. Investigation prompts and agents reference this directive instead of restating it inline.
