# Reviewer File Quality Checklist

Standard for all `/dso:review-protocol` reviewer prompt files, derived from auditing
the reference implementation in `${CLAUDE_PLUGIN_ROOT}/agents/ui-designer.md` and `${CLAUDE_PLUGIN_ROOT}/skills/ui-designer/docs/reviewers/`.

## File Structure

Each reviewer prompt file MUST contain these sections in order:

### 1. Header: Role Definition (required)

```markdown
# Reviewer: {Title}

You are a {Title} reviewing {what}. Your job is to evaluate {focus areas}.
{One sentence on what you care about / your perspective.}
```

**Criteria:**
- [ ] Clear professional title (e.g., "Senior Product Manager", not just "PM")
- [ ] States what is being reviewed (the artifact type)
- [ ] States the evaluation focus in one sentence
- [ ] Establishes the reviewer's priorities/values in one sentence

### 2. Scoring Scale (required, use verbatim)

```markdown
## Scoring Scale

| Score | Meaning |
|-------|---------|
| 5 | Exceptional — exceeds expectations, production-ready as-is |
| 4 | Strong — meets all requirements, only minor polish suggestions |
| 3 | Adequate — meets core requirements but has notable gaps to address |
| 2 | Needs Work — significant issues that must be resolved |
| 1 | Unacceptable — fundamental problems requiring substantial redesign |
| N/A | Not Applicable — this dimension does not apply |
```

**Criteria:**
- [ ] Identical scoring table across all reviewer files (consistency)
- [ ] No custom score meanings — use the standard table above

### 3. Dimensions Table (required)

```markdown
## Your Dimensions

| Dimension | What "4 or 5" looks like | What "below 4" looks like |
|-----------|--------------------------|---------------------------|
| dimension_name | Positive criteria description | Negative criteria description |
```

**Criteria:**
- [ ] Uses `snake_case` dimension names matching the JSON output
- [ ] Every dimension has BOTH a "4 or 5" AND a "below 4" description
- [ ] Descriptions are specific and observable, not vague (e.g., "All endpoints require authentication" not "Security is good")
- [ ] Descriptions reference domain-specific standards where applicable (WCAG criteria, pattern names, etc.)
- [ ] Includes N/A guidance for any dimension that might not apply (e.g., "Score null if story has no parent epic")

### 4. Input Sections (required)

```markdown
## Input Sections

You will receive:
- **Section Name**: Description of what this contains and what to pay attention to
```

**Criteria:**
- [ ] Lists every artifact the reviewer will receive
- [ ] Calls out specific parts to focus on (e.g., "pay close attention to the `aria` properties")
- [ ] Matches what the calling skill actually provides — no phantom inputs

### 5. Instructions (required)

```markdown
## Instructions

Evaluate the design on all {N} dimensions. For each, assign an integer score of
1-5 or `null` (N/A).

For any score below 4, you MUST provide a finding with {specific guidance on what findings should contain}.
```

**Criteria:**
- [ ] States total dimension count explicitly
- [ ] Mandates findings for scores below 4
- [ ] Specifies what findings must include beyond the standard fields (e.g., "cite WCAG criterion", "reference existing components by name", "suggest a simpler alternative")
- [ ] Includes any domain-specific review guidance (e.g., contrast ratio verification rules)

### 6. Output Reference (required)

The reviewer file defers to `REVIEW-SCHEMA.md` for the full JSON structure (to avoid
schema drift) and only specifies what's unique to this reviewer:

```markdown
Return your review as JSON conforming to `REVIEW-SCHEMA.md`, using perspective
label `"{Perspective Label}"` and these dimensions:

\`\`\`json
"dimensions": {
  "dimension_one": "<integer 1-5 | null>",
  "dimension_two": "<integer 1-5 | null>"
}
\`\`\`

{Domain-specific field instructions, if any.}
```

**Criteria:**
- [ ] States the exact `perspective` label string
- [ ] Shows the `dimensions` map with ALL dimension names from the table, each showing `"<integer 1-5 | null>"`
- [ ] Does NOT duplicate the full REVIEW-SCHEMA.md wrapper (`perspective`, `status`, `findings[]` structure) — defers to the schema doc
- [ ] Domain-specific finding fields documented as prose instructions after the dimensions block (e.g., "Include `wcag_criterion` in each finding")
- [ ] No inline `findings` array template — standard finding fields (`dimension`, `severity`, `description`, `suggestion`) come from REVIEW-SCHEMA.md

## Integration: Calling Skill Updates

When migrating a skill's inline perspectives to separate files, the calling SKILL.md must also be updated:

### Directory Structure

```
${CLAUDE_PLUGIN_ROOT}/skills/{skill-name}/
  SKILL.md
  docs/
    review-criteria.md      # Overview of all reviewers + launch/aggregation instructions
    reviewers/
      {reviewer-name}.md    # One file per perspective
```

### review-criteria.md (required)

Must contain:
- [ ] Overview paragraph stating the review's purpose and stage configuration
- [ ] Reviewer table: Reviewer title, prompt file path, perspective label, focus summary
- [ ] "Launching Reviews" section: how to construct the sub-agent prompt from the file
- [ ] "Score Aggregation Rules" section: pass/fail threshold and logging
- [ ] "Conflict Detection" section: common conflict patterns specific to this review's domain
- [ ] "Revision Protocol" section (can reference `/dso:review-protocol` if standard)

### SKILL.md Updates

- [ ] Remove inline perspective definitions
- [ ] Add `Read [docs/review-criteria.md](docs/review-criteria.md)` instruction at the review step
- [ ] Reference reviewer files by relative path in the perspectives list
- [ ] Preserve any sub-agent prompt requirements as part of the reviewer file's Instructions section (e.g., "Do NOT inflate scores", "Suggestions must be concrete")

## Quality Gates

A migrated reviewer file passes this checklist when:

1. **Standalone**: A sub-agent receiving ONLY the reviewer file + artifact can produce a valid review without needing the SKILL.md
2. **Schema-compliant**: The output reference defers to REVIEW-SCHEMA.md for structure and only specifies the perspective label, dimensions map, and domain-specific fields
3. **Specific**: Every dimension's pass/fail criteria are concrete enough that two reviewers would score the same artifact within 1 point of each other
4. **Complete**: N/A guidance exists for every conditionally-applicable dimension
5. **Domain-aware**: Domain-specific standards are cited where relevant (WCAG, Nielsen heuristics, pattern names, etc.)
6. **Actionable**: Instructions specify what findings must contain beyond the minimum (reference patterns by name, cite standards, suggest alternatives)
