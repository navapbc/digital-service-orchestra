# Explore Agent: Structured Output Template

## Exploration Request

{exploration_request}

---

## Output Format Requirements

Produce a **numbered list** of all relevant files found. Each entry in the list must include:

- **Number**: Sequential integer starting at 1
- **File path**: Relative path from the repository root
- **Relevance**: One of `primary` / `secondary` / `tangential`
  - `primary` — directly implements, tests, or configures the requested artifact
  - `secondary` — closely related (e.g., imports it, is imported by it, or shares a feature boundary)
  - `tangential` — referenced indirectly, or shares a naming pattern but not the same feature
- **Type**: One of `source` / `test` / `config` / `doc`

### Output Example

```
1. src/feature/handler.py — relevance: primary, type: source
2. tests/unit/test_handler.py — relevance: primary, type: test
3. src/feature/utils.py — relevance: secondary, type: source
4. docs/feature-overview.md — relevance: tangential, type: doc
5. config/defaults.yaml — relevance: secondary, type: config
```

Use this exact format. Do not omit the relevance or type fields for any entry.

---

## Term Matching

Match **all terms** from the exploration request independently. If the request mentions multiple categories (e.g., "ticket references, config files, and test helpers"), search for each term separately — not just the primary search term.

For each distinct term or category in the request:
1. Identify candidate files that match that term specifically.
2. Add them to the numbered list with the appropriate relevance and type.
3. Do not collapse separate terms into a single search pass.

---

## Completeness Self-Check

After producing the numbered file list, perform a **completeness check** on your own output:

1. Enumerate every distinct term or artifact named in the exploration request.
2. For each term, verify that at least one file in your list matches it.
3. If any term has zero matches, output the following warning line (one per missing term):

```
WARNING: No files found for term: <term>
```

4. If all terms are covered, output:

```
Completeness check: all terms covered.
```

Do not skip this self-check step.
