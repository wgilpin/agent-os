# Phase 10 — Priorities Coach (live personal agent, v9)

**Type:** workload-driven build-out (the third turn of the loop described in
[ROADMAP.md](ROADMAP.md) → *Strategy*; candidate agent tracked in
[agent-primitive-matrix.md](agent-primitive-matrix.md) → *Priorities coach* row and
*Connector backlog* table).

**Goal.** Deliver the **Priorities Coach** as a real, generated, *live* agent — not a mock.
A daily 0800 run reads the user's priorities doc, pings them on Discord asking whether
yesterday's stated intentions actually happened, offers coaching if appropriate, and writes
the doc back to reflect the current state.

> **Channel feasibility (2026-07-06):** the notify/reply channel is **Discord**, not Google
> Chat. Google Chat's incoming webhooks and Chat-app API require a Google **Workspace**
> account; the operator is a personal `@gmail.com` account, so those surfaces are unavailable.
> Discord incoming webhooks are a static per-channel URL available to any personal account, so
> the `Notif` outbound path (10-01) lands on the static-key broker unchanged. **Asymmetry to
> plan around:** Discord's outbound ping is a simple webhook POST, but *receiving* the user's
> reply (10-03) needs a Discord **bot/gateway** connection (persistent websocket or an
> interactions endpoint), not a plain inbound webhook — a heavier ingress than Google Chat
> would have been. Telegram was the lighter option for the reply loop but was not chosen. The user's Chat reply flows back in and drives the
update. All coaching / diff logic is machine-written agent body (Constitution IX); this phase
builds **only the substrate grants the manifest projection would need and can't yet issue.**

**Depends on:** Phase 8 (pluggable connector registry + credential proxy + admission) and
Phase 9 (queryable store — "since yesterday" is a `store_find`; already live).

**Surfaced by:** the Priorities-Coach candidate. It is the widest gap-opener currently on the
matrix — it lights **four** open columns at once (`Rd`, `Mut`-for-real, `OAuth`, `Notif`) and
is the first *live* exercise of `Evt` from a real external channel. That makes it a high-value
divergence pick, not a convergence one.

---

## What's actually missing (the honest starting state)

The connector *wiring* is proven end-to-end, but **nothing has crossed the network/filesystem
boundary for real.** From the code today:

- **Live egress is unproven at the connector boundary.** `external_send.execute/2` routes to a
  test PID or no-ops; `web_search` returns canned text unless a mock fn is set;
  `gmail_draft` / `gmail_read` are `{:error, :not_implemented}` stubs. `req` is a dep and the
  *inference broker* makes live calls, but no **connector** `execute/2` ever has.
- **The credential source is static-only.** `AgentOS.CredentialSource.resolve_credentials/0`
  maps `credential_id → UPPERCASED env var`. No OAuth, no refresh, no token rotation.
- **The trigger gateway has message-trigger machinery (spec 007) but no real inbound surface.**
  Nothing external has ever POSTed a message into a waiting agent's trigger.

So this phase is part **build** (new primitives/connectors) and part **complete-not-mock**
(make the live-egress path and the inbound-trigger surface actually cross the boundary).

### Primitives to BUILD (matrix columns this closes)

| Primitive | What it forces |
|-----------|----------------|
| `Rd` (first *live* read) | A read connector whose `execute/2` actually returns external data. Forces a **path-scoped grant shape** for the local-file variant (grants over filesystem paths, not API methods/recipients) and a matching gate constraint. |
| `Notif` (notify-user channel) | First notify-user egress. Discord *incoming webhook* is a static per-channel URL → lands on the existing static-key credential source with **no OAuth**. |
| `OAuth` (refresh credential) | Only forced by the **Drive** variant. Extends the credential source to hold a refresh token, mint/rotate access tokens, and inject the current one per call behind the credential-proxy boundary (agent never sees it). |
| `Evt` (real external message) | First inbound message from a real channel. For Discord this needs a **bot/gateway** (persistent websocket or interactions endpoint) that maps an inbound message onto the waiting agent's message trigger — heavier than a plain inbound webhook POST. |

`Query` (`store_find`/`store_append`) and the daily time trigger are **already live** — reused,
not built. `Fbk` (coaching conditioned on prior check-ins) stays **backlog**; the doc + query
history cover the core loop without it — do not build speculatively.

### Connectors to BUILD / COMPLETE

| Connector | Kind | Credential | Build vs complete |
|-----------|------|-----------|-------------------|
| `discord_notify` | notify (live HTTP POST) | static webhook URL | **build + completes** the live-egress path |
| `file_read` / `file_write` *(local / Obsidian vault)* | read + mutating (filesystem) | none | **build** (path-scoped grant shape) |
| `drive_read` / `drive_write` | read + mutating (live HTTP) | OAuth (refresh) | **build** — Drive variant only |

The `gmail_read` / `gmail_draft` stubs are **not** on this path — leave them stubbed; don't
complete speculatively.

---

## Doc-location decision (fork resolved)

Both a local file and a Google Doc are legitimate `Rd` connectors — connectors execute
substrate-side, so a local-md / Obsidian-vault read is a trusted BEAM-side file read (no
container bind-mount). They differ only in cost and which column they open:

- **Local file / Obsidian** — cheapest live `Rd` (no credential at all), but forces the new
  **path-scoped grant shape**. Ships a working live coach without touching OAuth.
- **Google Drive** — costs the whole `OAuth`-with-refresh build-out, but that's a real open
  substrate column worth closing.

**Recommendation: stage it.** Build the coach on **local file first** (Wave A) to deliver a
working live agent fast and surface the path-grant + live-egress + inbound-trigger gaps; then
cross the **OAuth/Drive** gap deliberately as Wave B when you want that column closed. This
follows the workload-driven discipline: build only what the agent forces — until you *choose*
Drive, OAuth isn't forced.

