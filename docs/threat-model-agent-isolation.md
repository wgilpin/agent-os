# Threat model: isolating machine-authored agents

**Status:** working note · **Date:** 2026-07-05 · **Scope:** the runtime boundary
around agent bodies the OS writes itself (Stage 4), and how it relates to the Gate
and to Stage 5 review.

## Why this note exists

The agents agent-os runs are **machine-authored**: Stage 4 synthesises an agent body,
and world-B is proven against "an agent the OS wrote itself"
(`specs/027-e2e-generation-thread/plan.md`). That single fact collapses a distinction
people usually lean on. For hand-written code you can separate a *buggy* agent (honest
mistake) from a *malicious* one (adversary) and pick a cheaper boundary for the former.
For generated code you can't:

- You can't audit a generated body the way you review a human PR.
- The generator is injectable. Prompt injection into Stage 3/4 can produce a body that
  is deliberately hostile, and at runtime a hostile body is indistinguishable from a
  merely-buggy one.

So the sandbox around a generated body must be sized for the adversarial case, because
you cannot know at runtime which case you have. This note records what each layer is
actually responsible for, so no layer gets quietly asked to do another's job.

## Three layers, three different jobs

Enforcement in agent-os is layered. The layers mitigate *different* failures and are not
substitutes for one another.

| Layer | Kind | Contains | Constitution |
|-------|------|----------|--------------|
| Stage 5 security review | Prevention (probabilistic) | Lowers the probability a bad body ever deploys | Smoke detector — "can only stop, never bypass" |
| The Gate | Authority mediation (deterministic) | What effects a deployed body can cause through the effector boundary | XI. Gate Is the Only Firewall · X. No Ambient Authority |
| The sandbox | Execution containment | Everything the Gate does **not** mediate — the mounted UDS, `RUN_TOKEN`, cross-tenant state, kernel | (isolation release, R2) |

Read as a funnel: review shrinks the top (fewer bad bodies reach deploy); the Gate
mediates authority (a deployed body still can't get grants it wasn't given —
world-B/BC-1…BC-7 proves this against a *machine-written* manifest); the sandbox
contains whatever a body does *below* the Gate. Residual risk is roughly the **product**
of the misses, so every layer helps — but only if each is sized for the others failing.

## The security-review agent is prevention, not a boundary

Reviewing generated code with an agent is genuine risk mitigation and belongs where the
constitution already puts it: a Stage 5 smoke detector in front of the Gate. It should
not be promoted — even implicitly — into the enforcement boundary, for three reasons its
misses are exactly the case the other layers exist for:

1. **Shared failure mode with the generator.** The reviewer is the same class of model,
   reachable by the same injected context. A generator that's been prompt-injected can
   emit a body shaped to pass review, and the poisoned context that steered generation
   can steer the reviewer too. Its misses *correlate* with the generator's hostile
   outputs — the worst possible correlation, and the reason it is not an independent
   check the way a hypervisor boundary is independent of the code it contains.

2. **Review sees source; the body acts at runtime.** Static review can't see behaviour
   decided at runtime — a data-dependent branch, a payload pulled from the inference
   response or from `item.text`, a dynamic import. Machine-authored bodies are exactly
   the kind of code that can defer the interesting behaviour past what is on the page.

3. **Nonzero, unquantified false-negative rate.** An agent reviewer won't cover every
   path and gives no bound on what it missed. The tail it misses is precisely when a
   hostile body executes — so the sandbox's strength must be sized for "review failed,"
   not "review usually works."

Net: review multiplies in another factor < 1 at the top of the funnel. It does not buy
down the isolation decision, because its failures land on exactly the hostile-body case
the isolation layer is there to contain.

## Container vs. VM: where the choice actually bites

The Gate governs **authority** — the effects routed through the effector boundary. The
sandbox governs **everything else**, and that is where a shared kernel is load-bearing
for agent-os specifically:

