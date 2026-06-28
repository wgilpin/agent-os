from pydantic import BaseModel, Field

class BookmarkItem(BaseModel):
    id: str = Field(..., max_length=256)
    author: str = Field(..., max_length=256)
    text: str = Field(..., max_length=10000)
    urls: list[str] = Field(default_factory=list)

class RosterState(BaseModel):
    records: list[dict] = Field(default_factory=list)

class DiscoveryInput(BaseModel):
    state: RosterState
    items: list[BookmarkItem] = Field(default_factory=list)
