# Phase 10 — Spec Prompts (Priorities Coach, v9)

Drafted `/speckit-specify` prompts for the Phase 10 plans. Full roadmap, doc-location
decision, and per-plan dependencies in [phase-10-priorities-coach-roadmap.md](phase-10-priorities-coach-roadmap.md).
Paste each prompt after `/speckit-specify` when starting that plan. All seven plans drafted;
run them in dependency order (10-01 → 10-02 → 10-03 → 10-04, then Wave B 10-05 → 10-06 → 10-07).

> **Channel decision (2026-07-06):** the notify/reply channel is **Discord**, not Google
> Chat. Google Chat's incoming webhooks and Chat-app API require a Google **Workspace**
> account; the user is a personal `@gmail.com` account, so those surfaces are unavailable.
> Discord incoming webhooks are a static per-channel URL available to any personal account —
> a clean fit for the static-key notify path with no OAuth. Trade-off carried forward:
> Discord's *outbound* ping is a simple webhook POST, but *receiving* the user's reply
> (10-03) needs a bot/gateway connection, not a plain inbound webhook — see the roadmap.

---

## 10-01 — `discord_notify` connector (first live outbound call)

```
/speckit-specify Add `discord_notify`, the first connector whose `execute/2` actually crosses the network — a live Discord incoming-webhook POST — completing the live-egress path that every existing egress connector only stubs.

## Problem
No connector `execute/2` has ever made a real outbound call. Every egress connector today is stubbed or sink-routed: `external_send.execute/2` (lib/agent_os/connector/external_send.ex) dispatches to `AgentOS.Connector.external_send_sink/2`, which sends to a test PID or no-ops; `web_search` returns canned text unless a mock fn is set; `gmail_draft` / `gmail_read` are `{:error, :not_implemented}`. `req` (~> 0.5) is already a dependency and the *inference broker* (lib/agent_os/inference_broker.ex) makes live HTTP calls with it, but no *connector* ever has. Meanwhile there is no notify-user channel at all — the substrate cannot tell the user anything. The Priorities Coach (and any future agent) needs to ping the user, and doing it for real is the point.

## Channel
Google Chat was ruled out: its incoming webhooks and Chat-app API require a Google Workspace account, and the operator is a personal `@gmail.com` account. Discord incoming webhooks are a static per-channel URL available to any personal account, need no OAuth, and match the static-credential notify shape exactly. The concrete channel differs from the original Google-Chat plan; the substrate design (static-credential notify egress, metered, agent-invisible destination) is unchanged.

## Desired behaviour
Land `discord_notify` as one self-contained module under lib/agent_os/connector/, implementing the `AgentOS.Connector` behaviour (lib/agent_os/connector.ex), auto-discovered by the 08-01 registry with no central list edited. It is a mutating, notify-user egress connector whose `execute/2` performs a real HTTPS POST (via `Req`) of a message to a Discord channel's incoming-webhook URL — a JSON body carrying the message text (Discord's `content` field) — and returns loudly on failure (invariant VI): a non-2xx response or transport error is `{:error, reason}`, never a swallowed success.

### Credential (static — no OAuth)
A Discord incoming webhook is a static per-channel URL that acts as the secret. Model it as a static credential resolved by `AgentOS.CredentialSource` (lib/agent_os/credential_source.ex, env / `.env` / app config, id → UPPERCASED env var) and injected at execute time by `AgentOS.CredentialProxy.with_credential/2` exactly as `external_send`'s `:outbound_token` is — the effector (lib/agent_os/effector.ex) already resolves `meta.credential` and hands the connector the secret. The agent never holds or sees the webhook URL (invariant X — no ambient authority). Declare the credential id in `metadata/0`; connector admission (08-03) provisions it. This plan adds NO OAuth and NO refresh (that is 10-05).

### Metadata / flags
- `mutating?: true`
- `requires_deploy_consent?: true` — approved once at deploy that the agent may notify this channel at all.
- `requires_runtime_approval?: false` — not a per-call human sign-off; the notify fires unattended.
- `credential:` a static webhook-URL credential id.
- `cost:` a non-zero per-call micro-dollar cost so the agent's spend cap IS the rate limit on notification volume (mirrors the backlog "notify connector" note: metered so the cap bounds the rate).

### Connector surface (what the agent proposes)
- Method `notify` (or similar single verb). The proposed action carries the **message text only** — never the webhook URL, never a channel id. The destination is agent-invisible: the substrate resolves it from the matched grant's credential at execute time (same invisibility discipline as 09-02's namespaces). An unknown method returns `{:error, {:unknown_method, other}}`, matching `external_send`.
- `scope/1` produces a `Grant` bounding `methods: ["notify"]`. Where more than one channel is later configured, the grant carries a logical channel handle that the substrate maps to the right webhook credential; for a single channel the handle may be implicit. This plan need only support one channel.
- `render/1` returns an `[EXTERNAL]`-badged, human-legible capability line (e.g. "NOTIFY THE USER ON DISCORD"), consistent with `external_send`'s render.

### Legibility (invariant VIII)
Each notification the substrate sends is recorded (run-log and/or standing inventory) with its message and outcome, so a human can see what was sent to the user without asking the agent.

### Outbound content
Agent-authored message text egresses through the existing outbound content path (lib/agent_os/output_check.ex / sanitizer.ex) unchanged — do not add a new checking mechanism; just route through what mutating egress already uses.

## Transport & testability (no-network deterministic tests — Constitution IV)
`execute/2` makes a live `Req` POST in production, but the transport MUST be injectable so the suite runs with no network: follow the established pattern (an `Application.get_env` override — e.g. a `discord_notify_transport_fn` / stubbed sink, as `web_search` uses `web_search_mock_fn` and `external_send` uses `external_send_sink_pid`). Unit tests assert the POST is shaped correctly (URL from the injected secret, JSON body carrying the message in Discord's `content` field) and that non-2xx / timeout become loud `{:error, _}`. A real POST to a real Discord channel is a manual live smoke, not a suite test.

## Acceptance criteria
- `discord_notify.execute/2` performs a real HTTPS POST to the injected webhook URL in production; with the test transport injected, the suite exercises success and failure with no network and no Docker.
- The proposed `notify` action carries message text only; nothing agent-observable contains the webhook URL or channel id. The destination is resolved substrate-side from the grant's credential.
- The connector is auto-discovered (no edit to `Gate`, `Effector`, the registry, `CredentialSource`'s contract, or `CapabilityRender` beyond what a new connector needs); `metadata/0` declares `requires_deploy_consent?: true`, `requires_runtime_approval?: false`, a static webhook credential id, and a non-zero cost.
- A non-2xx response or transport failure returns `{:error, reason}` and is logged (invariant VI) — never a silent `:ok`.
- The notification (message + outcome) is recorded so a human can read what was sent without asking the agent (invariant VIII).
- `discord_notify` classifies as external/mutating egress in the capability render (lib/agent_os/capability_render.ex), `[EXTERNAL]`-badged.
- The world-B suite is unchanged and green; the existing connectors are unaffected.

## Out of scope
- OAuth / token refresh and any credential-source change beyond declaring one more static id (that is 10-05).
- Reading or writing the priorities doc — local-file connectors (10-02) and Drive connectors (10-06).
- Ingesting the user's Discord *reply* — inbound message trigger (10-03), which for Discord needs a bot/gateway, not a plain inbound webhook.
- Generating/deploying the Priorities Coach agent end-to-end (10-04).
- Completing the `gmail_read` / `gmail_draft` stubs — not on this agent's path.
- Multi-channel fan-out, message embeds/threading, or retry/backoff policy beyond returning a loud error.
```

