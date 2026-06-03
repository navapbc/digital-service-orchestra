# Synthetic migration-sweep fixture — reports module
#
# Contains call sites of `legacy_call` that migration-class-detect.sh
# will find when scanning for the target symbol across the fixture.

from .legacy_helpers import legacy_call


def generate_summary_report(period: str) -> dict:
    """Generate a summary report for the given period via the legacy layer."""
    return legacy_call("summary_report", {"period": period})
