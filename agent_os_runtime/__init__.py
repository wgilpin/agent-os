"""agent_os_runtime — first-party runtime kit for generated agent bodies.

Baked into the generated-agent image (never generated). Gives an agent body
``substrate_model()`` (broker-connected model over the mounted UDS) and
``run_agent()`` (the session-shaped stdin/stdout invocation wrapper), so bodies
carry zero transport, HTTP, or environment-plumbing code. DX and early failure
only — the gate and broker remain the sole enforcement.
"""

from agent_os_runtime.invoke import run_agent
from agent_os_runtime.model import substrate_model

__all__ = ["substrate_model", "run_agent"]