---

## 10-02 — Path-scoped file connectors: `file_read` + `file_write`

```
/speckit-specify Add `file_read` and `file_write` connectors — the first *live* external read (`Rd`) and a mutating filesystem write (`Mut`) — bounded by a new path-scoped manifest grant that the substrate resolves and enforces, so a generated agent can read and write the priorities doc without ever naming or seeing a host path.

## Scope-shape decision (change here before running if desired)
Adopt **handle-resolved paths (agent-invisible)** — the same discipline as the 09-02 store namespace. The manifest grant binds a real filesystem path (author/substrate-controlled); the agent addresses the document only by a logical handle; the substrate resolves handle → real path at execute time. The proposed action carries a handle (and, for writes, content) — never a path. There is therefore NO agent-supplied path to validate and NO path-traversal attack surface: the grant IS the path.
Alternative considered and deferred: **prefix + containment** — the agent supplies a relative path, the grant binds an allowed directory prefix, and the gate canonicalizes and checks containment (rejecting `..`/symlink escape, with a world-B traversal breach case). More flexible (an agent could navigate a whole vault) but adds a genuinely new gate check and attack surface. The Priorities Coach needs exactly one document, so handle-resolved is sufficient and strictly safer; graduate to prefix+containment only when a concrete agent must address many files under a directory. Pick before implementing.

## Problem
No connector `execute/2` reads live external data — the `Rd` column has only the `gmail_read` stub (`{:error, :not_implemented}`). And every manifest grant today scopes by `recipients` / `methods` — exact-membership checks in the gate (lib/agent_os/gate.ex, steps 2–3) over an API-shaped action. A document on disk (a local markdown file / Obsidian-vault note) has no recipient or method to bound; it needs a *path* binding, which the `Grant` struct (lib/agent_os/manifest/grant.ex — currently `connector, recipients, methods, handle, namespace`) cannot express. The Priorities Coach must read its priorities doc and write it back; both halves need this new grant shape.

## Desired behaviour
Two self-contained modules under lib/agent_os/connector/, implementing the `AgentOS.Connector` behaviour (auto-discovered by the 08-01 registry, no central list edited):
- `file_read` — non-mutating live read. `execute/2` reads the file bound to the matched grant and returns its contents. Read/write asymmetry is expressed by granting `file_read` without `file_write` (mirrors `store_find` vs `store_append`).
- `file_write` — mutating write-back. `execute/2` writes the supplied content to the file bound to the matched grant, atomically (tmp + rename, as `StateStore` already does for the term-file), and returns loudly on failure (invariant VI) — an I/O error is `{:error, reason}`, never a swallowed `:ok`.

Both connectors execute substrate-side (a trusted BEAM-side file read/write — NOT across the container/port boundary; no bind-mount into the agent sandbox). The agent proposes the action; the substrate performs the filesystem effect.

## Manifest & permissions (the new grant shape)
- Add a **path binding to `Grant`** (parallel to the 09-02 `:namespace` binding — e.g. `:path`). It is author/substrate-controlled and **agent-invisible** (invariant III — manifest invisibility; invariant X — no ambient authority). No proposed action and nothing agent-observable contains a real host path.
- The agent addresses the document by the existing `handle` mechanism the gate already matches (lib/agent_os/gate.ex, step 1 — `g.handle == action_handle`). The substrate resolves the grant's bound `:path` from the matched grant and hands it to the connector at execute — the connector receives the resolved path, never reads a path from the action payload. Where an agent uses more than one document, each grant carries its own handle → path binding; a single document may leave the handle implicit.
- The gate's existing checks stand unchanged: connector granted + handle match, spend, approval flags. Because the agent supplies no path, **no new gate validation is required** for the handle-resolved model — the grant match already bounds which file is touched. (Only the deferred prefix+containment alternative would add a containment check.)
- `scope/1` for each connector produces a `Grant` carrying the connector name, the `handle`, and the bound `:path` (path supplied via the projection boundaries, author-side).

### Metadata / flags
- `file_read`: `mutating?: false`, `requires_deploy_consent?: false`, `requires_runtime_approval?: false`, `credential: nil`, low/zero `cost`.
- `file_write`: `mutating?: true`, `requires_deploy_consent?: true` (a human vouches at deploy that the agent may write this document at all), `requires_runtime_approval?: false` (the 0800 write-back runs unattended — per-call sign-off would defeat it), `credential: nil`, low `cost`.
- `render/1`: human-legible capability lines (e.g. "READ THE PRIORITIES DOCUMENT" / an `[EXTERNAL]`- or mutation-badged "WRITE BACK THE PRIORITIES DOCUMENT"), consistent with existing connectors. The human-facing render MAY show the real path (invariant VIII); the agent-facing surface MUST NOT (invariant III).

### Legibility (invariant VIII)
Each write is recorded (run-log and/or standing inventory) with the real file and the outcome, so a human can see what the agent changed without asking it. The same file read/write is available to the substrate/human directly.

## Testability (no network, no Docker — Constitution IV)
File operations run against an injected root / temp directory in the suite (never a real user path); tests assert that a granted read returns the bound file's contents, a granted write updates it atomically, an I/O error becomes a loud `{:error, _}`, and that nothing agent-observable carries a real path. No network is involved; tests must not touch any path outside the injected test root.

## Acceptance criteria
- `file_read.execute/2` returns the contents of the file bound to the matched grant; `file_write.execute/2` atomically writes supplied content to it; both resolve the path substrate-side from the grant, never from the action payload.
- `Grant` carries an agent-invisible path binding; no proposed action, and nothing observable by the agent, contains a real host path. The agent addresses the document only by handle.
- An agent granted `file_read` but not `file_write` can read but cannot write (asymmetry via separate connectors).
- The gate rejects an ungranted file action (wrong/absent handle, or connector not granted) exactly as it rejects any ungranted action — the new grant shape is enforced by the existing grant/handle match, and **world-B stays green** with no breach case dropped or relaxed.
- `file_write` declares `requires_deploy_consent?: true` / `requires_runtime_approval?: false`; `file_read` declares both false; the capability render classifies each correctly and shows the real path only on the human-facing surface.
- A write failure (I/O error) returns `{:error, reason}` and is logged (invariant VI); a write is atomic (a crash mid-write cannot leave a truncated document).
- The write (real file + outcome) is recorded so a human can read what changed without asking the agent (invariant VIII).
- Both connectors are auto-discovered with no edit to `Gate`, `Effector`, the registry, or `CapabilityRender` beyond what a new connector + the `Grant` path field require; tests run with no network and no Docker, against an injected root.

## Out of scope
- The prefix + containment / path-traversal-defense model (deferred alternative above) — build only when an agent must address many files under a directory.
- Google Drive as the document source — `drive_read` / `drive_write` over OAuth (10-06); OAuth itself (10-05).
- Notifying the user or ingesting a reply — `discord_notify` (10-01), inbound trigger (10-03).
- Generating/deploying the Priorities Coach end-to-end (10-04).
- Completing the `gmail_read` / `gmail_draft` stubs — not on this agent's path.
- Any diff/merge or content-format logic (what the coach writes into the doc is agent-level, machine-written body — Constitution IX).
```

