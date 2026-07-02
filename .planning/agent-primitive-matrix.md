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
| `Query` | Long queryable history store (`store_find`/`store_append`) | ◐ planned **09-02** |
| `Fbk` | Cross-run feedback conditioning | ○ backlog (Phase 9 note) |
| `Tool` | Synchronous tool-use mid-reasoning (e.g. web_search) | ◐ planned **08-02** |
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

## Saturation tracker

Not yet saturated. Known open columns: `Rd` (needs a first live-read connector), `OAuth`,
`Notif`, `Query` (09-02), `Fbk`, `Tool` (08-02), `NoMoney`, and the `NoAPI` fork. Add candidate
agents as they're conceived; when new candidates stop opening columns, the substrate is done.
