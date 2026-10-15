"""Golden reference kit-based agent body: under 30 lines, zero transport/env code."""

from pydantic import BaseModel
from pydantic_ai import Agent

from agent_os_runtime import run_agent, substrate_model


class Result(BaseModel):
    """Structured outcome the model must produce to finish the run."""

    outcome: str
    reason: str


def build_agent() -> Agent[None, Result]:
    """Construct the golden multi-step agent; the kit owns all transport."""
    agent = Agent(
        substrate_model(),
        output_type=Result,
        retries=2,
        system_prompt="Search the user's notes, then add a todo, then report the outcome.",
    )

    @agent.tool_plain
    def search_notes(query: str) -> str:
        """Search the user's notes for a query string."""
        return "found 3 notes matching the query"

    @agent.tool_plain
    def add_todo(title: str, link: str) -> str:
        """Add a todo item with a title and a link."""
        return "todo added"

    return agent


if __name__ == "__main__":
    run_agent(build_agent)
