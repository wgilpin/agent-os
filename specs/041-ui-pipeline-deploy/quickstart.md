# Quickstart: Manual Browser Walkthrough

UI flows are verified by manual walkthrough, not unit tests (Constitution III /
FR-012). Backend behavior (registry, gating, re-arming, events) is covered by ExUnit.

## Prerequisites

```bash
mix deps.get
mix phx.server        # UI at http://localhost:4000
```

Model credentials must be configured (real pipeline runs call providers; the test
suite never does).

## Walkthrough 1 — Confirmed spec → pipeline → consent-gated deploy (US1 + US2)

1. Open `http://localhost:4000/` (ElicitationLive). Enter a one-sentence purpose and
   drive the elicitation conversation to a confirmed spec.
2. Confirm the spec. **Expect**: a "Start pipeline" card with a review-mode select —
   default is the consent-gated mode (`always_review`); `dangerously_skip_review` is
   visible but NOT preselected.
3. Click Start. **Expect**: the page stays responsive; a stage-progress panel advances
   through manifest → classify → synthesis → judge → security review → deploy, showing
   verdicts as they land.
4. Mid-run, refresh the browser. **Expect**: the progress view rebuilds to the true
   current state within one update cycle (SC-005) and keeps updating live.
5. With passing verdicts in `always_review` mode. **Expect**: terminal state
   "blocked pending consent" with a link to the consent screen.
6. Follow the link (`/consent?manifest=manifests/<agent>.md`). **Expect**: requested
   grants listed by danger tier. Click **Approve**. **Expect**: approval banner;
   deployment completes via the approval-resume path.
7. Open `/inventory`. **Expect**: the agent shows as **deployed (active)** — state
   comes from the deployment registry, and the update appears without waiting for the
   5s poll (PubSub).
8. Re-run a pipeline and **Deny** at the consent screen. **Expect**: agent absent from
   the registry / not deployed; denial recorded in the run log; the pipeline can be
   re-run later without manual cleanup.

## Walkthrough 2 — Durable deployment across a power cycle (US3)

1. With at least one agent deployed (Walkthrough 1), stop the server (Ctrl-C twice).
2. Restart `mix phx.server`. **Expect**: `/inventory` still lists the agent as
   deployed; its declared triggers are re-armed from its manifest at boot (log lines
   from trigger arming), with NO manual step and NO catch-up firing of missed windows.
3. Negative check: place a manifest file in `manifests/` that was never deployed, then
   send its event/message trigger. **Expect**: no run starts; a warning log records
   the refusal.
4. Edge: delete a deployed agent's manifest file and restart. **Expect**: boot
   completes (no crash); a loud error log names the agent and missing path; inventory
   shows it inactive.

## Walkthrough 3 — Test-fire from the inventory (US4)

1. On `/inventory`, find a **deployed** agent whose manifest declares a **message**
   trigger. **Expect**: a payload input + fire affordance on its card.
2. Enter a test payload and fire. **Expect**: a run starts through the normal
   trigger→run path; its outcome and action tally appear in the card's run log.
3. Check an undeployed agent or one without a message trigger. **Expect**: no active
   fire affordance.

## Pending consent survives restart (US2 AS-4)

1. Park a deployment (terminal state blocked-pending-consent), then restart the
   server before acting.
2. **Expect**: the pending approval is still visible and can be approved (completing
   deployment + registry record) or denied.
