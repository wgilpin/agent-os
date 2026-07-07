from pydantic import BaseModel

class Outcome(BaseModel):
    outcome: str
    reason: str