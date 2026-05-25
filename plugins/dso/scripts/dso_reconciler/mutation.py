"""Mutation manifest types for the dso_reconciler.

Defines the immutable Mutation value object and its enum vocabulary
(MutationDirection, MutationAction). Direction/action validity is enforced
by an explicit allowlist (`_VALID_COMBINATIONS`): clean_label and
repair_property are inbound-only — they have no outbound semantics.
"""

from collections.abc import Mapping
from dataclasses import dataclass
from enum import StrEnum
from typing import Any


class MutationDirection(StrEnum):
    inbound = "inbound"
    outbound = "outbound"


class MutationAction(StrEnum):
    create = "create"
    update = "update"
    delete = "delete"
    probe = "probe"
    clean_label = "clean_label"
    repair_property = "repair_property"
    conflict = "conflict"


# All (direction, action) pairs except outbound-with-inbound-only actions.
_INBOUND_ONLY_ACTIONS: frozenset[MutationAction] = frozenset(
    {MutationAction.clean_label, MutationAction.repair_property}
)

_VALID_COMBINATIONS: frozenset[tuple[MutationDirection, MutationAction]] = frozenset(
    (direction, action)
    for direction in MutationDirection
    for action in MutationAction
    if not (direction is MutationDirection.outbound and action in _INBOUND_ONLY_ACTIONS)
)


@dataclass(frozen=True, slots=True)
class Mutation:
    """An immutable description of a single reconciler-driven change."""

    direction: MutationDirection
    action: MutationAction
    target: str
    payload: Mapping[str, Any]
    provenance: Mapping[str, Any]

    def __post_init__(self) -> None:
        if not isinstance(self.target, str) or not self.target:
            raise ValueError("target must be a non-empty str")
        if not isinstance(self.payload, Mapping):
            raise TypeError("payload must be a Mapping")
        if not isinstance(self.provenance, Mapping):
            raise TypeError("provenance must be a Mapping")
        if (self.direction, self.action) not in _VALID_COMBINATIONS:
            raise ValueError(
                f"invalid (direction={self.direction.value}, "
                f"action={self.action.value}) combination"
            )

    def __hash__(self) -> int:
        # payload/provenance are Mapping (often dict, which is unhashable).
        # Identity of a Mutation for set/dict-key purposes is the
        # (direction, action, target) triple — payload/provenance are
        # descriptive metadata, not part of the identity.
        return hash((self.direction, self.action, self.target))
