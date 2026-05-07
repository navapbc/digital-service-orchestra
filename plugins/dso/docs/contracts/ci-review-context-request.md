# Contract: CI Review Context-Request

- Signal Name: ci-review-context-request
- Status: accepted
- Scope: ci-review LLM reviewer → dispatch_review() augmentation loop
- Version: 1

## Purpose

This contract defines the structured-request format used by LLM reviewers to request
additional file context during a CI code review. The dispatcher parses these request
blocks from assistant-role messages only and executes them before issuing a follow-up
completion call.

## Supported Actions

### `read_files`

Request the dispatcher to read one or more files from the repository and return their
contents as a new user message.

```json
{
  "action": "read_files",
  "paths": ["path/to/file.py", "another/file.ts"]
}
```

Fields:
- `action` (string, required): Must be `"read_files"`.
- `paths` (array of strings, required): Relative paths from the repository root.
  Absolute paths and parent-traversal sequences (`..`) are rejected.

### `grep`

Request the dispatcher to run a recursive grep over one or more repository paths and
return matching lines as a new user message.

```json
{
  "action": "grep",
  "patterns": ["pattern1", "pattern2"],
  "paths": ["src/", "tests/"],
  "timeout_seconds": 5
}
```

Fields:
- `action` (string, required): Must be `"grep"`.
- `patterns` (array of strings, required): One or more grep patterns (`-e` flags). At least one pattern must be provided.
- `paths` (array of strings, required): Repository-relative paths to search (files or directories). Paths are canonicalized and must resolve within the repo root jail.
- `timeout_seconds` (integer, optional): Wall-clock timeout. Defaults to `5` seconds (`_GREP_DEFAULT_TIMEOUT_SECONDS`).

Output is capped at 64 KB; a truncation marker is appended when the limit is reached.
Binary files are excluded (`--binary-files=without-match`).
On timeout, the dispatcher returns `timed_out: true` and no output — the turn proceeds
without grep results.

## Request-Precedence Rule

When an assistant message contains both a well-formed request block AND a final-findings
JSON block in the same turn, **the request takes precedence**. The dispatcher will
execute the request and issue a follow-up completion; the final-findings block in that
turn is deferred and not treated as the final output.

This rule prevents a class of LLM behavior where the model includes both a request and
tentative findings in the same response. The dispatcher always prefers the request so
that the model has an opportunity to produce grounded findings after seeing the file
content.

## Security Notes

- **File-system paths only**: Only repository-relative file paths are accepted. URLs,
  shell expressions, and glob patterns are not executed.
- **Repo-root jail enforced**: All paths are canonicalized via `os.path.realpath()` and
  verified to resolve within the repository root before any file I/O occurs.
- **Absolute paths rejected**: Any path beginning with `/` is rejected immediately,
  before canonicalization.
- **Parent traversal rejected**: Any path containing `..` sequences is rejected.
  Canonicalization also catches symlink-based escapes; the resolved path must begin
  with the canonical repository root.
- **Per-file size cap**: Files larger than `max_file_bytes` (default 256 KB / 262,144
  bytes) are truncated. A truncation marker is appended to inform the model that the
  content is incomplete:

  ```
  [TRUNCATED: file exceeded 262144 bytes — do not assert absence of content based on this truncated read]
  ```

## Parser Rules

- The parser scans **only assistant-role messages** for request blocks.
- User-role messages are never scanned, even if they contain syntactically valid
  request-format JSON. This defends against injection via PR diff content or
  documentation that happens to contain request-syntax literals.
- Request blocks must be fenced JSON (`\`\`\`json ... \`\`\``) matching the schema above.
- Malformed JSON inside a fenced block is silently skipped (returns empty list, does
  not raise).

## Well-Formed Request Block Examples

Single file request:

```json
{
  "action": "read_files",
  "paths": ["src/mymodule/service.py"]
}
```

Multiple files request:

```json
{
  "action": "read_files",
  "paths": [
    "src/mymodule/service.py",
    "tests/unit/test_service.py"
  ]
}
```

## Schema Evolution

The `version` field enables future schema changes. Parsers should validate `version`
when present. Version 1 is the baseline — `version` defaults to `1` when omitted for
backward compatibility.
