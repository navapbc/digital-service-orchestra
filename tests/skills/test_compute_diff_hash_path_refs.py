"""Structural tests for compute-diff-hash.sh path references in workflow docs.

Bug dcdc-8c7b: Orchestrators constructing CLAUDE_PLUGIN_ROOT as
$REPO_ROOT/plugins/dso get exit 127 in worktree sessions because the script
lives in the plugin cache (~/.claude/plugins/), not the repo tree.

These tests verify:
1. No workflow doc or SKILL.md contains a hardcoded $REPO_ROOT/plugins/dso
   path to compute-diff-hash.sh (the broken pattern from the bug).
2. REVIEW-WORKFLOW.md's CLAUDE_PLUGIN_ROOT fallback does NOT construct
   $REPO_ROOT/plugins/<name> directly — it must use the shim instead.
3. References to compute-diff-hash.sh in workflow docs use CLAUDE_PLUGIN_ROOT
   (resolved via shim or env var), not a raw repo-relative path.
"""

import pathlib
import re

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
REVIEW_WORKFLOW_MD = (
    REPO_ROOT / "plugins" / "dso" / "docs" / "workflows" / "REVIEW-WORKFLOW.md"
)

# All markdown files under plugins/dso that may contain compute-diff-hash refs
_SKILL_AND_WORKFLOW_DIRS = [
    REPO_ROOT / "plugins" / "dso" / "docs" / "workflows",
    REPO_ROOT / "plugins" / "dso" / "skills",
    REPO_ROOT / "plugins" / "dso" / "agents",
]


def _all_md_files() -> list[pathlib.Path]:
    """Return all .md files in skill and workflow dirs."""
    files = []
    for d in _SKILL_AND_WORKFLOW_DIRS:
        files.extend(d.rglob("*.md"))
    return files


# Pattern that represents the broken construct: a path to compute-diff-hash.sh
# built directly from $REPO_ROOT/plugins/<something>/ (not via the shim or
# CLAUDE_PLUGIN_ROOT set from the shim).
_BROKEN_REPO_ROOT_PATTERN = re.compile(
    r"\$REPO_ROOT/plugins/[^/]+/(?:scripts|hooks)/compute-diff-hash\.sh"
    r"|\$\{REPO_ROOT\}/plugins/[^/]+/(?:scripts|hooks)/compute-diff-hash\.sh"
    r"|\$ORCHESTRATOR_ROOT/plugins/[^/]+/(?:scripts|hooks)/compute-diff-hash\.sh"
    r"|\$\{ORCHESTRATOR_ROOT\}/plugins/[^/]+/(?:scripts|hooks)/compute-diff-hash\.sh"
)

# Pattern for the broken fallback in REVIEW-WORKFLOW.md: setting CLAUDE_PLUGIN_ROOT
# to $REPO_ROOT/plugins/<name> without going through the shim.
_BROKEN_FALLBACK_PATTERN = re.compile(
    r'CLAUDE_PLUGIN_ROOT=["\'"]?\$(?:REPO_ROOT|{REPO_ROOT})/plugins/[^"\'"\s]+'
)


def test_no_skill_or_workflow_doc_hardcodes_repo_root_compute_diff_hash_path() -> None:
    """No SKILL.md or workflow doc may reference compute-diff-hash.sh via $REPO_ROOT/plugins/."""
    violations = []
    for md_file in _all_md_files():
        content = md_file.read_text()
        if _BROKEN_REPO_ROOT_PATTERN.search(content):
            violations.append(str(md_file.relative_to(REPO_ROOT)))

    assert not violations, (
        "The following files contain hardcoded $REPO_ROOT/plugins/.../compute-diff-hash.sh "
        "paths that break in worktree sessions (plugin lives in cache, not repo tree).\n"
        "Use the shim: $REPO_ROOT/.claude/scripts/dso compute-diff-hash.sh\n"
        f"Files: {violations}"
    )


def test_review_workflow_fallback_does_not_construct_repo_root_plugin_path() -> None:
    """REVIEW-WORKFLOW.md CLAUDE_PLUGIN_ROOT fallback must not build $REPO_ROOT/plugins/<name>.

    The broken pattern sets CLAUDE_PLUGIN_ROOT by constructing a path from $REPO_ROOT,
    which fails in worktree sessions where plugins live in the cache. The fallback must
    instead use the shim to resolve DSO_ROOT.
    """
    content = REVIEW_WORKFLOW_MD.read_text()

    assert not _BROKEN_FALLBACK_PATTERN.search(content), (
        "REVIEW-WORKFLOW.md contains a CLAUDE_PLUGIN_ROOT fallback that constructs "
        "$REPO_ROOT/plugins/<name> directly. This breaks in worktree sessions where "
        "the plugin lives in ~/.claude/plugins/ cache, not the repo tree.\n"
        "Replace with shim-based resolution:\n"
        '  CLAUDE_PLUGIN_ROOT="$(. "$REPO_ROOT/.claude/scripts/dso" --lib && echo "$DSO_ROOT")"'
    )


def test_review_workflow_fallback_uses_shim() -> None:
    """REVIEW-WORKFLOW.md CLAUDE_PLUGIN_ROOT fallback must reference the dso shim."""
    content = REVIEW_WORKFLOW_MD.read_text()

    # The fallback block should source the shim in --lib mode to get DSO_ROOT
    has_shim_lib = re.search(
        r"\.claude/scripts/dso.*--lib|--lib.*\.claude/scripts/dso",
        content,
    )
    # Alternative: shim referenced as the resolver for CLAUDE_PLUGIN_ROOT
    has_shim_resolver = re.search(
        r"CLAUDE_PLUGIN_ROOT.*\.claude/scripts/dso|\.claude/scripts/dso.*DSO_ROOT",
        content,
    )

    assert has_shim_lib or has_shim_resolver, (
        "REVIEW-WORKFLOW.md does not use the dso shim to resolve CLAUDE_PLUGIN_ROOT "
        "in its fallback block. The fallback must invoke the shim (e.g., via --lib mode) "
        "so it works in both plugin-cache installs and in-repo dev setups.\n"
        "Expected pattern like:\n"
        '  CLAUDE_PLUGIN_ROOT="$(. "$REPO_ROOT/.claude/scripts/dso" --lib && echo "$DSO_ROOT")"'
    )
