"""Adversarial containment probe body (test fixture — NOT a real agent).

Each invocation runs exactly ONE escape attempt, selected by argv[1]. The body only
reaches the final ``print("ESCAPED", ...)`` / ``exit(0)`` if the sandbox FAILED to
contain the attempt. The expected outcome for every mode is an uncaught error and a
non-zero exit, i.e. the operation was denied.

Modes:
  read <host_path>  read a host path that is not among the container's mounts
  net               open an outbound network connection
  write             write outside the writable scratch area (into the read-only mount)
"""

import sys
import socket


def main() -> None:
    """Run the single escape attempt named by argv[1]; exit 0 only if it was NOT denied."""
    mode = sys.argv[1] if len(sys.argv) > 1 else "read"

    if mode == "read":
        # A host path that exists on the operator's machine but is not mounted into the
        # container. If the host filesystem were reachable this open() would succeed.
        with open(sys.argv[2], "r", encoding="utf-8") as handle:
            handle.read()
    elif mode == "net":
        # Network is `--network none`; any outbound connection must be refused.
        socket.create_connection(("8.8.8.8", 53), timeout=2)
    elif mode == "write":
        # The code directory is mounted read-only and the root fs is read-only; the only
        # writable surface is /scratch. Writing here must fail.
        with open("/app/agents/containment_probe/pwned", "w", encoding="utf-8") as handle:
            handle.write("pwned")

    # Reached only if the attempt was NOT denied — that is a containment failure.
    print("ESCAPED", mode)
    sys.exit(0)


if __name__ == "__main__":
    main()
