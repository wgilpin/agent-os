# Agent Framework Bake-off — Scorecard

Date: 2026-07-12 · Host: macOS (Apple Silicon), Python 3.12.13 (venvs) · Harness: `harness/` (stub UDS broker + AF_UNIX-only socket jail) · Re-run: `python3 harness/run_all.py <bakeoff_dir>` → `logs/summary.json`

**Version note:** the pin target was corrected during the run — **latest pydantic-ai-slim on PyPI is 2.5.0** (verified with a cache-refreshed `uv` resolve). An earlier claim of "2.9.0" came from a bad web-page extraction and is wrong. Pin: `pydantic-ai-slim[openai]==2.5.0`.

## Candidates

1. **pydantic-ai-slim[openai]==2.5.0** — the `[openai]` extra is unavoidable: the OpenAI-format provider (`OpenAIChatModel`/`OpenAIProvider`) is the supported way to speak chat-completions JSON to a custom endpoint.
2. **No-framework baseline** — ~200-line typed tool loop (`candidates/run_nofw.py`): pydantic-only deps, raw HTTP/1.1 over AF_UNIX exactly like today's generated agents.
3. **openai-agents SDK** — *not run* (deprioritized after 1 and 2 produced a clear picture).

## Results

| Metric | pydantic-ai-slim 2.5.0 | no-framework |
|---|---|---|
| Import time (best of 3, subprocess wall) | **0.22 s** | **0.03 s** |
| Deps (packages / site-packages) | 30 / 45 MB | 5 / 8.3 MB |
| Offline-total (AF_UNIX-only jail) | **PASS** — 0 egress attempts | **PASS** — 0 egress attempts |
| UDS transport | **First-class**: `httpx.AsyncHTTPTransport(uds=…)` into `OpenAIProvider(http_client=…)` | Trivially native (raw socket) |
| Golden 2-tool task | **PASS** — typed args, history threaded, structured `Result` output | **PASS** — identical |
| Broker requests (3 commanded) | **3** — zero hidden calls | **3** — zero hidden calls |
| Malformed-args behavior | Feeds validation error back to model; fails closed after `retries=2` (configurable) at exactly 3 requests | Identical semantics at parity settings (3 requests) |
| Declarative body quality (1–5) | **5** — config + decorated pure functions | **3** — loop is imperative (but it would live in the kit, not in generated bodies) |

Notable in the import profile: `pydantic_ai.capabilities._deferred_capability_loader` is a top-5 import — the v2 capability machinery loads eagerly but cheaply.

## UDS integration (seed of `agent_os_runtime`)

```python
uds_client = httpx.AsyncClient(
    transport=httpx.AsyncHTTPTransport(uds=SOCK),
    base_url="http://localhost/v1", timeout=30.0)
provider = OpenAIProvider(base_url="http://localhost/v1",
                          api_key="stub-key", http_client=uds_client)
model = OpenAIChatModel("stub-model", provider=provider)
agent = Agent(model, output_type=Result, system_prompt=..., retries=2)
```

## Blessed-subset import surface (generation-prompt cheat sheet)

```python
from pydantic import BaseModel
from pydantic_ai import Agent
# transport comes from the kit, never generated:
from agent_os_runtime import substrate_model   # wraps the snippet above
```
Generated bodies need: `Agent(...)`, `@agent.tool_plain`, `output_type=<BaseModel>`, `run_sync`. Nothing else.

## Findings & surprises

- **Zero hidden spend in both candidates.** Broker logs reconcile call-for-call with commanded requests; retries are explicit, bounded, and each one is a visible (metered) broker request.
- **Offline-total passed** — no telemetry, no lazy tokenizer download was triggered in this flow, despite `tiktoken` sitting in the pydantic-ai tree. Residual risk: some code path could still touch it; the containerized `--network=none` run remains the final validation.
- **The `[openai]` extra drags the heavy tail** (`openai`, `tiktoken`, `requests`, `tqdm`, `regex`, otel/logfire shims): 30 packages vs 5. That's image size and supply-chain surface, not runtime cost.
- **AF_UNIX `sun_path` ≤ ~104 chars on macOS** bit this harness (deep temp dir → "path too long"). Relevant to the substrate: keep `INFERENCE_SOCKET` paths short.
- Runner code: `candidates/run_pydai.py`, `candidates/run_nofw.py`. Raw evidence: `logs/*.jsonl`, `logs/summary.json`.

## Verdict

**Back the `agent_os_runtime` kit with `pydantic-ai-slim[openai]==2.5.0`, pinned exact.** It passed every gating criterion — first-class UDS transport, offline-total, zero uncommanded calls, configurable retries — and its real costs (0.19 s import delta, ~37 MB image delta) are immaterial for container-run agents, while its declarative bodies are markedly better for machine review and generation. **Keep the no-framework loop as the exit ramp**: it passed everything at 7× the import speed and 1/6 the footprint, it's ~200 lines already written, and because generated bodies import only the kit (never pydantic-ai directly), swapping to it later costs a kit release, not a generation-contract change.
