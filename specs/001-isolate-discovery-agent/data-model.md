# Phase 1 Data Model: Isolate the Discovery Agent

Entities are described at the contract level (fields + validation), not as storage schemas
— there is no database (Constitution: term-file + git markdown only).

## Bookmark Item (untrusted, raw)

One bookmarked X/Twitter post as ingested from the operator's local export, before
sanitization. Treated as hostile-by-assumption.

| Field | Type | Notes |
|-------|------|-------|
| `id` | string | Source id; opaque. |
| `author` | string | Handle/display name. |
| `text` | string | Post body — the primary untrusted content. |
| `urls` | list[string] | Associated links; not fetched in v1. |

## Sanitized Bookmark Item

The validated, bounded form that crosses the port boundary into the container. Produced by
`Sanitizer` (Elixir) and re-validated by the Pydantic model (Python).

**Validation rules** (reject → item dropped and logged; FR-003, FR-006):

- `id`: non-empty string, ≤ 256 chars.
- `author`: string, ≤ 256 chars.
- `text`: string, ≤ N chars (bounded; default 10_000), control characters stripped,
  normalized to valid UTF-8.
- `urls`: list of ≤ M entries (default 32), each a syntactically valid `http(s)` URL,
  length-bounded.
- Whole-item byte size bounded; an oversized or schema-violating item is rejected, not
  truncated silently.

## Sandbox Run Config

The substrate-owned description of *how* a single agent invocation is contained. Built by
`Sandbox`; rendered into `docker run` argv (see `contracts/sandbox.md`). Represented as an
Elixir struct (Constitution V — no bare maps).

| Field | Type | Enforces |
|-------|------|----------|
| `image` | string | Which agent image/tag to run. |
| `network` | atom | `:none` — network disabled (deny-all) — FR-001/FR-008. |
| `read_only` | bool | Root FS read-only — FR-001. |
| `scratch_path` | string | The single writable tmpfs/scratch mount. |
| `memory_mb` | integer | `--memory` cap — FR-004 (OOM → exit 137). |
| `cpus` | float | `--cpus` cap. |
| `timeout_ms` | integer | Port-level timeout (existing). |

## Run Record (extended)

Phase 1's run-log/inventory entry, extended so a containerized run is legible (FR-006).

| Field | Type | Notes |
|-------|------|-------|
| `trigger` | enum | `:timer` \| `:manual` (FR-010 adds `:manual`). |
| `outcome` | enum | `:ok` \| `:failed`. |
| `exit_code` | integer? | Container exit code; `137` flagged as OOM. |
| `failure_cause` | string? | e.g. `"oom"`, `"crash"`, `"timeout"`, `"sanitizer_reject"`. |
| `items_in` / `items_dropped` | integer | Count ingested vs. rejected by the sanitizer. |
| `timestamp` | datetime | Run time. |

## State transitions (one invocation)

```text
ingest export → sanitize (drop+log rejects) → build Sandbox config →
  docker run (stub or real agent) →
    exit 0  → collect actions → effector applies the granted output action → Run Record :ok
    exit ≠0 → Run Record :failed(cause) → RunSupervisor: restart once, else alert
    timeout → wrapper stops container → Run Record :failed(:timeout)
```