---

## Plans (each becomes one `/speckit-specify`)

Ordered; dependencies noted. Wave A delivers a working live coach on local files; Wave B is
the OAuth/Drive upgrade.

### Wave A — working live coach (no OAuth)

- **10-01 — `discord_notify` connector: first real outbound call (`Notif` live).**
  Complete the connector → live-HTTP path (today every egress connector is stubbed/sink-routed).
  Land `discord_notify` as the first connector whose `execute/2` actually POSTs over the network —
  a Discord incoming-webhook message. Static per-channel webhook URL via the existing static
  credential source (no OAuth). Metered so the spend cap *is* the rate limit;
  `requires_deploy_consent?: true`, `requires_runtime_approval?: false`. Tests stub the HTTP
  sink; acceptance is a manual live smoke against a real Discord channel. **Depends on:** none.

- **10-02 — Path-scoped file connectors: `file_read` + `file_write` (`Rd` live + `Mut` on a
  path grant).** A read connector that actually reads the priorities doc and a write connector
  that writes it back. Forces the new **path-scoped grant shape** in the manifest/gate (grant
  bounds a filesystem path prefix; the gate constrains reads/writes to it) — the shared new
  thing, so read + write ship together. No credential. Closes `Rd` live without OAuth.
  **Depends on:** none (parallel with 10-01).

- **10-03 — Inbound external message trigger: Discord-reply ingress (`Evt` from a real channel).**
  Stand up a Discord **bot/gateway** connection (persistent websocket, or an interactions
  endpoint) that receives the user's reply in the channel, verifies the sender, maps it onto
  the waiting agent's message trigger (spec 007 machinery), and feeds it into the run. First
  real external `Evt`. **Heavier than the original Chat plan** — a plain inbound webhook POST
  would not have needed a gateway; Discord does. **Depends on:** trigger gateway (present);
  pairs with 10-01 for the full ask→reply loop.

- **10-04 — Generate the Priorities Coach end-to-end, live (Wave-A acceptance / saturation
  point).** Drive the elicitor with the coach's purpose; the manifest projection must express
  the new grants (path-scoped file read+write, `discord_notify`, Discord-reply event, daily
  trigger, spend cap). The pipeline writes the judge, the novel agent body, security-reviews,
  and deploys on green — human-out-of-the-loop. **Re-prove world-B-on-generated with the new
  grant shapes** (no breach case dropped — the path grant and notify channel must be
  gate-enforced exactly like existing grants). Then a live smoke: 0800 fires → reads the real
  local doc → pings the real Discord channel → ingests the reply → coaches → writes the doc
  back. **Depends on:** 10-01, 10-02, 10-03.

### Wave B — OAuth / Drive upgrade (cross the `OAuth` column)

- **10-05 — OAuth-with-refresh credential source (`OAuth` primitive).** Extend
  `CredentialSource` (static-env only today) to hold an OAuth refresh token, mint/rotate the
  access token on expiry, and inject the current access token per call — behind the
  credential-proxy boundary so the agent never sees it. Provisioned at connector-admission time
  (Phase 8, 08-03). Substrate primitive; unblocks any Google/OAuth connector.
  **Depends on:** none (independent of Wave A; only Wave B needs it).

- **10-06 — `drive_read` + `drive_write` connectors (Drive variant of the doc source).** Live
  read + live write-back of a Google Doc using 10-05's OAuth credential, over the live-egress
  path proven in 10-01. Same manifest/gate treatment as the file connectors, but API-scoped
  (document id) rather than path-scoped. **Depends on:** 10-01 (live egress), 10-05 (OAuth).

- **10-07 — Regenerate the coach against Drive (Wave-B / OAuth-path acceptance).** Re-run 10-04's
  end-to-end generation with the doc source switched to Drive; confirm OAuth injection, live
  read/write, and world-B-on-generated all hold with the OAuth-credentialed grants.
  **Depends on:** 10-04, 10-06.

---

## Phase success criteria (what must be TRUE)

1. **A generated agent makes a real outbound call.** `discord_notify.execute/2` POSTs a live
   message to a real Discord channel; no connector `execute/2` is sink-routed or canned on
   this path.
2. **A generated agent reads real external data**, bounded by a gate-enforced grant — a
   path-scoped grant (local file) in Wave A, an id-scoped Drive grant in Wave B.
3. **The user's Discord reply re-enters the substrate** through the bot/gateway ingress and
   drives the same run's doc update (first live `Evt` from a real channel).
4. **The coach is machine-generated and auto-deployed** through the unchanged pipeline
   (elicit → manifest → judge → novel agent → security-review → deploy-on-green), and
   **world-B-on-generated stays green** with the new grant shapes — no breach case dropped or
   relaxed.
5. **(Wave B)** The credential source holds and refreshes an OAuth token, injecting the current
   access token per call without the agent ever observing it; Drive read + write-back work live.
6. The Priorities-Coach row in [agent-primitive-matrix.md](agent-primitive-matrix.md) goes
   all-green (Wave B) and the `Rd` / `Notif` (and, Wave B, `OAuth`) columns close in the
   saturation tracker.

## Explicitly out of scope

- `Fbk` (cross-run feedback conditioning) — backlog; the doc + query history carry the loop.
- Completing the `gmail_read` / `gmail_draft` stubs — not on this agent's path.
- The `NoAPI` browser-egress fork and `NoMoney` enforcement — different candidate agents.

## Next step

These plans are the units; the per-plan `/speckit-specify` prompts are **not** drafted here (as
with Phase 9's separate `phase-09-spec-prompts.md`). Draft them plan-by-plan when starting each,
beginning with **10-01**.
