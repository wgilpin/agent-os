from typing import List, Optional
from pydantic import BaseModel, Field

class BoundaryModel(BaseModel):
    egress_domains: List[str] = Field(
        default_factory=list,
        description="Allowed outgoing domain hosts, e.g. ['api.github.com']"
    )
    target_locations: List[str] = Field(
        default_factory=list,
        description="Allowed storage paths or folders, e.g. ['data/inventory.term']"
    )

class SpendLimitsModel(BaseModel):
    dollar_cap: float = Field(
        default=0.0,
        description="Maximum dollar-denominated spend cap, e.g. 0.50"
    )
    token_limit: int = Field(
        default=0,
        description="Maximum total tokens allowed per execution run"
    )

class ElicitedSpecModel(BaseModel):
    purpose: str = Field(
        description="Concise description of the agent's goal"
    )
    capabilities: List[str] = Field(
        default_factory=list,
        description="Minimal set of connector capability grants"
    )
    boundaries: BoundaryModel = Field(
        default_factory=BoundaryModel
    )
    spend_limits: SpendLimitsModel = Field(
        default_factory=SpendLimitsModel
    )
    confirmed: bool = Field(
        default=False,
        description="Whether the user has explicitly confirmed the spec"
    )

class ElicitorResponse(BaseModel):
    spec_draft: ElicitedSpecModel
    next_question: str = Field(
        description="The next clarifying question to ask the user, or empty if KISS-clear and ready to confirm"
    )
    scope_creep_detected: bool = Field(
        default=False,
        description="Whether the user is trying to add unnecessary permissions"
    )
    pushback_message: str = Field(
        default="",
        description="Warning message to show the user if scope creep is detected, otherwise empty"
    )
