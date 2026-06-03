# Synthetic migration-sweep fixture — orders module
#
# Contains call sites of `legacy_call` that migration-class-detect.sh
# will find when scanning for the target symbol across the fixture.

from .legacy_helpers import legacy_call


def place_order(user_id: int, items: list) -> dict:
    """Place a new order via the legacy data layer."""
    return legacy_call("place_order", {"user_id": user_id, "items": items})


def cancel_order(order_id: int) -> None:
    """Cancel an existing order via the legacy data layer."""
    legacy_call("cancel_order", {"order_id": order_id})
