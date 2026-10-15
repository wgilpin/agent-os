"""``substrate_model()`` — the broker-connected framework model.

Wraps the proven bake-off transport shape (SCORECARD.md): a pydantic-ai
``OpenAIChatModel`` whose ``OpenAIProvider`` talks OpenAI chat-completions JSON
over the mounted Unix domain socket via a custom httpx transport. The per-run
token is passed as the provider ``api_key`` so the OpenAI client sends it as
``Authorization: Bearer <run_token>`` — exactly the header the broker's
compatibility surface authenticates on (no kit-side request rewriting).

Connection details come ONLY from the sandbox-injected environment contract
(``INFERENCE_SOCKET``, ``RUN_TOKEN``, ``AGENT_MODEL``); the agent body never
reads these itself.
"""

from __future__ import annotations

import os

import httpx
from pydantic_ai.models.openai import OpenAIChatModel
from pydantic_ai.providers.openai import OpenAIProvider

# macOS AF_UNIX sun_path is ~104 bytes; surface an over-limit path as a clear
# kit error rather than an opaque OS bind/connect failure (spec Edge Cases).
_SUN_PATH_LIMIT = 100


class RuntimeConfigError(RuntimeError):
    """Raised when the environment contract is incomplete or invalid.

    ``run_agent`` catches this and emits a structured failure outcome — the kit
    never attempts a call with a broken contract (FR-009).
    """


def _require_env(name: str) -> str:
    """Return a non-empty environment variable or fail fast (loud failure)."""
    value = os.environ.get(name)
    if not value:
        raise RuntimeConfigError(
            f"required environment variable {name!r} is missing or empty"
        )
    return value


def substrate_model() -> OpenAIChatModel:
    """Build the broker-connected model from the environment contract.

    Reads ``INFERENCE_SOCKET``/``RUN_TOKEN``/``AGENT_MODEL``, points an httpx
    UDS transport at the broker, and returns an ``OpenAIChatModel`` the body
    hands to ``pydantic_ai.Agent``. Fails fast on a missing/empty variable or an
    over-length socket path.
    """
    socket_path = _require_env("INFERENCE_SOCKET")
    run_token = _require_env("RUN_TOKEN")
    agent_model = _require_env("AGENT_MODEL")

    if len(socket_path) > _SUN_PATH_LIMIT:
        raise RuntimeConfigError(
            f"INFERENCE_SOCKET path is {len(socket_path)} chars, over the "
            f"~{_SUN_PATH_LIMIT}-char AF_UNIX limit: {socket_path!r}"
        )

    # First-class UDS transport: the OpenAI provider speaks to the broker over
    # the mounted socket. base_url is a placeholder host — routing is the socket.
    uds_client = httpx.AsyncClient(
        transport=httpx.AsyncHTTPTransport(uds=socket_path),
        base_url="http://localhost/v1",
        timeout=30.0,
    )
    provider = OpenAIProvider(
        base_url="http://localhost/v1",
        api_key=run_token,  # -> Authorization: Bearer <run_token>
        http_client=uds_client,
    )
    return OpenAIChatModel(agent_model, provider=provider)