---

## 10-03 — Inbound Discord-reply message trigger (`Evt` from a real channel)

```
/speckit-specify Stand up a substrate-supervised Discord ingress that receives the user's reply in the channel and feeds it into the waiting agent's message trigger — the first real external event to enter the substrate.

## Ingress-mechanism decision (change here before running if desired)
Use a **Discord Gateway bot connection** (a persistent authenticated websocket the substrate maintains, subscribed to message-create events for the configured channel). Rationale: only the Gateway delivers free-text channel messages; the alternative — a Discord *interactions* HTTP endpoint — covers slash-commands and component clicks, not a plain typed reply, so it cannot carry "yes I did X, no I skipped Y". The cost is that the substrate owns a long-lived outbound websocket (unlike the plain inbound webhook Google Chat would have offered). Supervise it (let-it-crash + reconnect with backoff). Decide before implementing; if a slash-command UX is acceptable instead of free text, the interactions-endpoint route becomes viable and lighter.

## Problem
`AgentOS.TriggerGateway` (lib/agent_os/trigger_gateway.ex) is "the only substrate-side intake for event, message, and approval-resume triggers." It already accepts a `{:message, agent, content}` signal via `submit/1` / `submit_sync/2`, finds the agent whose manifest declares a `%{type: :message}` trigger, and starts a run: `start_run_fn.(trigger: "message", trigger_input: content, agent: agent_name)`. But nothing external has ever produced that signal — there is no real inbound channel. The message-trigger machinery is proven in tests only; the Priorities Coach needs the user's actual Discord reply to become that signal.

## Desired behaviour
A supervised substrate component that maintains the Discord Gateway connection, and on an inbound channel message from the **configured user in the configured channel**:
1. Authenticates/verifies the source (bot token identity; the message is from the expected user and channel — everything else is dropped, logged, and never turned into a signal).
2. Extracts the reply text.
3. Calls `TriggerGateway.submit({:message, agent, content})` for the coach — reusing the existing intake unchanged. The gateway does the manifest check and starts the run.

The bot token is a **static credential** resolved by `AgentOS.CredentialSource` and provisioned at admission (08-03) — no OAuth. The connection is supervised (crash → reconnect with backoff; a dropped socket must not take down the substrate — invariant VI, loud but isolated).

### Correlation is agent-level, not substrate
The substrate delivers the reply text as a message-triggered run; matching "this reply answers this morning's question" is the coach's job, using its own query-store history (yesterday's stated intentions / the pending check-in it wrote). Do NOT build run-resume or reply-correlation into the substrate — a message trigger starts a run with the content as input, exactly as today.

## Testability (no network, no Docker — Constitution IV)
The Gateway connection MUST be injectable/stubbed: tests feed a synthetic inbound message (from the configured source, and from a wrong source) into the ingress and assert that `TriggerGateway.submit/1` is called with `{:message, coach_agent, reply_text}` for the former and NOT called for the latter — with no network. The existing TriggerGateway message-dispatch tests stand unchanged.

## Acceptance criteria
- An inbound Discord message from the configured user+channel results in exactly one `{:message, agent, content}` submitted to `TriggerGateway`, carrying the reply text; the run starts via the unchanged `start_run_fn` path.
- A message from any other user or channel is dropped and logged, and produces no signal.
- The ingress is supervised: a dropped/errored connection reconnects (backoff) and does not crash the substrate; failures are logged loudly (invariant VI).
- The bot token is a static credential resolved substrate-side; nothing agent-observable contains it (invariant X).
- No substrate reply-correlation or run-resume is added; correlation stays agent-level. `TriggerGateway` intake and its tests are unchanged; world-B stays green.
- Tests exercise the accept and reject paths with a stubbed connection, no network, no Docker.

## Out of scope
- Sending the outbound ping — `discord_notify` (10-01).
- Reading/writing the doc — file connectors (10-02) / Drive (10-06).
- Generating/deploying the coach end-to-end (10-04).
- The interactions-endpoint / slash-command variant (the deferred alternative above), unless chosen at the decision point.
- Any change to how message triggers start runs, or any new trigger type.
```

