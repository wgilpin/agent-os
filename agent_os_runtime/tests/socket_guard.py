"""Network jail: only AF_UNIX is permitted (simulates the container's network=none).

Seeded from ``.planning/bakeoff-agent-framework/harness/socket_guard.py`` — this
is part of the kit's deterministic regression suite (FR-012), the mandatory gate
for any framework pin bump.

``install()`` monkeypatches ``socket.socket`` and ``socket.create_connection`` so
any attempt to open an AF_INET/AF_INET6 socket, or ``create_connection`` to a
host:port, raises immediately; AF_UNIX (the broker UDS) is allowed. Every raise
is recorded in ``ATTEMPTS`` so a test can assert zero attempted egress.
"""

from __future__ import annotations

import socket as _socket

ATTEMPTS: list[tuple] = []

_real_socket_cls = _socket.socket
_real_create_connection = _socket.create_connection


class BlockedEgress(RuntimeError):
    """Raised when a body attempts non-AF_UNIX network egress."""


class _GuardedSocket(_real_socket_cls):  # type: ignore[misc,valid-type]
    """A socket that permits only AF_UNIX, recording and blocking anything else."""

    def __init__(self, family=_socket.AF_INET, type=_socket.SOCK_STREAM, *a, **kw):  # noqa: A002
        if family not in (_socket.AF_UNIX,):
            ATTEMPTS.append(("socket", int(family), int(type)))
            raise BlockedEgress(
                f"network egress blocked (family={family!r}); only AF_UNIX permitted"
            )
        super().__init__(family, type, *a, **kw)


def _guarded_create_connection(address, *a, **kw):
    """Block and record any create_connection (always a host:port egress)."""
    ATTEMPTS.append(("create_connection", address))
    raise BlockedEgress(f"network egress blocked to {address!r}; only AF_UNIX permitted")


def install() -> None:
    """Activate the AF_UNIX-only egress jail."""
    _socket.socket = _GuardedSocket  # type: ignore[misc]
    _socket.create_connection = _guarded_create_connection  # type: ignore[assignment]


def uninstall() -> None:
    """Restore the real socket constructors."""
    _socket.socket = _real_socket_cls  # type: ignore[misc]
    _socket.create_connection = _real_create_connection  # type: ignore[assignment]
