# Plan 01-02 Summary — Provisioner + Scheduler

**Status:** Complete. `mix test` 22/22 green (10 new tests added, zero compiler warnings).

## What was built

- **`AgentOS.Provisioner`** (`lib/agent_os/provisioner.ex`) — handles hard-wired agent configuration.
  - Sourced from `config/config.exs` under `config :agent_os, :agent` block.
  - Implements `agent_config/0` to expose `:manifest_path`, `:agent_cmd`, `:agent_args`, `:tz`, `:run_hour`, `:connectors`, `:outputs`, and `:spend_cap`.
  - Implements `check_drift/0` which reads the hand-kept manifest (`manifests/discovery.md`) and compares declared connectors, outputs, and spend-cap against config values. Logs a warning on divergence and returns `{:drift, mismatched_fields}` or `:ok`.
  - Implements `fire_run/0` as a logging execution stub, serving as a boundary hook to be wired into the real run pipeline in Plan 05.
- **`AgentOS.Scheduler`** (`lib/agent_os/scheduler.ex`) — a daily 07:00 self-rescheduling timer GenServer (no database or external cron dependencies).
  - Calculates time difference dynamically using pure timezone-safe arithmetic in `ms_until_next/2` (guaranteed > 0, rolls over to tomorrow if at-or-past the hour).
  - Arms a timer on `init/1` using `Process.send_after/3`.
  - On `:fire` message, executes the configured run function, computes the next interval, and schedules the next daily trigger (self-rescheduling).
- **Application Supervision tree Integration** (`lib/agent_os/application.ex`) — mounts the `AgentOS.Scheduler` process in the supervision tree, and runs the cheap Provisioner drift check at application startup when `autostart` is enabled (making manifest/config synchronization observable).
- **Configuration** (`config/config.exs`) — added hard-wired agent capability mirror grants (`connectors`, `outputs`, `spend_cap`), scheduled trigger time (`run_hour: 7`), and target timezone (`tz: "Etc/UTC"`).

## Verification Results

- **Provisioner Tests** (`test/agent_os/provisioner_test.exs`):
  - Verified `agent_config/0` loads config values accurately.
  - Verified `check_drift/0` detects matches and reports drift on connectors, outputs, and spend cap (via dynamic setup overrides and restore callbacks).
- **Scheduler Tests** (`test/agent_os/scheduler_test.exs`):
  - Verified pure arithmetic logic under three boundary cases (1h before, exactly at scheduled hour, 1h after).
  - Verified integration behavior of Scheduler process firing `run_fn` and self-rescheduling when receiving `:fire` message, checking process state for updated timer references.

## Interfaces established (consumed by 03–05)

- `AgentOS.Scheduler.ms_until_next(now_dt, hour)` -> returns non-negative millisecond difference.
- `AgentOS.Scheduler.start_link(opts)` -> starts Scheduler GenServer process.
- `AgentOS.Provisioner.agent_config()` -> returns configuration map.
- `AgentOS.Provisioner.check_drift()` -> `:ok` | `{:drift, list}`.
- `AgentOS.Provisioner.fire_run()` -> `:ok`.
