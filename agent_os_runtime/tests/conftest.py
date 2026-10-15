"""Pytest fixtures for the deterministic kit suite (no network).

Spins the scripted stub UDS broker on a SHORT socket path (well under the macOS
AF_UNIX ~104-char limit) and wires the sandbox-injected environment contract, so
the kit's transport/retry/history behaviour is exercised exactly as it would be
in the container but with zero live model calls (Constitution IV).
"""

from __future__ import annotations

import json
import os
import tempfile
from collections.abc import Iterator

import pytest

from agent_os_runtime.tests import socket_guard, stub_broker


class BrokerHandle:
    """A running stub broker plus helpers to reconcile its request log."""

    def __init__(self, broker: stub_broker.Broker, sock: str, log: str) -> None:
        self._broker = broker
        self.sock = sock
        self.log = log

    def requests(self) -> list[dict]:
        """Return every logged broker request (one dict per discrete call)."""
        with open(self.log) as f:
            return [json.loads(line) for line in f if line.strip()]

    def request_count(self) -> int:
        """Number of discrete metered broker requests seen so far."""
        return len(self.requests())


def _start(mode: str) -> Iterator[BrokerHandle]:
    """Start a broker in ``mode`` on a short-path UDS and set the env contract."""
    # Short base dir keeps sun_path under the AF_UNIX limit (bake-off hit this).
    tmp = tempfile.mkdtemp(prefix="aosk", dir="/tmp")
    sock = os.path.join(tmp, "b.sock")
    log = os.path.join(tmp, "req.log")
    broker = stub_broker.start_in_thread(sock, log, mode)

    prev = {k: os.environ.get(k) for k in ("INFERENCE_SOCKET", "RUN_TOKEN", "AGENT_MODEL")}
    os.environ["INFERENCE_SOCKET"] = sock
    os.environ["RUN_TOKEN"] = "test-run-token"
    os.environ["AGENT_MODEL"] = "stub-model"

    try:
        yield BrokerHandle(broker, sock, log)
    finally:
        broker.stop()
        for k, v in prev.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        socket_guard.ATTEMPTS.clear()


@pytest.fixture
def broker() -> Iterator[BrokerHandle]:
    """Scripted broker running the normal 3-step golden task."""
    yield from _start("normal")


@pytest.fixture
def malformed_broker() -> Iterator[BrokerHandle]:
    """Broker that always returns invalid tool args (drives bounded retries)."""
    yield from _start("malformed")
