"""Pydantic model for the deterministic fixture's terminal outcome record."""

from pydantic import BaseModel


class Outcome(BaseModel):
    """The single-line JSON record the deterministic body prints on completion."""

    outcome: str
    reason: str
