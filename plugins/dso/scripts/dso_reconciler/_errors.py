"""Domain exceptions for dso_reconciler."""

class DirectionMismatchError(Exception):
    """Raised when a Mutation's direction doesn't match its dispatch context."""
    def __init__(self, message: str) -> None:
        super().__init__(message)

class UnknownActionError(Exception):
    """Raised when an unmapped MutationAction reaches the applier dispatch table."""
    def __init__(self, message: str) -> None:
        super().__init__(message)

class StatusMappingError(Exception):
    """Raised when Jira <-> local status mapping cannot be resolved."""
    def __init__(self, message: str) -> None:
        super().__init__(message)
