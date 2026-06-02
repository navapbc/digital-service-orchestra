#!/usr/bin/env python3
"""Detect a real `gh pr merge ... --admin` INVOCATION in a shell command.

Reads the command from stdin. Exit 0 = the command actually invokes
`gh pr merge` with `--admin` (the force-merge guard must BLOCK it). Exit 1 =
the literal is only a MENTION — inside a quoted argument, a commit message, a
grep pattern, a heredoc body — and must be ALLOWED.

Why structural, not textual. The literal `gh pr merge --admin` can appear two
ways. As a *mention* it is fused inside a single quoted shell token (a commit
message, a grep pattern, an echo string) — shell unquoting leaves it as ONE
token whose value has embedded spaces. As an *invocation* the words are
separate tokens at a command position, produced by splitting on unquoted
whitespace. We therefore tokenize with shlex (correct shell unquoting) rather
than stripping text, then look for `gh`, `pr`, `merge` as three ADJACENT tokens
(matching the command basename, so `/usr/bin/gh` and `command gh` both resolve)
with `--admin` among the argument tokens before the next command terminator.

`punctuation_chars=True` makes shlex split unquoted `() {} ; & | < >` into their
own tokens, so the scan finds an invocation regardless of the surrounding
construct: `command gh ...`, `/usr/bin/gh ...`, `env gh ...`, a wrapper
(`timeout 60 gh ...`), a subshell `(gh ...)`, a brace group `{ gh ...; }`,
command substitution `$(gh ...)`, or backticks. `eval` / `bash -c` / `sh -c`
string payloads are recursed into. Quoted grouping characters stay inside their
token, so a quoted mention is never mis-split into command tokens.

Accepted edge: a BARE, UNQUOTED `echo gh pr merge --admin` (the words typed as
separate unquoted tokens after another command) is treated as an invocation and
blocked. This is contrived — real mentions are quoted (and therefore fused and
allowed) — and over-blocking a contrived mention is the safe direction for a
force-merge guard.

Fails CLOSED: any tokenizer error (unbalanced quotes), recursion-depth
exhaustion, or unexpected exception is treated as an invocation (exit 0) so a
parser failure can never produce a false negative on a genuine override.
"""

import os
import re
import shlex
import sys

ADMIN = "--admin"
_MAX_DEPTH = 5

# Heredoc body: <<[-]? optional-quote DELIM optional-quote ... newline DELIM.
# The delimiter run is any non-space, non-quote, non-backtick characters, so it
# matches EOF, MY-DELIM, DELIM.v1, etc. — not just [A-Za-z0-9_].
_HEREDOC = re.compile(r"""<<-?\s*(["']?)([^\s"'`]+)\1.*?\n[ \t]*\2\b""", re.S)

# Tokens that end a simple command — the `--admin` search stops here so a flag
# belonging to a *later* command (`gh pr merge 5 ; echo --admin`) is not counted.
_TERMINATORS = {";", "&", "|", "&&", "||", "(", ")", "{", "}", "<", ">", ";;", "\n"}


def _strip_heredoc_bodies(s: str) -> str:
    prev = None
    while prev != s:
        prev = s
        s = _HEREDOC.sub(" ", s, count=1)
    return s


# Backslash-newline line continuation: POSIX shells delete `\` + newline before
# word-splitting, so `gh pr merge 5 \<NL>--admin` runs as one command. shlex in
# POSIX mode does NOT collapse it, leaving a stray newline token that splits the
# invocation. Normalize it to a space (after heredoc stripping, which needs the
# real newlines) so a continued invocation is detected as one command.
_LINE_CONT = re.compile(r"\\\n[ \t]*")


def _tokenize(s: str) -> list:
    # Default punctuation_chars=True splits `();<>|&`; add backtick so unquoted
    # `\`gh ...\`` command substitution is split into command tokens too. A
    # backtick inside single/double quotes stays in its token (quoting is honored
    # before punctuation), so a quoted mention is never mis-split.
    lex = shlex.shlex(s, posix=True, punctuation_chars="();<>|&`")
    lex.whitespace_split = True
    return list(lex)


def _scan(tokens: list) -> bool:
    """True if `gh pr merge` appears as adjacent command tokens with --admin
    among its arguments before the next command terminator."""
    n = len(tokens)
    for i in range(n - 2):
        if (
            os.path.basename(tokens[i]) == "gh"
            and tokens[i + 1] == "pr"
            and tokens[i + 2] == "merge"
        ):
            j = i + 3
            while j < n and tokens[j] not in _TERMINATORS:
                if tokens[j] == ADMIN:
                    return True
                j += 1
    return False


def _has_admin_invocation(cmd: str, depth: int = 0) -> bool:
    if depth > _MAX_DEPTH:
        return True  # fail closed on unexpected nesting depth
    cmd = _strip_heredoc_bodies(cmd)
    cmd = _LINE_CONT.sub(" ", cmd)
    try:
        tokens = _tokenize(cmd)
    except ValueError:
        return True  # fail closed on unbalanced quotes
    if _scan(tokens):
        return True
    # Recurse into eval / bash -c / sh -c string payloads.
    n = len(tokens)
    for j in range(n):
        base = os.path.basename(tokens[j])
        if base == "eval":
            parts = []
            k = j + 1
            while k < n and tokens[k] not in _TERMINATORS:
                parts.append(tokens[k])
                k += 1
            if parts and _has_admin_invocation(" ".join(parts), depth + 1):
                return True
        elif base in ("bash", "sh", "zsh"):
            for k in range(j + 1, n - 1):
                if tokens[k] in _TERMINATORS:
                    break
                if tokens[k] == "-c":
                    if _has_admin_invocation(tokens[k + 1], depth + 1):
                        return True
                    break
    return False


def main() -> int:
    cmd = sys.stdin.read()
    try:
        return 0 if _has_admin_invocation(cmd) else 1
    except Exception:
        return 0  # fail closed


if __name__ == "__main__":
    sys.exit(main())
