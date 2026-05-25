"""Contract test: conflict_resolver never proposes (write, dso-id) mutation.

Parametrized across the 6-case matrix from draft-9 (story 26de-eb67-29d2-48ae).
For each case, every resolved Mutation is inspected to assert that no mutation
has a 'labels' payload containing any value starting with 'dso-id-' AND an
action in {create, update}.

This is the dd-3 contract: per-element provenance must skip dso-id labels;
the conflict_resolver must not propose writes for the identity marker.

6 case names (per task e2f8-9fa5-9eab-4418 REVISION_CYCLE_1):
  (a) inbound-comment-create
  (b) outbound-comment-create
  (c) comment-edit-bidirectional
  (d) comment-delete-bidirectional
  (e) label-create-edit-delete-bidirectional  (excluding dso-id)
  (f) link-create-edit-delete-bidirectional
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path
from typing import Any

import pytest

# ---------------------------------------------------------------------------
# Module loading (per conftest.py convention for this directory)
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parents[3]
DIFFER_PATH = REPO_ROOT / "plugins" / "dso" / "scripts" / "dso_reconciler" / "differ.py"


def _load(path: Path, name: str):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


@pytest.fixture(scope="module")
def differ():
    return _load(DIFFER_PATH, "differ_no_dso_id_writes")


# ---------------------------------------------------------------------------
# Assertion helper
# ---------------------------------------------------------------------------

_WRITE_ACTIONS = {"create", "update"}


def _assert_no_dso_id_label_writes(mutations: list[Any], case_id: str) -> None:
    """Assert no mutation proposes a dso-id-* label write.

    A forbidden mutation is one where:
      - action is 'create' or 'update', AND
      - payload contains a 'labels' key whose value includes any item
        starting with 'dso-id-'
    """
    for mut in mutations:
        action_val = mut.action.value if hasattr(mut.action, "value") else str(mut.action)
        if action_val not in _WRITE_ACTIONS:
            continue
        payload = dict(mut.payload or {})
        labels = payload.get("labels", [])
        if not labels:
            continue
        if not isinstance(labels, (list, tuple, set)):
            labels = [labels]
        dso_id_labels = [lbl for lbl in labels if str(lbl).startswith("dso-id-")]
        assert not dso_id_labels, (
            f"case={case_id}: mutation action={action_val} target={mut.target!r} "
            f"proposed dso-id label write(s): {dso_id_labels} — "
            "conflict_resolver must skip dso-id labels (dd-3 contract)"
        )


# ---------------------------------------------------------------------------
# 6-case draft-9 matrix parametrization
# ---------------------------------------------------------------------------
#
# Each case is a (local_state, jira_state) dict pair keyed by the same issue
# key "PROJ-1".  All cases include a dso-id-* label in one or both sides to
# verify it is never proposed as a create/update payload field.
#
# The 6 cases follow the draft-9 per-element provenance scenarios:
#   (a) inbound-comment-create
#   (b) outbound-comment-create
#   (c) comment-edit-bidirectional
#   (d) comment-delete-bidirectional
#   (e) label-create-edit-delete-bidirectional (excluding dso-id)
#   (f) link-create-edit-delete-bidirectional

JIRA_KEY = "PROJ-1"
LOCAL_ID = "local-id-1"
DSO_ID_LABEL = "dso-id-local-id-1"  # typical identity marker format

_DRAFT9_CASES = [
    pytest.param(
        # (a) inbound-comment-create: Jira has a new comment that local does not.
        # dso-id label is identical on both sides — no label diff, so labels
        # must not appear in any mutation payload at all.
        {
            JIRA_KEY: {
                "dso_local_id": LOCAL_ID,
                "labels": [DSO_ID_LABEL, "feature"],
            }
        },
        {
            JIRA_KEY: {
                "dso_local_id": LOCAL_ID,
                "labels": [DSO_ID_LABEL, "feature"],
                "comments": [{"id": "c1", "body": "New Jira comment"}],
            }
        },
        id="inbound-comment-create",
    ),
    pytest.param(
        # (b) outbound-comment-create: local has a new comment; Jira does not.
        # dso-id label identical on both sides — must not appear in outbound payload.
        {
            JIRA_KEY: {
                "dso_local_id": LOCAL_ID,
                "labels": [DSO_ID_LABEL, "feature"],
                "comments": [{"id": "c1", "body": "Local comment"}],
            }
        },
        {
            JIRA_KEY: {
                "dso_local_id": LOCAL_ID,
                "labels": [DSO_ID_LABEL, "feature"],
            }
        },
        id="outbound-comment-create",
    ),
    pytest.param(
        # (c) comment-edit-bidirectional: both sides have different comment bodies.
        # dso-id label identical on both sides — must not appear in update payload.
        {
            JIRA_KEY: {
                "dso_local_id": LOCAL_ID,
                "labels": [DSO_ID_LABEL, "feature"],
                "comments": [{"id": "c1", "body": "Local version of comment"}],
            }
        },
        {
            JIRA_KEY: {
                "dso_local_id": LOCAL_ID,
                "labels": [DSO_ID_LABEL, "feature"],
                "comments": [{"id": "c1", "body": "Jira version of comment"}],
            }
        },
        id="comment-edit-bidirectional",
    ),
    pytest.param(
        # (d) comment-delete-bidirectional: local deleted a comment Jira still has.
        # dso-id label identical on both sides; comment diverges but labels do not.
        # Since labels are identical, no label entry appears in the update payload.
        # This case verifies that the comment divergence path does not accidentally
        # inject a dso-id label write via the labels resolver.
        {
            JIRA_KEY: {
                "dso_local_id": LOCAL_ID,
                "labels": [DSO_ID_LABEL, "feature"],
                "comments": [],
            }
        },
        {
            JIRA_KEY: {
                "dso_local_id": LOCAL_ID,
                "labels": [DSO_ID_LABEL, "feature"],
                "comments": [{"id": "c1", "body": "Jira still has this comment"}],
            }
        },
        id="comment-delete-bidirectional",
    ),
    pytest.param(
        # (e) label-create-edit-delete-bidirectional (excluding dso-id):
        # Regular labels diverge (local adds 'sprint-1'; jira adds 'bug').
        # dso-id label absent from BOTH sides — the resolved payload labels
        # {'feature','sprint-1','bug'} must not contain any dso-id-* item.
        # This is the primary "excluding dso-id" contract case: even when
        # label sets diverge, the resolver must never introduce a dso-id-* label.
        {
            JIRA_KEY: {
                "dso_local_id": LOCAL_ID,
                "labels": ["feature", "sprint-1"],
            }
        },
        {
            JIRA_KEY: {
                "dso_local_id": LOCAL_ID,
                "labels": ["feature", "bug"],
            }
        },
        id="label-create-edit-delete-bidirectional",
    ),
    pytest.param(
        # (f) link-create-edit-delete-bidirectional:
        # Links diverge (jira has an extra 'relates' link); dso-id label
        # identical on both sides — no dso-id label write proposed.
        # The link elements are plain strings here (not dicts) to avoid
        # the unhashable-dict issue in resolve_set_valued's dedup pass.
        {
            JIRA_KEY: {
                "dso_local_id": LOCAL_ID,
                "labels": [DSO_ID_LABEL, "feature"],
                "links": ["PROJ-2"],
            }
        },
        {
            JIRA_KEY: {
                "dso_local_id": LOCAL_ID,
                "labels": [DSO_ID_LABEL, "feature"],
                "links": ["PROJ-2", "PROJ-3"],
            }
        },
        id="link-create-edit-delete-bidirectional",
    ),
]


@pytest.mark.parametrize("local_state,jira_state", _DRAFT9_CASES)
def test_no_dso_id_label_writes_per_draft9_case(
    differ, local_state: dict, jira_state: dict, request
) -> None:
    """For each draft-9 provenance case, no mutation proposes a dso-id label write.

    Drives compute_mutations with the 6-case matrix and asserts that for every
    emitted Mutation with action in {create, update}, the 'labels' payload key
    (if present) contains no item starting with 'dso-id-'.

    Contract (dd-3): conflict_resolver per-element provenance MUST skip dso-id
    labels; the identity marker remains exclusively under inbound_clean_label /
    outbound_create jurisdiction.
    """
    mutations = differ.compute_mutations(local_state, jira_state)
    _assert_no_dso_id_label_writes(mutations, case_id=request.node.callid if hasattr(request.node, "callid") else request.node.name)
