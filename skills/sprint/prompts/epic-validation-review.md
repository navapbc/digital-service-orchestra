## Epic Validation Review
Epic: {title} ({id})
Type: {epic-type}

### What Changed
{list of files from git diff --name-only main...HEAD}

### Context
Project-wide validation (/validate-work) has already passed.
Your job is epic-specific quality assessment only — do NOT re-run
format, lint, or unit tests (already verified).

### Your Task

1. If this is a UI epic:
   a. Start the application if not running:
      cd {repo_root}/app && make db-start && USE_MOCK_LLM=true docker compose up -d
   b. Wait for health check: poll http://localhost:3000/health
   c. Navigate to each affected page
   d. Take screenshots of key states (save to `.claude/screenshots/`)
   e. Check accessibility (aria attributes, keyboard navigation, color contrast)
   f. Test the happy path user flow end-to-end
   g. Test error states and edge cases

2. If this is a backend-only epic:
   a. Test API endpoints affected by changes (if applicable)
   b. Verify response formats and error handling

### Scoring Rubric

**For UI epics** — score each dimension, final score = min(all dimensions):

| Dimension | 5 (Perfect) | 3 (Acceptable) | 1 (Failing) |
|-----------|-------------|-----------------|-------------|
| Functionality | All features work, edge cases handled | Core flow works, minor issues | Broken or missing features |
| Accessibility | ARIA labels, keyboard nav, contrast OK | Partial ARIA, some keyboard issues | No accessibility support |
| UX | Intuitive flow, clear feedback, no layout issues | Usable but rough edges | Confusing, broken layout |
| Regression | No existing tests broken | — | Existing tests broken |

**For backend-only epics**:

| Score | Criteria |
|-------|----------|
| 5 | All tests pass, no regressions, API contracts intact |
| 3 | Tests pass but minor issues found (e.g., slow responses, minor warnings) |
| 1 | Test failures or API contract breakage |

### Output Format

Report your findings exactly as:
- SCORE: {1-5}
- DIMENSIONS: {dimension}: {score} (UI epics only)
- PASS: {list of what works well}
- FAIL: {list of issues found, with specific details}
- REMEDIATION: {for each issue, a concrete one-line task description}

### Rules
- Do NOT: git commit, git push, tk close, tk status, edit .tickets/ files
- Do NOT modify any code — this is a read-only review
- Do NOT re-run format, lint, or unit tests (already verified by /validate-work)
- Be specific: include file paths, test names, exact error messages
