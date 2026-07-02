# Phase 9 — Spec Prompts (Persistent State & Permissions, v8)

Drafted `/speckit-specify` prompts for the Phase 9 plans. Surfaced during a design
discussion using the "buying agent" as an example workload (a monitor that keeps a long,
queryable history of what it has seen/shown and remembers user feedback) — the example
exposed these substrate gaps; it is not a committed product.

Paste each prompt after `/speckit-specify` when you're ready to open that spec.

## Ordering & dependencies

1. **09-01** (flag split) first — it introduces `requires_runtime_approval?`, which 09-02
   references. (Or soften 09-02's wording to be flag-independent.)
2. **09-02** (queryable store) — depends on 09-01. Engine choice (SQLite vs zero-dep
   append-log + ETS) is still open; decide before implementing.
3. **09-03** (retire term-file) — depends on 09-02 (the new backend must exist before the
   old one can be removed).

The backlog items surfaced by the same discussion (eBay connector, notify connector,
durable "watch" objective, feedback conditioning, and the Facebook-Marketplace
no-API feasibility flag) live in the Phase 9 section of `ROADMAP.md`, tagged
do-not-build-speculatively.

---

## 09-01 — Split the approval flag

```
/speckit-specify Split the connector approval model into two independent flags: `requires_deploy_consent?` (build-time) and `requires_runtime_approval?` (per-call runtime).

## Problem
A connector capability today carries a single boolean, `requires_approval?` (the `AgentOS.Connector` capability type in lib/agent_os/connector.ex). It is consumed in exactly one place — the gate (lib/agent_os/gate.ex, the approval check that returns `{:needs_approval, grant}`) — and its only effect is to PARK every proposed action of that type for per-call human sign-off at execution time (surfaced via the consent screen, spec 023).

This conflates two genuinely different human decisions:

1. **Build-time consent** — "may this agent be deployed holding this capability at all?" A one-time decision a human makes when the agent's manifest is approved (the deployment consent envelope, specs 011/023). Example: "yes, I approve that this agent can send messages to me."

2. **Runtime action approval** — "must each individual invocation be approved by a human before it acts?" A per-call decision, reserved for genuinely dangerous, irreversible, or high-blast-radius actions. Example: "hold this specific email to my customers until I click approve."

Because there is only one flag, any capability that needs a human's blessing at build time is forced into per-call approval at runtime. That is wrong for something like a notification channel: the human approves once, at deploy, that the agent may message them — but each notification should then just fire, not nag. The spend cap already bounds abuse (each send costs micro-dollars against the per-agent budget, and kill-on-breach stops a runaway), so per-call approval is not the right throttle for routine outbound.

## Desired behaviour
Replace the single `requires_approval?` with two orthogonal flags on the connector capability metadata:

- **`requires_deploy_consent?`** — when true, the capability may not appear in a deployed manifest unless a human explicitly approved it during the consent/deploy step. It has NO effect at runtime — it never parks an action. Defaults to false (auto-grantable).

- **`requires_runtime_approval?`** — when true, each proposed action of this type is parked for per-call human sign-off at execution time (the current `{:needs_approval, ...}` behaviour). Reserved for dangerous actions. Defaults to false.

The two are independent. Valid combinations:
- deploy yes, runtime no  → e.g. a notify/message-the-owner channel: approved once at deploy, fires freely thereafter (still scoped + metered).
- both yes                → a dangerous capability approved at deploy AND signed off per call (e.g. "email my customer list").
- both no                 → a local read or local write (e.g. search a store, draft, append to state).
- deploy no, runtime yes  → allowed but unusual.

## Clean cutover — no migration
There is no live/persisted state and no deployed manifest in use. This is a hard replacement of the old field, not a backward-compatible migration: remove `requires_approval?` entirely, wipe any existing state store contents if present, and set every existing connector's new flags directly:

- `gmail_read`   → requires_deploy_consent?: false, requires_runtime_approval?: false
- `gmail_draft`  → requires_deploy_consent?: false, requires_runtime_approval?: false
- `kv_append`    → requires_deploy_consent?: false, requires_runtime_approval?: false
- `external_send`→ requires_deploy_consent?: true,  requires_runtime_approval?: true

No code, test, or fixture may reference `requires_approval?` after this change.

## Acceptance criteria
- The gate parks an action for per-call approval IFF `requires_runtime_approval?` is set — never because of `requires_deploy_consent?`.
- The deploy/consent step rejects (or requires explicit human approval for) any manifest granting a capability whose `requires_deploy_consent?` is set; a capability without it is auto-grantable.
- The capability render / classification (lib/agent_os/capability_render.ex) is updated so `:local` still means no credential, no runtime approval, zero cost; `requires_deploy_consent?` surfaces as its own distinct, legible badge separate from runtime approval.
- A connector configured as (deploy_consent: true, runtime: false) fires without parking, while remaining scope-bounded and spend-metered.
- Legibility (invariant VIII): both flags are visible in the standing inventory / capability render without asking the agent.
- No occurrence of `requires_approval?` remains anywhere in the codebase.

## Out of scope
- The notify connector itself and the eBay/store connectors (separate features).
- Any change to how the spend cap or kill-on-breach works.
```

---

## 09-02 — Queryable record store (agent-invisible namespaces)

```
/speckit-specify Add a queryable, append-heavy record store as a second StateStore backend, exposed via `store_append` and `store_find` connectors, with policy-bound, agent-invisible namespaces.

## Engine decision (change here before running if desired)
Use embedded SQLite (via `exqlite`) as the backend. It runs in-process with no server (a file on disk, or an in-memory database in tests), so it honours the project's no-Docker / no-network deterministic-test rule. Alternative considered and rejected for now: a hand-rolled append-only log file + ETS index (zero-dependency, but reimplements indexing and query and needs compaction). Rejected: the single term-file (rewrites the whole blob per append), DETS (size cap + corruption on unclean shutdown), Mnesia (overkill), any server-based DB (breaks deterministic tests).

## Problem
The only state store today is `AgentOS.StateStore` (lib/agent_os/state_store.ex): a single-writer GenServer that persists one Erlang term-file holding one map, rewritten in full on every mutation (atomic tmp+rename). It supports only `:append`, `:put`, `:delete_in`, and has NO query — reads return a full snapshot copy. The `kv_append` connector (lib/agent_os/connector/kv_append.ex) writes to it with the mount name `"roster_trust"` hardcoded inside the connector.

This engine is correct for small config-like state (a manifest) but wrong for a high-volume, append-heavy record log queried by predicate:
- Appending row N rewrites all N rows to disk — O(total size) per write.
- There is no way to FIND records by property; the agent would have to pull the whole snapshot into context and scan it, which does not scale and blows the metered inference budget.

## Desired behaviour
A new substrate-owned store, single-writer per mount (invariant IX: one GenServer per mount is the sole writer; agents never hold the handle), that is:
- **Append-cheap**: writing one record does not rewrite existing records.
- **Queryable by predicate**: retrieve records matching field conditions (equality + comparison such as `<`, `>`, `>=`), with optional ordering and limit.
- **Crash-durable**: a committed write survives a node crash; a crash mid-write cannot corrupt committed data.
- **Domain-blind**: the substrate stores opaque records with declared indexable fields. It does not know what a "listing" or "verdict" is — record shape and meaning belong to the agent.
- **Legible (invariant VIII)**: the same query interface is available to the substrate/human, so history can be inspected without asking the agent.

### Connector surface (what the agent sees)
- `store_find` — read-only (`requires_runtime_approval?: false`, no credential, zero cost → `:local`). Takes a predicate and returns matching records.
- `store_append` — write (`:local`). Appends one opaque record.

The single `store_find` verb covers both "find prior records" and "load prior feedback" — feedback is just records of a given type. Read/write asymmetry (agent may query history but only the substrate writes ledger/verdict records) is expressed by granting `store_find` without `store_append`; no new machinery is needed for that.

## Manifest & permissions
Namespaces are **policy-bound and agent-invisible**. The agent never names, sees, or knows the real namespace of any store — consistent with manifest invisibility (invariant III) and no ambient authority (invariant X).

- A `store_find` / `store_append` proposed action carries a predicate or a record ONLY. It carries no namespace. The agent cannot express which store it touches.
- The real namespace is bound in the manifest grant (author/substrate-controlled) and resolved by the substrate from the matched grant at execute time. `kv_append`'s hardcoded `"roster_trust"` is removed; the mount comes from the grant, never from a literal and never from agent-supplied payload.
- Where an agent legitimately uses more than one store, the manifest assigns each grant a logical handle (e.g. an alias) that the agent uses to address the right store; the substrate maps that handle to the real, agent-invisible namespace. If an agent has a single store, the handle may be implicit.
- The gate does not need to validate an agent-supplied namespace (there is none). Its existing checks (connector granted, method in scope, spend, approval) stand; the substrate additionally resolves the grant's bound namespace and provides it to the connector at execute.
- Legibility vs invisibility: the standing inventory / capability render MAY show the real namespace to the human (VIII); anything the agent can observe MUST NOT include it (III).

This implies (for `/plan`, not to be designed here): the `Grant` struct (lib/agent_os/manifest/grant.ex, currently `{connector, recipients, methods}`) gains a namespace binding, and the connector `execute` path receives the grant-resolved namespace rather than reading a mount from the action payload.

### Relationship to the existing store
This is an ADDITIONAL backend, not a replacement (yet — the term-file is retired separately in 09-03). This plan delivers ONLY the record/predicate mode (`store_append` + `store_find`). It does NOT serve the existing map contract (`:put`, `:delete_in`, `:append`, `snapshot`) — that map/key-value mode, and the migration of the config mounts off the term-file, are added in 09-03. Small config-like state stays on the current term-file store for now. A mount declares which backend it uses.

## Acceptance criteria
- Appending the (N+1)th record does not re-serialize or rewrite the existing N records (write cost does not grow with store size).
- `store_find` returns exactly the records matching a multi-field predicate (equality + `<`/`>`/`>=`), honouring optional ordering and limit, without returning the whole store.
- A record written, followed by a simulated crash/restart of the mount's GenServer, is still present and queryable.
- `store_find` and `store_append` classify as `:local` in the capability render (lib/agent_os/capability_render.ex).
- The store holds opaque records; no substrate code references any domain-specific record type or field name.
- No proposed action, and nothing observable by the agent, contains a real namespace string. The namespace is resolved substrate-side from the grant.
- An agent granted `store_find` but not `store_append` can query but cannot write.
- The human-facing standing inventory / render can display the real namespace; the agent-facing surface cannot.
- Tests run with no Docker and no network (in-memory backend for the suite); the existing term-file store and its mounts continue to work unchanged.

## Out of scope
- The buying agent's specific record schema (listing, seen-set, notification ledger, verdict) — agent-level, defined by the agent.
- The map/key-value access mode (`:put`/`:delete_in`/`:append`/`snapshot`) on the new backend — added in 09-03 when the config mounts migrate. This plan is record/predicate mode only.
- Retiring the term-file backend (09-03).
- Log compaction / retention policy (revisit if the log-file backend is chosen).
- Any change to the gate's spend metering or the two approval flags.
```

---

## 09-03 — Retire the term-file backend

```
/speckit-specify Retire the term-file StateStore backend and consolidate all mounts onto the queryable backend behind the unchanged single-writer contract.

## Problem
After the queryable store lands (plan 09-02), two persistence engines sit behind the `AgentOS.StateStore` single-writer GenServer contract: the legacy term-file (one Erlang term-file per mount, rewritten in full on every write via atomic tmp+rename) and the new backend. The term-file has no remaining unique value:
- It rewrites the whole blob on every write — O(total size) per append — even for small state.
- It has no query; reads return a full snapshot copy.
- It is an opaque `:erlang.term_to_binary` blob — LESS inspectable than the new backend (which can be opened with standard tooling), so it is worse on legibility (invariant VIII), not better.
- Its crash-safety (tmp+rename) is weaker than the new backend's committed-write durability.

Keeping two engines is ongoing cognitive and maintenance cost for no benefit. The valuable, keep-worthy part is the `StateStore` GenServer *contract* — single-writer per mount, serialized `apply_action`, snapshot-by-copy, atomic apply (invariant IX). That is engine-independent and must be preserved exactly. Only the term-file *persistence* underneath it is retired.

## Scope
Two deliverables: (1) ADD a map/key-value access mode to the 09-02 backend, then (2) migrate the config mounts onto it and delete the term-file.

09-02 delivered the new backend in record/predicate mode ONLY (`store_append` + `store_find`). The config mounts, however, use the *map* contract (`:put`, `:delete_in`, `:append`, `snapshot`). So this plan first adds a map/key-value mode to the same backend — a key→value model where per-key writes do not rewrite unrelated keys and `snapshot` reconstructs the map — then repoints the callers onto it. The two modes are distinct storage shapes behind the one single-writer `StateStore` GenServer contract; this plan owns the map mode.

The term-file store is currently used by roughly these call-sites for small, config-like state: `inference_broker`, `trigger_gateway`, `conformance_auditor`, `run_worker`, `inventory`, `provisioner`, `stage5_review`, `consent_live`. All of them migrate.

## Desired behaviour
- All mounts run on the new backend. The term-file persistence code (the term-file load in `init/1` and the `persist/1` tmp+rename `term_to_binary` write) is deleted; there is no code path that reads or writes a term-file.
- The `StateStore` public API is unchanged for callers: `snapshot/1` and `apply_action/2` with `:append` / `:put` / `:delete_in` behave exactly as before. No call-site outside `StateStore` changes its usage.
- The single-writer-per-mount GenServer contract (invariant IX) is preserved: one writer, serialized mailbox, snapshot-by-copy, agent never holds the handle.
- A per-key write no longer rewrites unrelated keys — the O(total-size) write cost is gone for small state too.
- Crash/restart durability is preserved: a committed write survives a node crash.

## Clean cutover — no data migration
There is no live/persisted state to preserve. Do not build a term-file → new-backend data migration: repoint the mounts, delete the term-file code, and remove any stray term-files on disk. This is a pure engine swap with no behavioural change visible to callers.

## Acceptance criteria
- The new backend serves the map contract: `:put`, `:delete_in`, `:append`, and `snapshot` behave exactly as the term-file did, backed by per-key storage.
- No term-file persistence code remains anywhere: no `term_to_binary`-to-file write, no tmp+rename persist path, no `binary_to_term` file load in `StateStore`.
- All the listed mounts run on the new backend; every existing caller of `StateStore.snapshot/1` and `StateStore.apply_action/2` works unchanged.
- A `:put` to one key does not re-serialize or rewrite other keys in the same mount (write cost does not grow with mount size).
- A write followed by a simulated crash/restart of the mount's GenServer is still present (durability preserved).
- The full test suite and the world-B suite are green, with no Docker and no network (in-memory backend for tests).
- The single-writer contract is intact: mutation is serialized through one GenServer per mount; agents receive snapshot copies only.

## Out of scope
- Any new store capability, query surface, or connector (delivered in 09-02).
- Any change to the gate, spend metering, or approval flags.
- Remodelling small config state into records — the map contract stays; only the engine under it changes.
```
