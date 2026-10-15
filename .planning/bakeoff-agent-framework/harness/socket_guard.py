"""Network jail: only AF_UNIX is permitted. Simulates the container's network=none.

install() monkeypatches socket.socket and socket.create_connection so any attempt
to open an AF_INET / AF_INET6 socket, or to create_connection() to a host:port,
raises immediately. AF_UNIX sockets (the UDS to the broker) are allowed.

Any raise is recorded in ATTEMPTS so the harness can report attempted egress.
"""
import socket as _socket

ATTEMPTS = []

_real_socket_cls = _socket.socket
_real_create_connection = _socket.create_connection


class BlockedEgress(RuntimeError):
    pass


class _GuardedSocket(_real_socket_cls):
    def __init__(self, family=_socket.AF_INET, type=_socket.SOCK_STREAM, *a, **kw):
        if family not in (_socket.AF_UNIX,):
            ATTEMPTS.append(("socket", int(family), int(type)))
            raise BlockedEgress(
                f"network egress blocked (family={family!r}); only AF_UNIX permitted"
            )
        super().__init__(family, type, *a, **kw)


def _guarded_create_connection(address, *a, **kw):
    ATTEMPTS.append(("create_connection", address))
    raise BlockedEgress(f"network egress blocked to {address!r}; only AF_UNIX permitted")


def install():
    _socket.socket = _GuardedSocket
    _socket.create_connection = _guarded_create_connection


def uninstall():
    _socket.socket = _real_socket_cls
    _socket.create_connection = _real_create_connection
