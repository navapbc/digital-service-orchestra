"""
plugins/dso/scripts/ticket-llm-format.py
Shared LLM formatting logic for ticket-show.sh and ticket-list.sh.

Provides to_llm(state) which converts a full ticket state dict to a
minified dict with shortened keys, stripped nulls/empty lists, and no
verbose timestamps.

Key mapping:
  ticket_id   → id
  ticket_type → t
  title       → ttl
  status      → st
  author      → au
  parent_id   → pid
  priority    → pr
  assignee    → asn
  description → desc
  comments    → cm  (sub-keys: body→b, author→au; timestamp omitted)
  deps        → dp  (sub-keys: target_id→tid, relation→r; link_uuid omitted)
  conflicts   → cf
"""

KEY_MAP = {
    "ticket_id": "id",
    "ticket_type": "t",
    "title": "ttl",
    "status": "st",
    "author": "au",
    "parent_id": "pid",
    "priority": "pr",
    "assignee": "asn",
    "description": "desc",
    "comments": "cm",
    "deps": "dp",
    "conflicts": "cf",
}

# Fields omitted from LLM format (verbose timestamps / system metadata)
OMIT_KEYS = {"created_at", "env_id"}

# Comment: keep only body and author (omit timestamp — not useful for LLM)
COMMENT_KEY_MAP = {
    "body": "b",
    "author": "au",
}
COMMENT_OMIT = {"timestamp"}

DEP_KEY_MAP = {
    "target_id": "tid",
    "relation": "r",
}
DEP_OMIT = {"link_uuid"}


def shorten_comment(c):
    if not isinstance(c, dict):
        return c
    out = {}
    for k, v in c.items():
        if k in COMMENT_OMIT or v is None:
            continue
        out[COMMENT_KEY_MAP.get(k, k)] = v
    return out


def shorten_dep(d):
    if not isinstance(d, dict):
        return d
    out = {}
    for k, v in d.items():
        if k in DEP_OMIT or v is None:
            continue
        out[DEP_KEY_MAP.get(k, k)] = v
    return out


def to_llm(state):
    """Convert a full ticket state dict to LLM-optimised format."""
    out = {}
    for k, v in state.items():
        if k in OMIT_KEYS:
            continue
        if v is None:
            continue
        if isinstance(v, list) and len(v) == 0:
            continue
        short_k = KEY_MAP.get(k, k)
        if k == "comments":
            v = [shorten_comment(c) for c in v]
        elif k == "deps":
            v = [shorten_dep(d) for d in v]
        out[short_k] = v
    return out
