from pydantic import BaseModel

class OutcomeRecord(BaseModel):
    outcome: str
    reason: str