---

## 10-04 — Generate the Priorities Coach end-to-end, live (Wave-A acceptance)

```
/speckit-specify Generate, deploy, and live-smoke the Priorities Coach through the unchanged six-stage pipeline, proving world-B holds against the machine-written agent with the new grant shapes from 10-01..10-03.

## Nature of this plan
This is glue + proof, not new stage logic — the same shape as spec 027 (E2E generation thread). The orchestrator (lib/agent_os/pipeline/orchestrator.ex), the gate, the review-mode rail, and the world-B-on-generated battery (test/agent_os/world_b_generated_test.exs) already exist. This plan threads the coach's stated purpose through elicit → manifest projection → judge → novel agent body → security-review → deploy-on-green, and re-proves world-B with the coach's grants. No new stage, no gate change.

## What the coach forces through the pipeline
The manifest projection must express, in one agent, grants and triggers that have not been generated together before:
- `file_read` + `file_write` with the handle-bound, agent-invisible **path grant** (10-02).
- `discord_notify` with a static webhook credential (10-01).
- a `%{type: :message}` trigger fed by the Discord reply ingress (10-03), AND the daily 0800 **time trigger** (the baseline scheduled trigger), together.
- a spend cap that bounds notification + inference volume.
If the elicitor/projection cannot yet emit a path-grant, or a message-trigger and time-trigger on the same agent, that gap is the work here.

## Desired behaviour
- Driving the pipeline from the coach purpose yields a machine-written manifest carrying exactly the grants/triggers above, a machine-written judge, a machine-written agent body, a passing security review, and an auto-deploy on green — human-out-of-the-loop after the conversation, recorded as one legible `PipelineRun`.
- **world-B-on-generated is re-proven with the coach's manifest**: every BC-* breach case holds against the machine-written manifest + body, no case dropped or relaxed. The new grant shapes (path grant, notify channel, message+time triggers) are gate-enforced exactly like existing grants — an ungranted file/notify/message action is rejected regardless of agent code.
- A **live smoke** (manual, not in the deterministic suite): 0800 time trigger fires → `file_read` the real local priorities doc → `discord_notify` the real Discord channel with the check-in question → the user replies → the Discord ingress raises a message trigger → the coach reads the reply and its query-store history → `file_write` the doc back. The whole loop runs on the deployed, generated agent.

## Acceptance criteria
- The coach is produced entirely by the pipeline (no hand-written manifest, judge, or body) and auto-deploys on green; the `PipelineRun` records per-stage outcome, both verdicts, and deploy provenance (legibility, invariant VIII).
- world-B-on-generated passes against the coach's manifest with no breach case dropped; the path grant and notify channel are enforced identically to recipient/method grants.
- The generation/orchestration tests run with injected provider/effector stubs — no live model calls, no network, no Docker (Constitution IV).
- The manual live smoke completes the full 0800 → read → ping → reply → coach → write-back loop against the deployed agent (documented as a quickstart, not a suite test).
- No new stage logic and no change to `Gate`, the envelope predicate, or review-mode semantics.

## Out of scope
- Google Drive as the doc source — Wave A ships on the local file; Drive is 10-06/10-07.
- The coach's coaching quality / prompt content — agent-level, machine-written (Constitution IX); this plan proves the substrate delivers it, not that the advice is good.
- Any new connector or trigger primitive (all are built in 10-01..10-03).
```

