"""Shared golden-task agent builder for the kit suite.

Mirrors ``agents/sample_kit_agent/main.py`` so the deterministic Python tier
exercises the exact kit path the Elixir E2E runs across the port boundary,
without importing from the ``agents/`` (untrusted-body) tree.
"""

from __future__ import annotations

from pydantic import BaseModel
from pydantic_ai import Agent

from agent_os_runtime import substrate_model


class Result(BaseModel):
    """Structured outcome the golden task must produce to finish."""

    outcome: str
    reason: str


def build_agent() -> Agent[None, Result]:
    """Build the golden multi-step agent (search_notes -> add_todo -> Result)."""
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
