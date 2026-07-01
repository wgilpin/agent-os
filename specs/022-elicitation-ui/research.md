# Research: Elicitation UI Asset Serving & Process Lifecycle

## 1. Zero-Build Static Asset Serving

### Objective
Serve Phoenix and LiveView client-side JavaScript without installing npm, Node.js, or configuring bundlers like esbuild or Webpack.

### Finding
Phoenix and Phoenix LiveView packages already bundle their compiled production JavaScript in their respective `priv/static` directories. We can expose these directories directly using Phoenix's `Plug.Static` plug.

By adding the following to `AgentOSWeb.Endpoint`:
```elixir
plug Plug.Static,
  at: "/phoenix",
  from: {:phoenix, "priv/static"}

plug Plug.Static,
  at: "/phoenix_live_view",
  from: {:phoenix_live_view, "priv/static"}
```

We can import them in `root.html.heex` using standard `<script>` tags:
```html
<script src="/phoenix/phoenix.js"></script>
<script src="/phoenix_live_view/phoenix_live_view.js"></script>
```

This guarantees zero compile-time or run-time dependencies on node/npm and is fully offline-compliant.

---

## 2. Preventing Elicitation Session Process Leaks

### Objective
Ensure that starting an `ElicitationSession` (which registers a run token and allocates resources) does not leak when a user closes their browser or navigates away.

### Finding
LiveView runs in a stateful Erlang process. When a browser client opens a WebSocket connection, a LiveView process is spawned. Calling `ElicitationSession.start_link/1` from this process links the two processes.

However, a clean client disconnect causes the LiveView process to terminate with exit reason `:normal`. By default, a `:normal` exit does not propagate to linked processes, meaning the `ElicitationSession` GenServer would remain alive (leaked).

### Solution
Implement the `terminate/2` callback in `ElicitationLive`:
```elixir
def terminate(_reason, socket) do
  if pid = socket.assigns[:session_pid] do
    if Process.alive?(pid) do
      GenServer.stop(pid)
    end
  end
  :ok
end
```
The `terminate/2` callback is guaranteed to run when the channel process shut down (both clean disconnects and crashes). This guarantees all allocations are cleanly freed.
