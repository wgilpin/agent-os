# Agent × Primitive Matrix — workload-driven build-out

**Strategy.** Drive substrate completeness by building a *series of concrete agents* and only
adding the substrate features each one forces — until a new agent can be built with **zero**
new substrate (only composition of existing primitives). That end-state is **feature
saturation**: the platform's definition of done.

**How to use this file.**
- **Pick the next agent** by which *missing* cells it unlocks per unit of build cost. Prefer
  divergence early (agents that light up different columns) so gaps surface fast.
- **Read saturation** off the grid: when a *candidate* agent's row is all-`✓` (needs nothing
  missing), that region of the space is done. A run of all-green candidates = saturated.
- **Guard against two failure modes**: *scope gravity* (build only the slice the current agent
  needs, not the general primitive — see 08-02 discipline) and *false saturation* (if every
  agent clusters in one corner, you'll declare done having covered a quarter of the matrix).

## Baseline — free for every agent (not columns)

Every generated agent already gets these, so they never discriminate between candidates:
sandbox/isolation, the deterministic gate + manifest enforcement, manifest invisibility,
credential broker (static app-key injection), spend metering + kill-on-breach, the
scheduled/time trigger, capability render + consent view, the review-mode envelope +
deploy-time consent, the conformance auditor, the standing inventory, small-config KV state
(map contract), and the full generation pipeline (elicit → manifest → judge → novel agent →
security-review → deploy-on-green).

## Primitive inventory (the columns that vary)

| Code | Primitive | Status |
|------|-----------|--------|
| `Evt` | Event / message trigger | ✓ present (spec 007) |
| `Rd` | Read-only external egress (credentialed API) | ◐ registry present, **no live-read connector yet** (all are stubs) |
| `Mut` | Mutating external egress (send / post) | ✓ present (`external_send`, `gmail_draft`; exercised by 04-10) |
| `NoAPI` | Browser / no-API egress (implies personal session creds) | ✗ **strategic fork** — not supported |
| `OAuth` | OAuth-with-refresh credential | ✗ missing (broker holds static keys only) |
| `Notif` | Notify-user channel | ○ backlog (Phase 9 note) |
| `Query` | Long queryable history store (`store_find`/`store_append`) | ✓ present (**09-02** merged) |
| `Fbk` | Cross-run feedback conditioning | ○ backlog (Phase 9 note) |
| `Tool` | Synchronous tool-use mid-reasoning (e.g. web_search) | ✓ present (**08-02** merged) |
| `RunApr` | Per-action runtime approval (dangerous action gate) | ✓ present (gate + consent 023; refined by **09-01**) |
| `NoMoney` | Enforced "never move money" boundary | ✗ norm only, **not enforced** by the substrate |

## The matrix

Rows = candidate agents. Cell = *does this agent need the primitive, and what's its status*:
`✓` needs & available · `09-02`/`08-02` needs & planned (plan #) · `bklog` needs & backlog ·
`new` needs & requires new-but-clearly-buildable work · `FORK` needs & strategic decision required ·
blank = not needed.

| Agent | Evt | Rd | Mut | NoAPI | OAuth | Notif | Query | Fbk | Tool | RunApr | NoMoney |
|-------|-----|----|-----|-------|-------|-------|-------|-----|------|--------|---------|
| **eBay monitor** *(in flight)* | | bklog | | | bklog | bklog | 09-02 | bklog | | | |
| **Recruiter-email responder** *(built, 04-10)* | ✓ | | ✓ | | | | | | | ✓ | |
| **Inbox digest / triage** | | new | | | | bklog | | | | | |
| **Finance watcher** *(reads, never trades)* | | new | | | | bklog | | | | | new |
| **Multi-step research / report** | | | | | | | | | 08-02 | | |
| **No-API site actor** | ✓ | | ✓ | FORK | | | | | | ✓ | |
| **Priorities coach** *(0800 check-in)* | 10-03 | 10-02/10-06 | 10-02/10-06 | | 10-05 | 10-01 | ✓ | bklog | | ✓ | |

## Reading it

- **Recruiter responder is all-green** — the one already-built generated agent. It's the first
  *saturation data point*: mutating egress + event trigger + per-action approval compose with
  no new substrate.
- **eBay monitor** is the widest gap-opener right now (5 missing cells), which is why it's in
  flight — but note 4 of the 5 are its *own* backlog connectors/objects; only `Query` (09-02)
  is a generalisable substrate plan. That's the scope-gravity guard working.
- **Finance watcher** is the highest-*leverage* untried pick: its headline gap `NoMoney` forces
  the financial-action prohibition from a written norm into an *enforced* boundary — a trust-
  surface gap, which matters more to the thesis than any capability gap.
- **No-API site actor** is not a feature request, it's a `FORK`: decide whether the substrate
  supports the browser/personal-cookie egress class *at all* before any agent in that class.
- **Research/report** mostly validates already-planned `08-02` — a convergence pick, not a
  divergence one.
- **Priorities coach** (added 2026-07-06): a *generated* agent — the validation scenario is
  asking the elicitor for it and watching the pipeline deliver. Daily 0800 run reads the
  user's priorities doc, pings them on Google Chat asking whether yesterday's stated
  intentions happened, coaches, and writes the doc back to reflect current state. All
  coaching/diff logic is machine-written agent body (Constitution IX); the row records only
  the substrate grants the manifest projection would need and can't yet issue. It opens **three** open columns at once —
  `Rd` (first *live*-read connector: fetch the Drive doc), `OAuth` (Drive requires
  OAuth-with-refresh; the broker only holds static keys), and `Notif` (the Chat ping is the
  first notify-user channel — a Chat *incoming webhook* is a static per-space URL, so `Notif`
  lands on the existing static-key broker without waiting for `OAuth`). It is also the first
  *live* exercise of `Query` (daily doc snapshots + stated intentions in the store; "since
  yesterday" is a `store_find`) and of the `Evt` message trigger from a real external channel
  (the user's Chat reply). **Doc location — both are legitimate `Rd` connectors** (connectors
  execute substrate-side, so a local md / Obsidian-vault read is a trusted BEAM-side file
  read — no container bind-mount involved): a *local-file* connector is the cheap first
  live-read (no credential at all) but forces a **path-scoped grant shape** (manifest grants
  over filesystem paths, not API endpoints); a *Drive* connector costs more but opens
  `OAuth`. Stageable either way: v1 = webhook ping + doc diff via `Query`; v2 = doc
  read/write connector (local-file or Drive); v3 = inbound Chat reply as `Evt`.

## Connector backlog

The matrix's `Rd`/`Mut`/`Tool`/`Notif` columns are *primitive* status; this table is the
*concrete connector* status behind them, so the "which connectors do we still need" question
has one answer instead of being re-derived from cells. Adding a connector is dropping one
module under `lib/agent_os/connector/` (auto-discovered via the `AgentOS.Connector`
behaviour — no central registry to edit), so this is a tracking aid, **not** a list the code
reads.

**Status legend:** `live` = crosses the real boundary end-to-end · `wired` = registered and
gated, but the boundary call is stubbed/mocked/sink-routed (no live egress yet) · `stub` =
`execute/2` returns `{:error, :not_implemented}` · `needed` = no module yet, forced by a
candidate agent.

| Connector | Kind | Credential | Status | Forced by / notes |
|-----------|------|-----------|--------|-------------------|
| `store_find` | query read | none | **live** | 09-02; substrate state, real |
| `store_append` | query write | none | **live** | 09-02; substrate state, real |
| `kv_append` | state write | none | **live** | small-config KV; real (migrates to effect-return under 08-03 T1) |
| `web_search` | tool (read) | `:search_api_key` | **wired** | 08-02; returns canned text unless `web_search_mock_fn` set — no live HTTP yet |
| `external_send` | mutating egress | `:outbound_token` | **wired** | routes to `external_send_sink_pid` (test PID) or no-ops — no live send yet |
| `gmail_draft` | mutating egress | none decl. | **stub** | `:not_implemented`; recruiter responder (04-10) exercises it via stub |
| `gmail_read` | read egress | none decl. | **stub** | `:not_implemented`; this is the empty `Rd` slot the matrix points at |
| `drive_read` | read egress | OAuth (refresh) | **needed** | Priorities coach (`Rd`+`OAuth`); fetch the priorities doc |
| `drive_write` | mutating egress | OAuth (refresh) | **needed** | Priorities coach (`Mut`); write the doc back |
| `local_file_read` *(or `obsidian_read`)* | read egress | none | **needed** | Priorities-coach doc-location alt; cheapest live `Rd`, but forces a **path-scoped grant shape** |
| `discord_notify` | notify-user | static webhook URL | **needed** | Priorities coach (`Notif`); Discord incoming webhook — static per-channel URL, lands on the existing static-key broker. (Google Chat ruled out: webhooks/API need a Workspace account; operator is personal `@gmail.com`.) |
| *(finance read source)* | read egress | TBD | **needed** | Finance watcher; also forces `NoMoney` enforcement, not just a connector |

**Nearest-term to make `Rd` real:** exactly one of `gmail_read` (fill the existing stub),
`local_file_read` (no credential — cheapest, but new grant shape), or `drive_read` (drags in
`OAuth`). Any one closes the `Rd` column; the choice is really *which credential/grant story
you want to prove first*, not which connector is easiest to write.

## Saturation tracker

Not yet saturated. Known open columns: `Rd` (needs a first live-read connector), `OAuth`,
`Notif`, `Fbk`, `NoMoney`, and the `NoAPI` fork (`Query` and `Tool` closed by 09-02 / 08-02).
Add candidate agents as they're conceived; when new candidates stop opening columns, the
substrate is done.