---

## 10-05 — OAuth-with-refresh credential (the `OAuth` primitive)

```
/speckit-specify Extend the credential path so a credential can be an OAuth-with-refresh credential — the substrate holds a refresh token and mints/rotates a short-lived access token, injecting the current one per call — without changing the connector-facing `with_credential/2` contract.

## Implementation decision (change here before running if desired)
Hand-roll a minimal OAuth2 refresh over `Req` (already a dependency): store the refresh token + client id/secret + token endpoint as the credential's secret material; when the cached access token is absent or expired, POST the refresh grant to the token endpoint, cache the new access token with its expiry, and inject it. Rejected: `goth` (Google *service-account* auth, not user authorization-code + refresh — wrong grant type for user Drive access); a full OAuth client library (overkill for one refresh flow). Note: obtaining the FIRST refresh token (the one-time authorization-code consent) is an out-of-band operator setup step, NOT substrate-automated — this plan automates refresh + injection only.

## Problem
`AgentOS.CredentialProxy.with_credential(credential_id, fun)` (lib/agent_os/credential_proxy.ex) resolves a **static** secret from `AgentOS.CredentialSource.resolve_credentials/0` (lib/agent_os/credential_source.ex — env / `.env` / app config), cached once at proxy init. Every credential today is a fixed string. Google Drive (10-06) needs an OAuth access token that expires and must be refreshed; a static string cannot express that. This is the `OAuth` column: the broker holds static keys only.

## Desired behaviour
- A credential may be declared as an OAuth-with-refresh credential, whose stored material is the refresh token + client id/secret + token endpoint (never a bare access token).
- On `with_credential(id, fun)` for such a credential, the substrate ensures a valid, unexpired access token — refreshing via the token endpoint when needed — and passes the **current access token** into `fun`. The connector-facing contract is unchanged: connectors still call `with_credential/2` and receive a `String.t()` secret; they do not know or care whether it is static or refreshed.
- The refresh token and client secret never leave the substrate and are never observable by the agent (invariant X). Access-token refresh is loud on failure (invariant VI) — a failed refresh is `{:error, _}`, not a stale/blank token.
- Refresh material is provisioned at connector admission (08-03), the same reviewed step that provisions static credentials.

## Testability (no network — Constitution IV)
The token endpoint MUST be injectable/stubbed. Tests assert: a valid cached token is injected without refresh; an expired/absent token triggers exactly one refresh and injects the new token; a refresh failure surfaces loudly and does not inject a stale token; the static-credential path is unchanged. No network, no Docker.

## Acceptance criteria
- `with_credential/2` returns unchanged behaviour for static credentials; for an OAuth credential it injects a current, unexpired access token, refreshing transparently when expired.
- The refresh token / client secret are held substrate-side only; nothing agent-observable contains them; the agent sees no token at all.
- A refresh failure returns a loud error and never injects a stale or empty token (invariant VI).
- OAuth refresh material is provisioned via the admission path (08-03), consistent with static-credential provisioning.
- Existing connectors and the static-credential resolution are untouched; world-B stays green; tests run with no network.

## Out of scope
- The one-time authorization-code consent that mints the first refresh token — operator setup, documented, not substrate-automated.
- The Drive connectors themselves (10-06).
- Multi-provider OAuth abstraction / token stores beyond what one Google refresh flow needs (build only when a second OAuth provider appears — scope-gravity).
- Any change to the `with_credential/2` connector contract.
```

