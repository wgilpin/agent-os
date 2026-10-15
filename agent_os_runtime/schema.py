"""Typed in-flight data shapes crossing the port boundary for the runtime kit.

These are developer-experience / early-failure types only — never enforcement
(the gate and broker are the firewall). Pydantic models, no bare dicts
(Constitution V). The kit persists nothing; ``history`` is threaded in and the
run's new-message delta is threaded out (the substrate owns persistence).
"""

from __future__ import annotations

from typing import Any

from pydantic import BaseModel, ConfigDict, Field


class InvocationPayload(BaseModel):
    """One JSON line read from stdin: the task input plus optional prior history.

    Extra keys are tolerated because existing ``run_worker`` payloads carry
    ``roster``/``trigger_input`` shapes; a kit-based body reads only what it
    needs. ``history`` is an opaque-but-JSON list of prior conversation messages
    (pydantic-ai's native message serialisation); absent means a fresh run.
    """

    model_config = ConfigDict(extra="allow")

    task: str | None = None
    history: list[dict[str, Any]] | None = None
    trigger_input: Any | None = None


class OutcomeRecord(BaseModel):
    """One JSON line printed to stdout describing how the run ended.

    ``outcome``/``reason`` match ``AgentOS.OutcomeRecord`` (the Elixir parser
    requires those two strings and tolerates the extra ``history`` key). The
    ``history`` field carries the messages *new to this run* — the delta the
    substrate persists (Phase 14), never the full transcript.
    """

    outcome: str
    reason: str
    history: list[dict[str, Any]] = Field(default_factory=list)
