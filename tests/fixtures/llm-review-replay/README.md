# LLM Review Replay Fixtures

These fixtures capture LLM-response shapes that the CI llm-review pipeline must
handle gracefully. Each file is a raw byte stream that mirrors what came back
from `litellm.completion(...).choices[0].message.content` in a real CI failure
(or a hypothetical worst-case).

## Files

- **`non-json-275.txt`** — the 275-byte non-JSON response that caused PR #442
  run 26614385353 to fail with `ERROR: LLM returned non-JSON response`. Used by
  R3 tests to verify the preview is logged and by R2 tests to verify the
  fallback chain iterates instead of exhausting.

- **`markdown-fenced.txt`** — valid findings JSON wrapped in a Markdown code
  fence (\`\`\`json … \`\`\`). The legacy `providers/anthropic.py` adapter
  fails on this shape because it calls `json.loads` directly. Used by R5
  tests to verify the rescue path (`_extract_json_from_text`) recovers.

- **`friendly-preamble.txt`** — valid findings JSON preceded by a friendly
  preamble ("Here is the review JSON: …"). The bare `json.loads` fails;
  `_extract_json_from_text` scans for the first `{` and recovers. Used by R5
  and R6 tests.

- **`refusal.txt`** — a safety-refusal response with no JSON at all. No rescue
  is possible — must surface as a real parse failure. Used by R3 tests to
  verify the preview path is hit and by R2 tests to verify the fallback chain
  iterates.

## Bug

The original incident is tracked as bug ticket `f148-2cb6-8b7e-4cdd`
(`[ci-llm-review]: LLM returns non-JSON + Reviews API 422 → stale prior-cycle
findings surfaced as blocking`).
