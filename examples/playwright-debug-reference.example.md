<!--
  TEMPLATE: playwright-debug-reference.example.md
  ================================================
  This is an EXAMPLE TEMPLATE — not a real project configuration.

  HOW TO USE:
  1. Copy this file to your project repository (suggested path: docs/playwright-debug-reference.md)
  2. Replace all placeholder content with your project's framework-specific details
  3. Set the path in workflow-config.yaml:

       skills:
         playwright_debug_reference: docs/playwright-debug-reference.md

  The /dso:playwright-debug skill reads sections from this file by header name.
  Section headers below define a contract with the plugin — do NOT rename them
  without updating the plugin's Read call targets in ${CLAUDE_PLUGIN_ROOT}/skills/playwright-debug/SKILL.md.

  Sections required by the plugin (all 7 must be present):
    - Symptom-to-Code-Path Table
    - Code Reading Patterns
    - Example Hypotheses
    - Tier 2 Evidence Examples
    - Framework-Specific Constraints
    - Staging Configuration
    - Worked Example
-->

# Playwright Debug: Project-Specific Reference

<!-- Replace this header comment with your project name and stack summary, e.g.:
     "Project-specific companion to /dso:playwright-debug for the Acme Rails app.
      Stack: Rails 7 / ERB / ActiveRecord / PostgreSQL."
-->

## When NOT to Use (Project-Specific)

<!-- List conditions where /dso:playwright-debug is NOT the right tool for this project.
     Examples:
       - The bug is confirmed server-side (check Rails logs, Sidekiq queue, Sentry)
       - You need to validate a full deployment pipeline — use your staging-test skill instead
       - The failure is a flaky Capybara/RSpec test — check spec/support/ fixtures first
-->

- The bug is confirmed server-side — check application logs or your server-side test suite
- You need to validate a full end-to-end deployment workflow — use your project's staging-test skill
- *(Add more project-specific exclusions here)*

---

## Symptom-to-Code-Path Table

<!-- Map each observable symptom type to the first place to look in YOUR project's source tree.
     The skill uses this table to orient Tier 1 code analysis.

     The table below shows two example frameworks:
       - Next.js (React): a modern JavaScript framework with server components and API routes
       - Rails/ERB: a traditional MVC framework (shown in the Worked Example section)

     Replace both with your actual stack.
-->

Map the symptom to its source in your project's stack:

| Symptom type | Where to look first |
|---|---|
| Element not visible | React component (`components/`), conditional JSX (`{condition && <El>}`), CSS module class, `useState` toggle |
| Wrong data displayed | API route (`pages/api/` or `app/api/`), server component `fetch()`, React Query cache |
| Form submit fails | `<form>` `action`/`onSubmit`, Next.js Server Action, API route handler |
| JS error | Browser console, `pages/` or `app/` client component, `useEffect` hook |
| API response wrong | `pages/api/` route handler, Prisma/ORM query, response serialization |
| Redirect unexpected | Next.js `redirect()`, middleware in `middleware.ts`, `router.push()` |
| Styles not applied | CSS module import path, Tailwind class typo, conflicting global style |
| Interactive element unresponsive | `onClick` handler, `useEffect` dependency array, hydration mismatch |
| Missing content | Server-side data fetch failure, null/undefined guard, auth/permission check |
| Layout broken | Flexbox/grid parent class, responsive breakpoint, missing container |

---

## Code Reading Patterns

<!-- List the Grep and Read patterns that are most useful for navigating YOUR codebase.
     Frame these around your framework's conventions — file naming, directory structure,
     how routes are declared, how templates reference data, how styles are applied.

     The example below is for a Next.js (App Router) project.
     Replace with your actual patterns.
-->

Use Read and Grep to examine your project's code:

1. **Page components / routes**: `Grep pattern="export default function" path="app/"` to find the relevant page or layout component
2. **API routes**: `Grep pattern="export (async )?function (GET|POST|PUT|DELETE)" path="app/api/"` to find the handler
3. **Data fetching**: Read the page component — look for `fetch()` calls, `use client` directives, and `Suspense` boundaries
4. **CSS modules**: `Grep pattern="styles\.\w+" path="app/"` to find class references; then read the corresponding `.module.css` file
5. **Shared state**: `Grep pattern="useContext\|createContext\|zustand\|jotai" path="app/"` to find global state sources
6. **Auth/permissions**: `Grep pattern="session\|getServerSession\|redirect.*login" path="app/"` for auth guards that may block rendering

---

## Example Hypotheses

<!-- Provide 2-4 ranked example hypotheses for a BUG THAT IS REALISTIC IN YOUR PROJECT.
     Show how a developer should think through the symptom → code path → ranked explanation chain.
     Make the example concrete: name real file paths, real variable names, real selectors.

     The example below uses a Next.js "publish button not visible" scenario.
     Replace with something representative of your own bugs.
-->

