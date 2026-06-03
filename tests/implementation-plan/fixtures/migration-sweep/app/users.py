# Synthetic migration-sweep fixture — users module
#
# Contains call sites of `legacy_call` that migration-class-detect.sh
# will find when scanning for the target symbol across the fixture.

from .legacy_helpers import legacy_call


def create_user(name: str, email: str) -> dict:
    """Create a new user record via the legacy data layer."""
    result = legacy_call("create_user", {"name": name, "email": email})
    return result


def fetch_user(user_id: int) -> dict:
    """Retrieve a user record via the legacy data layer."""
    return legacy_call("fetch_user", {"id": user_id})


def deactivate_user(user_id: int) -> None:
    """Deactivate a user account via the legacy data layer.

    NOTE: This call is the one site intentionally preserved in the sweep
    simulation so that completeness re-queries can detect it was missed.
    """
    legacy_call("deactivate_user", {"id": user_id})  # OMITTED-SITE
