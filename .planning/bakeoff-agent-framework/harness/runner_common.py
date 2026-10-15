"""Shared helpers for candidate runners: broker lifecycle + log reading."""
import json
import os
import subprocess
import sys
import time

HARNESS_DIR = os.path.dirname(os.path.abspath(__file__))
BROKER_PY = os.path.join(HARNESS_DIR, "broker.py")


def start_broker(sock_path, log_path, mode="normal"):
    """Launch broker.py as a subprocess and wait until its socket is ready."""
    ready = sock_path + ".ready"
    for p in (sock_path, ready):
        if os.path.exists(p):
            os.unlink(p)
    proc = subprocess.Popen(
        [sys.executable, BROKER_PY, sock_path, log_path, mode],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    for _ in range(200):
        if os.path.exists(ready):
            break
        if proc.poll() is not None:
            out, err = proc.communicate()
            raise RuntimeError(f"broker died: {err.decode()}")
        time.sleep(0.02)
    else:
        raise RuntimeError("broker did not become ready")
    return proc


def read_log(log_path):
    if not os.path.exists(log_path):
        return []
    with open(log_path) as f:
        return [json.loads(line) for line in f if line.strip()]
