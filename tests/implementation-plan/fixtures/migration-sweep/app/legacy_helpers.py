# Synthetic migration-sweep fixture — legacy_helpers module
#
# Defines the `legacy_call` function that is the migration-sweep target symbol.
# All other modules in this fixture import and call this function.
#
# This module deliberately does NOT call legacy_call on itself — a call to
# legacy_call within the defining module would be unusual and could confuse
# static analysis; the sweep target is outbound calls from other modules.


def legacy_call(operation: str, payload: dict | None = None) -> dict:
    """Stub implementation of the legacy RPC call.

    In the real codebase this would dispatch to a legacy service.  For the
    migration-sweep fixture it simply returns an empty dict so that the
    Python modules remain importable without any real dependency.

    Args:
        operation: The operation name to dispatch.
        payload:   Optional data payload (ignored by this stub).

    Returns:
        An empty dict (stub behaviour — deterministic, no side-effects).
    """
    _ = (operation, payload)  # suppress "unused variable" linters
    return {}
