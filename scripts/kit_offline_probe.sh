#!/usr/bin/env bash
# Feature 046 / FR-013 / SC-004 — in-image offline containment probe.
#
# Proves the baked runtime kit runs the golden multi-step task under `--network=none`
# with zero egress and no lazy asset downloads (tiktoken never fetches). Extends the
# spec-044 containment posture: the body reaches its broker ONLY via a UDS on a shared
# volume (the 045 topology), never the network.
#
# Two containers in the same runtime VM (same kernel): a baked stub broker on a shared
# volume, and the sample body run with NO network. Success = the body prints
# outcome "completed" and the broker logged exactly 3 discrete requests.
#
# Usage: scripts/kit_offline_probe.sh [image]   (default image: agent-generated:dev)
# Exit 0 on success; non-zero (with a diagnostic) on any failure.
set -euo pipefail

IMAGE="${1:-agent-generated:dev}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BODYDIR="$REPO_ROOT/agents/sample_kit_agent"
VOL="aos_kit_probe_$$"
BROKER="aos_kit_probe_broker_$$"

cleanup() {
  docker rm -f "$BROKER" >/dev/null 2>&1 || true
  docker volume rm "$VOL" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker volume create "$VOL" >/dev/null
# Make the shared-volume dir writable by the non-root app user (uid 1000).
docker run --rm --user 0 -v "$VOL":/run/probe "$IMAGE" /bin/sh -c "chmod 0777 /run/probe"

# Baked stub broker on the shared volume (no network needed to bind AF_UNIX).
docker run -d --name "$BROKER" --network=none -v "$VOL":/run/probe \
  --entrypoint /app/.venv/bin/python "$IMAGE" \
  /app/agent_os_runtime/tests/stub_broker.py /run/probe/b.sock /run/probe/req.log normal >/dev/null

# Wait for the broker readiness marker.
ready=""
for _ in $(seq 1 50); do
  if docker exec "$BROKER" /bin/sh -c "test -f /run/probe/b.sock.ready" 2>/dev/null; then
    ready="yes"; break
  fi
  sleep 0.1
done
[ -n "$ready" ] || { echo "PROBE_FAIL: stub broker never became ready"; exit 1; }

# Sample body under --network=none: only the shared volume + read-only body mounted.
OUT="$(echo '{"task":"Prepare my quarterly review."}' | docker run -i --rm --network=none \
  -v "$VOL":/run/probe \
  -v "$BODYDIR":/app/agents/sample_kit_agent:ro \
  -e INFERENCE_SOCKET=/run/probe/b.sock \
  -e RUN_TOKEN=probe-token \
  -e AGENT_MODEL=stub-model \
  --entrypoint /app/.venv/bin/python "$IMAGE" \
  /app/agents/sample_kit_agent/main.py)"

REQS="$(docker exec "$BROKER" /bin/sh -c 'wc -l < /run/probe/req.log' 2>/dev/null | tr -d ' ')"

echo "PROBE_STDOUT=$OUT"
echo "PROBE_BROKER_REQUESTS=$REQS"

echo "$OUT" | grep -q '"outcome":"completed"' || { echo "PROBE_FAIL: body did not complete the golden task"; exit 1; }
[ "$REQS" = "3" ] || { echo "PROBE_FAIL: expected 3 broker requests, got $REQS"; exit 1; }

echo "PROBE_OK: golden task completed offline (network=none), 3 metered calls, zero egress possible"