Example ranked hypotheses for a Next.js publish button visibility bug:

```
H1 (most likely): The publish button is wrapped in `{post.status === 'draft' && <PublishButton>}`
    in `app/posts/[id]/page.tsx` and the post fetched from the API has status 'published',
    so the JSX conditional evaluates to false and the button is never rendered.

H2: The PublishButton component is rendered but has Tailwind class `hidden` applied via
    a conditional `className={canPublish ? '' : 'hidden'}`, and `canPublish` is derived
    from a session check that returns false for the current test user's role.

H3: A `useEffect` hook in `components/PostToolbar.tsx` is supposed to call `setVisible(true)`
    after checking permissions, but the async permission fetch is failing silently and
    the default state `visible: false` is never updated.
```

---

## Tier 2 Evidence Examples

<!-- Show project-specific batched browser_run_code examples using REAL selectors from your project.
     The goal is to illustrate the batching principle (one call, multiple hypotheses) with
     selectors that a developer on this project would actually use.

     ANTI-PATTERN (show what NOT to do):
       - One call per hypothesis
       - Generic selectors that don't match the project

     PREFERRED PATTERN:
       - One batched call per investigation
       - Real selectors from the project's HTML/CSS

     The examples below use Next.js / React class names.
     Replace with your actual component class names and data attributes.
-->

### Anti-pattern (4 separate calls, ~40k tokens):

```javascript
// Call 1
async (page) => document.querySelector('[data-testid="publish-btn"]') !== null

// Call 2
async (page) => getComputedStyle(document.querySelector('[data-testid="publish-btn"]')).display

// Call 3
async (page) => document.querySelector('.PostToolbar') !== null

// Call 4
async (page) => document.querySelectorAll('[data-post-id]').length
```

### Preferred pattern (1 batched call, ~10k tokens):

```javascript
async (page) => {
  const publishBtn = document.querySelector('[data-testid="publish-btn"]');
  const toolbar = document.querySelector('.PostToolbar');
  return {
    // H1: is the publish button in the DOM at all?
    publishBtnInDom: publishBtn !== null,
    // H2: is it present but hidden via CSS?
    publishBtnDisplay: publishBtn ? getComputedStyle(publishBtn).display : 'not in DOM',
    publishBtnHasHiddenClass: publishBtn ? publishBtn.classList.contains('hidden') : null,
    // H3: did the toolbar render?
    toolbarInDom: toolbar !== null,
    // Context: what is the post status badge showing?
    postStatusBadge: document.querySelector('[data-post-status]')?.textContent ?? null,
    // Context: any auth/permission error messages?
    errorMessages: Array.from(document.querySelectorAll('.alert-error, [role="alert"]'))
                       .map(el => el.textContent.trim()),
    pageTitle: document.title,
  };
}
```

---

## Framework-Specific Constraints

<!-- Document Tier 3 interaction patterns that require special handling in your project.
     Common examples:
       - Custom file upload widgets (hidden input behind a dropzone overlay)
       - Rich text editors (ProseMirror, Slate, TipTap) that intercept keyboard events
       - Date pickers that open a shadow-DOM calendar
       - Drag-and-drop interfaces
       - Modal dialogs that trap focus
       - Server-rendered components with hydration delays

     For each constraint: describe the issue and provide the correct browser_run_code or
     browser_* tool sequence to work around it.

     The example below is for a Next.js project with a custom image upload widget.
     Replace with your actual constraints.
-->

### Custom image upload widget (Tier 3)

The profile page uses a drag-and-drop image uploader (`components/ImageUploader.tsx`) that wraps
<!-- REVIEW-DEFENSE: dropzone is a generic open-source JS library (Dropzone.js) used in React/Next.js projects — not Lockpick-specific. See npmjs.com/package/dropzone. -->
a hidden `<input type="file">` behind a styled `<div class="dropzone">`. Standard `browser_click`
on the dropzone will open the OS file picker, which Playwright cannot control. Use `browser_run_code`
with `setInputFiles` targeting the hidden input directly:

```javascript
async (page) => {
  await page.locator('input[type="file"][data-upload-target]').setInputFiles(
    '<REPO_ROOT>/test/fixtures/sample-avatar.png'
  );
}
```

The test fixture must be inside the worktree (not `/tmp/`). Store fixtures in `test/fixtures/` (gitignored).

### Rich text editor (Tier 3)

The post body editor uses TipTap. Standard `browser_type` into the editor container will not work.
Use `browser_run_code` to inject content programmatically:

```javascript
async (page) => {
  // TipTap exposes a ProseMirror editor; dispatch an input event to the contenteditable
  const editor = document.querySelector('.ProseMirror');
  editor.focus();
  document.execCommand('insertText', false, 'Your test content here');
}
```

---

## Staging Configuration

