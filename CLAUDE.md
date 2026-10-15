# Stack & boundary

This is an **Elixir/OTP project**, not Python. The trusted, deterministic substrate —
kernel, gate, orchestration, scheduler, triggers, and the elicitation orchestrator — is
all Elixir under `lib/agent_os/`. Python appears **only** as sandboxed agent workloads
under `agents/<name>/` (discovery, elicitor), run across the BEAM port boundary
(`port_runner.ex`). The `pyproject.toml`/`pytest` config exists solely for those port
workloads. **The language boundary is the trust boundary** — do not infer the stack from
`pyproject.toml`. UI work (none yet) is Phoenix/LiveView territory, not HTMX.

**Deployment model: single-user, on the owner's Mac — never the cloud.** The heavy
security deliberately targets the *agents* (untrusted code beside personal data);
the app itself (UI on :4000) has no auth/TLS by design and assumes the one operator
at the machine. Do not propose cloud hosting, multi-tenancy, or login layers as
"production gaps" — they are out of scope by design.

<!-- SPECKIT START -->
For additional context about technologies to be used, project structure,
shell commands, and other important information, read the current plan:
`specs/046-agent-runtime-kit/plan.md`
<!-- SPECKIT END -->
