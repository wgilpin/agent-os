# Contract: Socket Topology & Substrate Entry Point

The interfaces this feature exposes: the two-mode socket-topology config contract (internal,
between config and the dispatch/broker/sandbox code) and the operator entry-point contract
(the compose command).

## 1. Mode-selection contract

```
inference_socket_volume == nil   ⇒ :host_bind    (every behaviour identical to pre-feature)
inference_socket_volume == "..." ⇒ :shared_volume
```

Every consumer (`run_worker.dispatch_spec/3`, `sandbox.build_argv/1`,
`inference_broker.start_uds_listener/1`, `test_helper.start_broker_uds!/1`) MUST derive the mode
from this single key and MUST NOT introduce a second, independently-settable switch.

## 2. Dispatch contract (`dispatch_spec/3`)

- **host_bind**: inference mount = `{Path.expand(uds_path), "/tmp/inference.sock"}`;
  `INFERENCE_SOCKET` env = `/tmp/inference.sock`. (unchanged)
- **shared_volume**: inference mount = `{volume_name, volume_path}`; `INFERENCE_SOCKET` env =
  the full configured `:inference_uds_path`. Generated-agent code mount (`{code_dir, ".../<name>:ro"}`)
  is unchanged in both modes (FR-010 / 044 FR-007 parity preserved).

## 3. Sandbox validation contract (`build_argv/1`)

- **host_bind**: for each mount, if container target == `/tmp/inference.sock` then host path MUST
  equal configured `uds_path`; else container target MUST end with `:ro`. (unchanged)
- **shared_volume**: exactly the writable mount whose container target == `volume_path` is
  allowed, and its host source MUST equal `volume_name`; every other mount MUST end with `:ro`.
- Violations raise `ArgumentError` with a diagnosable message (FR-005, FR-009).

## 4. Broker permission contract (`start_uds_listener/1`)

- **host_bind**: parent dir `0700`; socket `0660` + chgrp to `INFERENCE_GID`. (unchanged)
- **shared_volume**: parent dir `0770` + chgrp to `INFERENCE_GID`; socket `0660` + chgrp.
- On any chmod/chgrp/listen failure: log GID + reason and return `{:error, ...}` → the broker
  `init/1` stops with `{:uds_listener_failed, reason}` (loud, no host fallback; FR-009).

## 5. Group-access guarantee (SC-005)

Given `INFERENCE_GID` = G, an agent running `1000:G` CAN connect/read the socket; a process not
in group G CANNOT. Enforced by 0770 dir + 0660 socket, both group-owned by G.

## 6. Operator entry-point contract (amended — container is the only run mode)

- **Build**: `docker compose build substrate` produces the substrate image (shared by both
  services below).
- **Run the app (FR-012/FR-013, SC-006)**: `docker compose up substrate` starts the full app in
  the OrbStack VM (`MIX_ENV=dev`, `mix run --no-halt`) — scheduler, triggers, generation,
  elicitation, and the LiveView web UI bound `0.0.0.0:4000` and published to the host at
  `http://localhost:4000`. This is THE way to run the substrate; there is no host run mode.
- **Docker-tagged suite (FR-008, SC-002)**: `docker compose run --rm e2e` runs the docker-tagged
  suite with the substrate in-VM (`MIX_ENV=test`, `mix deps.get && mix test --only docker`). The
  `e2e` service shares the `substrate` image and volumes. Exit 0 ⇒ SC-002 met. Recorded in
  `quickstart.md` and referenced from the compose file.
- **Host app start (FR-011, SC-007)**: refused. `iex -S mix` / `mix run --no-halt` on the macOS
  host aborts application start with a loud message naming `docker compose up substrate`. The
  hermetic host test suite (autostart disabled) is unaffected.
- **Real run (SC-001)**: `docker compose up substrate` (dev) with a live `MODEL_KEY`/`.env` reaches
  the model — an operator step (needs a live key), not an automated test (Constitution IV).
- Failure modes (socket absent, permission denied, volume missing, daemon unreachable) surface as
  a loud non-zero exit with a diagnosable log line — never a silent host fallback (FR-009).