---

## 10-06 — `drive_read` + `drive_write` connectors (Drive variant of the doc source)

```
/speckit-specify Add `drive_read` and `drive_write` — live read and write-back of the priorities document in Google Drive over the OAuth credential from 10-05 — the id-scoped cloud parallel of the local file connectors.

## Document-format decision (change here before running if desired)
Store the priorities doc as a **plain-text file in Drive** and use the Drive Files API (get media / update media) for read and write. Rationale: it mirrors the local-file content model (10-02) exactly — full-content read, full-content atomic overwrite — so the coach's agent body is unchanged whether it targets local or Drive, and it keeps the same simple content contract. Rejected for now: the Google Docs structured API (rich document with structural edits) — heavier, different content model, only needed if the doc must be a formatted native Google Doc. Decide before implementing.

## Problem
Wave A reads/writes a local file (10-02). To satisfy the original "priorities doc in Google Drive" ask, the substrate needs connectors that read and write a Drive document — the first live egress requiring OAuth. `req` and the live-egress path are proven (10-01), and OAuth-with-refresh injection exists (10-05); what is missing is the Drive-specific read/write connectors and an **id-scoped** grant shape (bind a document id, where 10-02 binds a filesystem path).

## Desired behaviour
Two self-contained modules under lib/agent_os/connector/, auto-discovered:
- `drive_read` — non-mutating; `execute/2` fetches the bound document's content via the Drive API using the injected OAuth access token; returns the text.
- `drive_write` — mutating; `execute/2` overwrites the bound document's content atomically via the Drive API; loud `{:error, _}` on failure (invariant VI).
Both use `with_credential/2` with an OAuth credential (10-05) — the connectors are unaware of refresh; they just receive a current access token. The read/write asymmetry is granting `drive_read` without `drive_write`.

## Manifest & permissions (id-scoped grant, agent-invisible)
- The grant binds the **Drive document id** (author/substrate-controlled), agent-invisible, addressed by the existing `handle` mechanism — the parallel of 10-02's path binding. No proposed action carries a document id; the substrate resolves it from the matched grant.
- Flags: `drive_read` — `mutating?: false`, both consent flags false, OAuth credential id, low cost. `drive_write` — `mutating?: true`, `requires_deploy_consent?: true`, `requires_runtime_approval?: false`, OAuth credential id, low cost.
- `render/1`: human-legible lines; the human-facing surface MAY show the document id/name (invariant VIII), the agent-facing surface MUST NOT (invariant III).
- Each write is recorded (run-log/inventory) with the document and outcome (invariant VIII).

## Testability (no network — Constitution IV)
The Drive API transport MUST be injectable/stubbed (as `discord_notify` and the file connectors are): tests assert a granted read returns the bound document's content, a granted write overwrites it, an API/auth error becomes a loud `{:error, _}`, and nothing agent-observable carries a document id or token. No network, no Docker.

## Acceptance criteria
- `drive_read.execute/2` returns the bound document's content and `drive_write.execute/2` overwrites it, both using the OAuth access token injected by 10-05 and resolving the document id substrate-side from the grant.
- The grant binds an agent-invisible document id addressed by handle; no proposed action or agent-observable surface contains the id or the token.
- An agent granted `drive_read` but not `drive_write` can read but cannot write.
- The gate rejects ungranted Drive actions exactly as any other; world-B stays green with no breach case dropped.
- `drive_write` declares deploy-consent true / runtime-approval false; renders classify correctly; writes are recorded for the human (invariant VIII); failures are loud (invariant VI).
- Auto-discovered with no gate/effector/registry edits beyond a new connector; tests run with no network, no Docker, against a stubbed Drive transport.

## Out of scope
- OAuth refresh itself (10-05) and the one-time consent (operator setup).
- The Google Docs structured API / rich formatting (deferred alternative above).
- Local file connectors (10-02) — this is the Drive variant; both can coexist, the coach chooses one per deployment.
- Regenerating the coach against Drive (10-07).
```

