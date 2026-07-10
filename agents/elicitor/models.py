from typing import List, Literal, Optional
from pydantic import BaseModel, Field

class TriggerModel(BaseModel):
    type: Literal["startup", "time", "event", "message"] = Field(
        description="When the agent runs: 'startup' (on load), 'time' (schedule), 'event' (named event), 'message' (incoming message)"
    )
    at: Optional[str] = Field(
        default=None,
        description="For 'time' triggers only: the UTC time of day, e.g. '07:00'"
    )
    name: Optional[str] = Field(
        default=None,
        description="For 'event' triggers only: the event name, e.g. 'approval_received'"
    )

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
    # Default matches the documented placeholder (the OS UI collects the real
    # value); 0.0 would project to an inert cap-0 manifest if it ever leaked.
    dollar_cap: float = Field(
        default=0.1,
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
    triggers: List[TriggerModel] = Field(
        default_factory=list,
        description="When the agent should run, derived from the stated purpose (e.g. 'upon loading' -> startup)"
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
