"""``run_agent()`` — the session-shaped invocation wrapper.

Wraps the existing PortRunner stdin/stdout contract: one JSON payload line in
(task input plus optional prior ``history``), one outcome-record line out (run
result plus the run's new-message delta). Every failure path — incomplete
environment, unreachable broker with retries exhausted, malformed history,
output-validation/tool retry exhaustion — is caught and surfaced as a structured
failure outcome. The kit never hangs, never retries unboundedly, and never exits
without emitting an outcome record (FR-009).
"""

from __future__ import annotations

import sys
from collections.abc import Callable
from typing import IO, Any

from pydantic import ValidationError
from pydantic_ai.messages import ModelMessagesTypeAdapter

from agent_os_runtime.schema import InvocationPayload, OutcomeRecord

# Bounded, visible retry budget (bake-off default). A kit-level constant, not
# per-agent config; every retry is a discrete metered broker request (FR-007).
DEFAULT_RETRIES = 2


class HistoryError(RuntimeError):
    """Raised when the ``history`` payload is malformed — fail fast, no drop."""


def _emit(record: OutcomeRecord, out: IO[str]) -> None:
    """Write exactly one outcome-record JSON line to stdout."""
    out.write(record.model_dump_json() + "\n")
    out.flush()


def _load_history(raw: list[dict[str, Any]] | None) -> Any | None:
    """Validate prior messages into pydantic-ai's message-history type.

    Malformed history raises ``HistoryError`` rather than silently dropping it.
    """
    if raw is None:
        return None
    try:
        return ModelMessagesTypeAdapter.validate_python(raw)
    except ValidationError as exc:
        raise HistoryError(f"malformed history payload: {exc}") from exc


def _dump_delta(messages: list[Any]) -> list[dict[str, Any]]:
    """Serialise this run's new messages to JSON-safe dicts (the history delta)."""
    return ModelMessagesTypeAdapter.dump_python(messages, mode="json")


def run_agent(
    build_agent: Callable[[], Any],
    *,
    payload_stream: IO[str] | None = None,
    out: IO[str] | None = None,
) -> None:
    """Drive one invocation of a kit-based agent over the port boundary.

    ``build_agent`` is a zero-arg callable that constructs the ``pydantic_ai.Agent``
    (typically ``Agent(substrate_model(), ...)`` plus its tools). It is invoked
    INSIDE the try/except so an incomplete environment contract surfaced by
    ``substrate_model()`` becomes a structured failure outcome rather than an
    uncaught traceback with no outcome record (FR-009 / US1-3).

    Reads one payload line, threads any prior ``history`` into the model, runs
    the agent once, and emits an outcome record carrying the new-message delta.
    """
    payload_stream = payload_stream or sys.stdin
    out = out or sys.stdout

    # Parse the single stdin line first; a broken payload is itself a failure
    # outcome (never a crash without a record).
    try:
        line = payload_stream.readline()
        payload = (
            InvocationPayload.model_validate_json(line)
            if line.strip()
            else InvocationPayload()
        )
    except (ValidationError, ValueError) as exc:
        _emit(OutcomeRecord(outcome="failed", reason=f"malformed invocation payload: {exc}"), out)
        return

    try:
        history = _load_history(payload.history)
    except HistoryError as exc:
        _emit(OutcomeRecord(outcome="failed", reason=str(exc)), out)
        return

    prompt = payload.task or "Proceed with your task."

    try:
        agent = build_agent()
        result = agent.run_sync(prompt, message_history=history)
    except Exception as exc:  # noqa: BLE001 — kit boundary: any failure -> structured outcome
        # Covers env/config errors (substrate_model fail-fast), broker-unreachable
        # after bounded retries, and tool/output-validation retry exhaustion.
        _emit(OutcomeRecord(outcome="failed", reason=f"{type(exc).__name__}: {exc}"), out)
        return

    output = result.output
    reason = output.model_dump_json() if hasattr(output, "model_dump_json") else str(output)
    _emit(
        OutcomeRecord(outcome="completed", reason=reason, history=_dump_delta(result.new_messages())),
        out,
    )