<!-- Document environment-specific configuration for your staging/preview environment.
     Include:
       - Staging URL (or how to find it)
       - Expected operation timeouts for async processes
       - Any staging-specific authentication steps
       - Known staging-only behaviors that differ from local dev

     The example below is for a Next.js app deployed to Vercel with background job processing.
     Replace with your actual staging details.
-->

Staging uses real external services and background job processing (15-90s per job). Use `browser_wait_for`
for steps that trigger async work:

```
browser_wait_for(text: "Processing complete", time: 90)
```

The default 5s timeout will fail on staging. For steps that only load data (no background jobs), 15s is sufficient.

**Staging URL**: https://your-project.vercel.app  *(replace with actual URL)*

**Staging auth**: Staging uses the same OAuth flow as production. Use a dedicated staging test account
(credentials in your team's password manager under "Staging QA Account") — do not use personal accounts.

**Known staging-only behaviors**:
- CDN caching: static assets are cached 1hr on staging; hard-refresh (`Ctrl+Shift+R`) if styles appear stale
- Email delivery: staging sends to Mailtrap, not real addresses — check the Mailtrap inbox for confirmation emails

---

## Worked Example

<!-- Provide a complete end-to-end debugging walkthrough using a real (or representative) bug
     from your project. Show all three tiers even if only Tier 1 or Tier 2 was needed.
     Include:
       - The bug as reported
       - Tier 1: which files you read, what code you found, the hypotheses you formed
       - The escalation decision (did code analysis resolve it? if not, why not?)
       - Tier 2 (if used): the batched browser_run_code call and its result
       - Tier 3 (if used): the interactive steps and what they revealed
       - The fix
       - Token cost comparison

     The example below uses Rails/ERB to demonstrate that this skill is framework-agnostic.
     A real project reference file would use the project's own stack throughout.
-->

### "Dashboard Chart Not Rendering for New Accounts" (Rails/ERB example)

**Reported bug**: New user accounts see a blank chart on the dashboard. Existing accounts see the chart correctly. No JS errors reported.

#### Tier 1: Code Analysis

Find the dashboard route:

```bash
# Find the controller action
Grep pattern="def dashboard" path="app/controllers/"
# → app/controllers/dashboard_controller.rb: def dashboard
```

Read the controller:

```ruby
# app/controllers/dashboard_controller.rb
def dashboard
  @stats = current_user.stats_for_last_30_days
  @chart_data = @stats.map { |s| { date: s.date, value: s.count } }
  render :dashboard
end
```

Read the template:

```erb
<!-- app/views/dashboard/dashboard.html.erb -->
<% if @chart_data.present? %>
  <div id="activity-chart" data-chart='<%= @chart_data.to_json %>'></div>
<% else %>
  <div class="empty-state">No data yet. Check back after your first activity.</div>
<% end %>
```

Read the `stats_for_last_30_days` model method:

```ruby
# app/models/user.rb
def stats_for_last_30_days
  activities.where('created_at > ?', 30.days.ago).group_by_day(:created_at).count
end
```

**Hypotheses generated:**

```
H1 (most likely): New accounts have no `activities` records, so `stats_for_last_30_days`
    returns an empty hash. `@chart_data` is `[]`, `@chart_data.present?` is false, and the
    `<% if %>` block renders the empty-state div instead of the chart div.

H2: The chart JavaScript in `app/javascript/charts.js` expects `data-chart` to contain
    a non-empty JSON array and silently no-ops when it receives `[]` — but the chart container
    IS rendered and just appears blank (a CSS visibility issue masking as a data issue).

H3: The `activities` association has a default scope that filters out records created
    within the first 24 hours, unintentionally hiding all new-account data.
```

**H1 is testable from code alone.** The conditional `@chart_data.present?` when `@chart_data = []`
evaluates to false in Rails — this is conclusively traceable. No browser needed.

**Tier 1 verdict**: H1 confirmed. Root cause is the empty-state branch being rendered instead of the chart.

**Fix**:

```erb
<!-- Before: hides chart entirely for new users with no data -->
<% if @chart_data.present? %>
  <div id="activity-chart" data-chart='<%= @chart_data.to_json %>'></div>
<% else %>
  <div class="empty-state">No data yet.</div>
<% end %>

<!-- After: always render the chart container; let JS handle the empty state gracefully -->
<div id="activity-chart" data-chart='<%= @chart_data.to_json %>'
     <% if @chart_data.empty? %>data-empty="true"<% end %>></div>
```

Update `app/javascript/charts.js` to handle `data-empty` with a zero-state message inside the chart.

**Total token cost for this debugging session**: ~4k (Tier 1 only).
Compared to a full browser walkthrough (navigate, screenshot, inspect): ~114k.
**Savings: ~96%.**

---

*This file is part of the Digital Service Orchestra plugin. See `${CLAUDE_PLUGIN_ROOT}/skills/playwright-debug/SKILL.md`
for the generic 3-tier methodology that consumes this file.*
