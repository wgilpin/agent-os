# Plan 01-03 Summary — Port Boundary + Python Discovery Agent

**Status:** Complete. All Elixir tests (26/26) and Python tests (3/3) are passing cleanly with zero compiler warnings.

## What was built

- **`priv/port_wrapper.sh`** — a POSIX-compliant stdin-guard wrapper script.
  - Reads a single-line JSON input from file descriptor 0.
  - Runs the child process (`uv run` or `.venv/bin/python`) in the background, feeding the input JSON.
  - Duplicates file descriptor 0 to file descriptor 3 to run a background subshell monitoring stdin for closure (EOF).
  - Automatically kills the child process via `kill -KILL` if stdin closes prematurely (orphan prevention during BEAM crash or timeout), or halts the blocker and propagates the child exit code when it terminates naturally.
- **`AgentOS.PortRunner`** (`lib/agent_os/port_runner.ex`) — a one-shot Erlang Port executor.
  - Runs commands through `priv/port_wrapper.sh`.
  - Feeds input to the child process and collects stdout binary data chunk-by-chunk.
  - Surfaces exit codes cleanly: returns `{:ok, stdout_binary}` on exit code 0, `{:error, {:exit_status, code}}` on non-zero exit codes, and `{:error, :timeout}` if the execution exceeds the timeout (default 30,000ms).
- **`agents/discovery/main.py`** — Python discovery agent workload.
  - Implements a Pydantic `Action(BaseModel)` representing proposed enumerated actions to enforce correct action shapes.
  - Parses JSON input from `sys.stdin.readline()`.
  - Implements a pure, testable `build_actions(input_data)` function.
  - Reasons over roster entries (a list of record maps) deterministically at v0: builds `append_digest` actions for high-signal entries, formats text output, handles empty input/no high-signal entries gracefully, and appends a trailing newline to the printed JSON to trigger the Erlang line-mode parser.
- **`agents/discovery/test_main.py`** — Python pytest suite.
  - Tests `build_actions` behaviors with empty inputs, high-signal items, and plain strings.
  - Contains an end-to-end integration test executing the python agent as a subprocess with simulated stdin and verifying the return code and stdout actions structure.
- **`pyproject.toml`** — Added `pythonpath = ["."]` in `[tool.pytest.ini_options]` so `pytest` can resolve package-level imports of `agents` cleanly inside the test suite.

## Verification Results

- **PortRunner Tests (`test/agent_os/port_runner_test.exs`):**
  - Happy path runs the Python discovery agent and receives expected JSON actions structure.
  - Standard command execution `bash -c "echo hello"` verifies stdout capture.
  - Non-zero exit code error surfacing verified with `bash -c "exit 1"`.
  - Timeout error and child termination verified with `bash -c "sleep 2"` and `timeout_ms: 100`.
- **Python Discovery Agent Tests (`agents/discovery/test_main.py`):**
  - Verified roster logic and action builders.
  - Subprocess execution happy path verified.

## Interfaces established (consumed by 04–05)

- `AgentOS.PortRunner.run(input_json, cmd, args, opts)` -> `{:ok, stdout}` | `{:error, {:exit_status, code}}` | `{:error, :timeout}`.
- Python agent command: accepts a single line of JSON on stdin; outputs `{"actions": [{"type": "append_digest", "payload": {"text": "..."}}]}\n` to stdout.