---

## 10-07 — Regenerate the coach against Drive (Wave-B / OAuth-path acceptance)

```
/speckit-specify Regenerate and live-smoke the Priorities Coach with its document source switched from the local file to Google Drive, proving OAuth injection and id-scoped Drive grants hold end-to-end and world-B stays green.

## Nature of this plan
The Wave-B counterpart of 10-04 — glue + proof, no new stage logic. Re-run the pipeline for the coach with the manifest projection targeting `drive_read` / `drive_write` (id-scoped, OAuth-credentialed) instead of `file_read` / `file_write` (path-scoped). Everything else — `discord_notify`, the Discord message trigger, the daily time trigger, the spend cap, the agent body's read/write-full-content contract — is unchanged, which is the point: only the document connector and its credential differ.

## Desired behaviour
- Driving the pipeline yields a machine-written coach whose manifest binds an agent-invisible Drive document id (handle-addressed) and an OAuth-with-refresh credential, deployed on green through the unchanged pipeline.
- **world-B-on-generated re-proven** with the OAuth-credentialed, id-scoped grants: no breach case dropped; an ungranted Drive read/write is rejected regardless of agent code; the OAuth token is never agent-observable.
- **Live smoke:** 0800 → `drive_read` the real Google Doc (OAuth token minted/refreshed by 10-05) → `discord_notify` the real channel → user replies → message trigger → coach reads reply + store history → `drive_write` the doc back. OAuth refresh is exercised for real across the run.

## Acceptance criteria
- The coach is produced entirely by the pipeline with a Drive-targeted manifest and an OAuth credential, auto-deployed on green; the `PipelineRun` is recorded legibly.
- world-B-on-generated passes with the OAuth-credentialed, id-scoped Drive grants — no breach case dropped or relaxed; the token and document id are never agent-observable.
- Generation/orchestration tests run with injected stubs — no live model calls, no network, no Docker.
- The manual live smoke completes the full loop against a real Google Doc, exercising live OAuth refresh, and is documented as a quickstart.
- The Priorities-Coach row in the agent-primitive matrix goes fully green (Wave B) and the `OAuth` column closes in the saturation tracker.

## Out of scope
- Any new connector/credential/trigger work (all built in 10-05/10-06).
- Keeping the local-file variant working in the same deployment — the coach targets one document source; switching is a manifest/projection choice, not a runtime toggle.
- Coaching quality — agent-level (Constitution IX).
```