- The inference broker is reachable over a **mounted Unix domain socket**
  (`INFERENCE_SOCKET`), and **`RUN_TOKEN` sits in the agent's environment**
  (`agents/*/main.py`). A compromised body targets exactly those to go *under* the Gate
  rather than through it.
- The single-writer `StateStore` term-file and other tenants' state live on the host.

A container shares the host kernel, so its isolation boundary is the full kernel attack
surface; a kernel-escape CVE reaches the UDS, the token, and cross-tenant state. A VM's
boundary is a thin hypervisor. Because our bodies are machine-authored and the generator
is injectable, the buggy case is not cleanly separable from the hostile one, so the
execution sandbox must be treated adversarially — and for that a shared-kernel container
is the weak link.

This is *not* a crisis for agent-os only because the architecture already refused to make
the sandbox its security boundary: the Gate is the firewall (XI), authority is never
ambient (X), and enforcement precedes generation (XII). The sandbox choice therefore
governs confidentiality/integrity of the things *below* the Gate, not the authority
model itself.

### What containers still earn

Containers remain the right tool for **fault containment**, which is most of what a
merely-buggy body does — resource exhaustion (cgroups), filesystem blast radius (mount
namespace / read-only rootfs), stray network calls (network namespace), orphaned
processes (PID namespace; today handled by `priv/port_wrapper.sh`). "Never use
containers" is overstated for that. The argument for a VM is about the *tail* where the
body is hostile, not the common case where it is clumsy.

## Recommendations

1. **Keep the Gate as the firewall.** Correct regardless of container-vs-VM.
   Enforcement-precedes-generation is the right stance for machine-authored bodies.
2. **Keep Stage 5 review as prevention.** It earns its place at the top of the funnel;
   just don't let it buy down isolation.
3. **Treat the execution sandbox adversarially.** `priv/port_wrapper.sh` already runs a
   Docker container (`--cidfile`, `docker stop`/`kill`). Two upgrade paths:
   - **gVisor (`runsc`)** — a real kernel boundary at near-container ergonomics; close to
     a runtime swap that preserves the existing Docker lifecycle.
   - **Firecracker / Kata, one microVM per agent session** — the fuller hypervisor
     boundary; warranted here given machine-authored bodies.
4. **Shrink what the sandbox has to protect.** Scope `RUN_TOKEN` per run to a single
   inference call, and forward only the one broker socket (vsock, under a microVM) rather
   than mounting host paths — so even a sandbox escape yields little.

## Status update (2026-07-11): generated agents are now sandboxed (spec 044 / 11-01)

The acute gap this note described — generated agent bodies running *outside* any sandbox,
as a bare `.venv/bin/python` child of the BEAM at the operator's macOS user — is closed.
`run_worker` no longer has a direct host-interpreter dispatch branch: config and generated
agents share the one `Sandbox.build_argv` path (network none, read-only root, cap-drop ALL,
non-root, memory/pids limits), differing only in image and mounts. A generated body runs
the generic `agent-generated:dev` image with its code bind-mounted **read-only** at
`/app/agents/<name>`; the inference UDS remains the sole writable host-backed mount. A
world-B-style containment probe (`test/agent_os/generated_containment_test.exs`) proves a
hostile body cannot read host files outside its mounts, open outbound connections, or write
outside `/scratch`, and every dispatch failure (missing image, unavailable daemon,
unmountable code) fails loudly with a diagnosable cause rather than falling back to a host run.

Still open follow-ups (later Phase 11 plans): the pluggable runtime knob (`runc`/`runsc`,
11-03), the Apple Containers per-agent-VM backend with a vsock broker channel (11-04), and
the standing operator task to trim Docker Desktop file sharing to just the inference-UDS
directory and agent code mounts (11-02).

## One-line summary

The instinct that "a container mitigates a buggy agent" is true, and containers earn
their place for fault containment — but because our agents are machine-authored and the
generator is injectable, the buggy case isn't separable from the hostile one, so the
execution sandbox must be sized for an adversary (VM-class), while the Gate — not the
sandbox, and not the reviewer — remains the security boundary.
