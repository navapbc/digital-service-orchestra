# Tool Error Detail Template

Tool use errors are tracked automatically by the PostToolUseFailure hook (`track-tool-errors.sh`).
Errors are logged to `~/.claude/tool-error-counter.json`.

## Counter File Format

The counter file has two sections:

1. **index** — Category names with occurrence counts (the "at a glance" view)
2. **errors** — Full details of every error observed

```json
{
  "index": {
    "file_not_found": 3,
    "edit_string_not_unique": 1
  },
  "errors": [
    { "...see Error Detail below..." }
  ]
}
```

## Error Detail Schema

Each entry in the `errors` array must include these fields:

| Field | Type | Description |
|-------|------|-------------|
| `id` | integer | Auto-incrementing error number |
| `timestamp` | string | ISO 8601 UTC timestamp (e.g., `2026-02-07T14:30:00Z`) |
| `category` | string | Snake_case error category (see Standard Categories) |
| `tool_name` | string | The Claude Code tool that failed (e.g., `Read`, `Edit`, `Bash`) |
| `input_summary` | string | One-line description of what was attempted |
| `error_message` | string | The raw error message from the tool |
| `session_id` | string | Claude Code session identifier |

## Example Entry

```json
{
  "id": 1,
  "timestamp": "2026-02-07T14:30:00Z",
  "category": "file_not_found",
  "tool_name": "Read",
  "input_summary": "Attempted to read /app/src/missing_module.py",
  "error_message": "File not found: /app/src/missing_module.py",
  "session_id": "abc123-def456"
}
```

## Standard Categories

| Category | Description |
|----------|-------------|
| `file_not_found` | File does not exist at the specified path |
| `edit_string_not_unique` | Edit tool's old_string matched multiple locations |
| `edit_string_not_found` | Edit tool's old_string not found in file |
| `command_not_found` | Bash command not available |
| `command_exit_nonzero` | Command returned non-zero exit code |
| `permission_denied` | Insufficient permissions for the operation |
| `invalid_path` | Path is malformed or uses wrong directory structure |
| `syntax_error` | Code or command has syntax issues |
| `timeout` | Operation exceeded time limit |
| `write_failed` | File write operation failed |

New categories are created by Haiku when existing ones don't fit. Always use snake_case.

## Threshold Notification

When any category reaches **50** occurrences, a notification is emitted via hook output.
Notifications repeat at each subsequent multiple of 50.

## Manual Operations

```bash
# View the error index
python3 -c "import json; print(json.dumps(json.load(open('$HOME/.claude/tool-error-counter.json'))['index'], indent=2))"

# View errors for a specific category
python3 -c "import json; [print(json.dumps(e, indent=2)) for e in json.load(open('$HOME/.claude/tool-error-counter.json'))['errors'] if e['category']=='file_not_found']"

# Reset the counter (start fresh)
rm ~/.claude/tool-error-counter.json
```
