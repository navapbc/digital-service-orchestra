---
id: dso-6ye6
status: open
deps: [dso-62hs, dso-9trm]
links: []
created: 2026-03-23T03:58:36Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-7mlx
---
# Implement _phase_migrate in cutover-tickets-migration.sh

Implement the _phase_migrate stub in plugins/dso/scripts/cutover-tickets-migration.sh to convert all .tickets/*.md files to event files using the new ticket CLI commands.

TDD REQUIREMENT: Tests from Task dso-62hs must be RED before starting. After implementation, all 5 migrate tests must turn GREEN.

Implementation details:

1. Introduce two new env vars at the top of the script:
   - CUTOVER_TICKETS_DIR (default: REPO_ROOT/.tickets) — source directory
   - CUTOVER_TRACKER_DIR (default: REPO_ROOT/.tickets-tracker) — destination directory

2. Replace _phase_migrate() stub body with:

   a. Export TICKET_COMPACT_DISABLED=1 at start of phase; unset at end (use trap or explicit unset).

   b. Parse each .tickets/*.md file:
      - Use python3 to parse YAML frontmatter between --- delimiters
      - Fields to extract: id, status, type (default: task), priority (default: 2), parent, deps (list), links (list), notes sections
      - If frontmatter is missing or malformed: print 'WARN: skipping malformed ticket <filename>' to stderr and continue (do not exit non-zero)
      - Skip non-ticket files: .index.json, README.md, any file without .md extension

   c. Idempotency check: before calling ticket create for ticket ID <id>, check if CUTOVER_TRACKER_DIR/<id>/*-CREATE.json exists. If yes, print 'Skipping already-migrated ticket: <id>' and continue.

   d. Create ticket: call ticket-create.sh <type> <title> [parent_id] (or equivalent 'ticket create' CLI). The ticket ID returned by ticket-create.sh will be a new auto-generated ID. Since we must preserve old IDs, we must either:
      - Use the ticket CLI's ID preservation feature (if available), OR
      - Create the ticket directory with the old ID and write the CREATE event manually using ticket-lib.sh's write_commit_event function with the old ID as the directory name.
      Check ticket-create.sh for --id flag support first; if absent, use write_commit_event approach.

   e. Transition status: if status != 'open', call ticket-transition.sh <id> open <status>.

   f. Migrate notes: for each timestamped note block in the Notes section, call ticket-comment.sh <id> <body>. Use python3 json.dumps() to safely encode bodies with special characters.

   g. Migrate deps: for each dep in deps list, call ticket-link.sh link <id> <dep_id> depends_on.

   h. Migrate parent: if parent field set, call ticket-link.sh link <id> <parent_id> blocks (or verify how parent/child is encoded in the new system and use the appropriate relation).

   i. Print progress: 'Migrated: <id> (<type>)' for each successful ticket.

3. At end of phase: unset TICKET_COMPACT_DISABLED.

4. Print summary: 'Migration complete: N tickets migrated, M skipped (already done), K skipped (malformed)'

File to edit: plugins/dso/scripts/cutover-tickets-migration.sh

## Acceptance Criteria

- [ ] bash tests/scripts/test-cutover-tickets-migration.sh passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/scripts/test-cutover-tickets-migration.sh
- [ ] ruff check passes (exit 0)
  Verify: ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] ruff format --check passes (exit 0)
  Verify: ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] CUTOVER_TICKETS_DIR env var is supported in the script
  Verify: grep -q 'CUTOVER_TICKETS_DIR' $(git rev-parse --show-toplevel)/plugins/dso/scripts/cutover-tickets-migration.sh
- [ ] CUTOVER_TRACKER_DIR env var is supported in the script
  Verify: grep -q 'CUTOVER_TRACKER_DIR' $(git rev-parse --show-toplevel)/plugins/dso/scripts/cutover-tickets-migration.sh
- [ ] TICKET_COMPACT_DISABLED is exported during _phase_migrate
  Verify: grep -q 'TICKET_COMPACT_DISABLED' $(git rev-parse --show-toplevel)/plugins/dso/scripts/cutover-tickets-migration.sh
- [ ] All 5 migrate tests from Task dso-62hs turn GREEN
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-cutover-tickets-migration.sh 2>&1 | grep -qv 'FAIL.*migrate'
- [ ] Script source: grep confirms idempotency check is present
  Verify: grep -q 'already-migrated\|already_migrated\|SKIP\|skip' $(git rev-parse --show-toplevel)/plugins/dso/scripts/cutover-tickets-migration.sh

