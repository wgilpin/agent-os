#!/usr/bin/env bash
#
# build_agent_os_map_v3_review_modes_delta.sh
#
# SECOND DELTA. Layers on top of:
#   1. build_agent_os_map.sh            (base map)
#   2. build_agent_os_map_v3_delta.sh   (v3 synthesis pipeline)
#
# Adds the review-modes + permission-visibility design:
#   - GENERATE column: the deploy step gains the three review modes and the
#     deterministic envelope predicate; permission visibility shown every mode.
#   - DECLARE column: the manifest carries the normie-readable capability
#     render (faithful, deterministic, danger-ranked).
#   - OBSERVE column: the 'reviewed: human | skipped-in-envelope' provenance
#     marker and the always-shown permission summary in the inventory.
#   - GATE column: restate that skip-review never crosses the gate.
#
# Run AFTER both prior scripts, against the SAME file:
#   bash build_agent_os_map_v3_review_modes_delta.sh agent_os.md
#
# Same CLI assumptions as the prior scripts (add echoes {#hash}; show prints
# {#hash} and [slug] inline). Fix extract_id/id_for_slug if your CLI differs.

set -euo pipefail

USM="${USM:-usm}"
FILE="${1:-agent_os.md}"
USM_FILE_FLAG=(-f "$FILE")

run() {
  echo "  \$ $USM ${USM_FILE_FLAG[*]} $*" >&2
  "$USM" "${USM_FILE_FLAG[@]}" "$@"
}

extract_id() {
  local out="$1" id
  id="$(printf '%s' "$out" | grep -oE '\{#[a-zA-Z0-9]+\}' | head -n1 | tr -d '{}#')"
  [[ -n "$id" ]] || { echo "FATAL: no {#hash} in output:" >&2; printf '%s\n' "$out" >&2; exit 1; }
  printf '%s' "$id"
}
add_step() { extract_id "$(run add step "$1" "$2" "$3")"; }
add_card() { run add card "$1" "$2" "$3" >/dev/null; }

SHOW="$(cat "$FILE")"

id_for_slug() {
  local slug="$1" line id
  line="$(printf '%s\n' "$SHOW" | grep -F "[$slug]" | head -n1 || true)"
  [[ -n "$line" ]] || { echo "FATAL: slug [$slug] not found. Run prior delta scripts first." >&2; exit 1; }
  id="$(printf '%s' "$line" | grep -oE '\{#[a-zA-Z0-9]+\}' | head -n1 | tr -d '{}#')"
  [[ -n "$id" ]] || { echo "FATAL: no {#hash} for [$slug]: $line" >&2; exit 1; }
  printf '%s' "$id"
}
release_id_for() {
  local name="$1" line
  line="$(printf '%s\n' "$SHOW" | grep -F "$name" | head -n1 || true)"
  [[ -n "$line" ]] || { echo "FATAL: release '$name' not found." >&2; exit 1; }
  printf '%s' "$line" | grep -oE '\{#[a-zA-Z0-9]+\}' | head -n1 | tr -d '{}#'
}

echo "[delta2] re-deriving ids" >&2
R3=$(release_id_for "Generation (MVP)")

# existing steps from prior scripts we attach cards to
S_DEPLOY=$(id_for_slug "deploy-on-green")     # GENERATE column (delta 1)
S_GMAN=$(id_for_slug "gen-manifest")          # GENERATE column (delta 1)
S_VALIDATE=$(id_for_slug "validate")          # GATE column (base)
S_INVENTORY=$(id_for_slug "inventory")        # OBSERVE column (base)
S_GRANT=$(id_for_slug "grant-caps")           # DECLARE column (base)

# ===========================================================================
# 1. GENERATE / deploy: the three modes + deterministic envelope
# ===========================================================================
echo "[delta2] GENERATE: review modes + envelope" >&2
add_card "$S_DEPLOY" "$R3" "Mode --always-review: every deploy blocks on a human (v3-LAUNCH DEFAULT; human does the SEMANTIC check, not security)"
add_card "$S_DEPLOY" "$R3" "Mode --review-if-risky: in-envelope (read-only/no-egress/spend<threshold) auto-deploys; out-of-envelope blocks"
add_card "$S_DEPLOY" "$R3" "Mode --dangerously-skip-review: out-of-envelope also auto-deploys (the only genuinely dangerous mode)"
add_card "$S_DEPLOY" "$R3" "Envelope is a DETERMINISTIC predicate over manifest fields — never an LLM judgement"
add_card "$S_DEPLOY" "$R3" "OPEN: should 'conformance auditor live & watching' be a precondition of envelope-eligibility? (leaning yes)"

# ===========================================================================
# 2. DECLARE: the normie-readable capability render
# ===========================================================================
echo "[delta2] DECLARE: normie-readable render" >&2
# Attached as cards on the existing grant-caps step (DECLARE column). If you'd
# prefer the readable render to be its own step under DECLARE, add it with:
#   A_DECLARE=$(id_for_slug "declare"); add_step "$A_DECLARE" "Readable capability render" "readable-caps"
add_card "$S_GRANT" "$R3" "Manifest carries a normie-readable capability render: <READ YOUR GMAIL>, <SEND EMAILS FROM YOUR GMAIL>"
add_card "$S_GRANT" "$R3" "Render is FAITHFUL+TOTAL (every capability appears; may collapse detail, never drop one)"
add_card "$S_GRANT" "$R3" "Render is DETERMINISTIC from manifest fields, never LLM-written (else co-generation misleads the consent screen)"
add_card "$S_GRANT" "$R3" "Render is DANGER-RANKED: read looks different from send/egress — the user sees WHY it left the envelope"

# ===========================================================================
# 3. OBSERVE: permission visibility always on + review provenance
# ===========================================================================
echo "[delta2] OBSERVE: visibility + provenance" >&2
add_card "$S_INVENTORY" "$R3" "Permission summary ALWAYS shown at deploy, every mode (display, not a decision) — legibility has no flag"
add_card "$S_INVENTORY" "$R3" "Inventory records provenance: reviewed = human | skipped-in-envelope | dangerously-skipped"

# ===========================================================================
# 4. GATE: skip-review never crosses the gate (the confirmed invariant)
# ===========================================================================
echo "[delta2] GATE: skip never crosses gate" >&2
add_card "$S_VALIDATE" "$R3" "INVARIANT: --dangerously-skip-review is deploy-review skip ONLY; the gate still enforces the manifest at runtime"

echo >&2
echo "[delta2] done. Rendering:" >&2
echo >&2
run show
