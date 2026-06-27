#!/usr/bin/env bash
#
# build_agent_os_map_v3_delta.sh
#
# DELTA on top of build_agent_os_map.sh. Adds the v3 synthesis pipeline that
# the original map missing: the orchestrator authoring a NOVEL agent, and the
# security-review component.
#
# What this delta adds:
#   - A new activity column: GENERATE (the orchestrator's own pipeline)
#       steps: elicit-spec / write-manifest / write-judge / write-agent /
#              security-review / deploy-on-green
#     all cards in the v3 release.
#   - The missing RUN-column v3 card: the OS synthesises the agent BODY
#     (the step the original map never reached).
#   - GATE-column v3 cards: validate machine-written CODE (not just manifest),
#     and the world-B / manifest-not-agent-readable commitments.
#   - OBSERVE: security-review verdict is visible in the inventory.
#
# It does NOT re-create releases/activities/steps the first script already made.
# It re-derives the IDs it needs from `usm show` so we don't hardcode hashes
# this script never generated.
#
# Run AFTER build_agent_os_map.sh, against the SAME file:
#   bash build_agent_os_map_v3_delta.sh agent_os.md
#
# ---------------------------------------------------------------------------
# Same ASSUMPTIONS as the parent script (correct here if your CLI differs):
#   - add commands echo the new element's {#hash}
#   - `usm show` prints elements with their {#hash} and [slug] inline
# ---------------------------------------------------------------------------

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
  if [[ -z "$id" ]]; then
    echo "FATAL: could not parse a {#hash} id from CLI output:" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi
  printf '%s' "$id"
}

add_activity() { extract_id "$(run add activity "$1" "$2")"; }
add_step()     { extract_id "$(run add step "$1" "$2" "$3")"; }
add_card()     { run add card "$1" "$2" "$3" >/dev/null; }

# --- re-derive existing IDs from `usm show` --------------------------------
# Finds the {#hash} on the line that contains a given [slug]. Errors if absent,
# which means the parent script didn't run (or used different slugs).
SHOW="$(cat "$FILE")"

id_for_slug() {
  local slug="$1" line id
  line="$(printf '%s\n' "$SHOW" | grep -F "[$slug]" | head -n1 || true)"
  if [[ -z "$line" ]]; then
    echo "FATAL: slug [$slug] not found in '$FILE'. Run build_agent_os_map.sh first." >&2
    exit 1
  fi
  id="$(printf '%s' "$line" | grep -oE '\{#[a-zA-Z0-9]+\}' | head -n1 | tr -d '{}#')"
  if [[ -z "$id" ]]; then
    echo "FATAL: no {#hash} on the line for [$slug]: $line" >&2
    exit 1
  fi
  printf '%s' "$id"
}

# Release id for v3: the show output lists releases in frontmatter as
# "- R4: v3 — Generation (MVP) {#hash}" (R-number may vary). Grab by name.
release_id_for() {
  local name="$1" line id
  line="$(printf '%s\n' "$SHOW" | grep -F "$name" | head -n1 || true)"
  if [[ -z "$line" ]]; then
    echo "FATAL: release matching '$name' not found." >&2; exit 1
  fi
  id="$(printf '%s' "$line" | grep -oE '\{#[a-zA-Z0-9]+\}' | head -n1 | tr -d '{}#')"
  printf '%s' "$id"
}

echo "[delta] re-deriving existing ids from $FILE" >&2
R3=$(release_id_for "Generation (MVP)")

# steps we need to hang new v3 cards on (created by the parent script)
S_HANDIN=$(id_for_slug "hand-input")     # RUN column
S_VALIDATE=$(id_for_slug "validate")     # GATE column
S_INVENTORY=$(id_for_slug "inventory")   # OBSERVE column

# ===========================================================================
# 1. The missing RUN card: the OS writes the agent BODY (novel code)
# ===========================================================================
echo "[delta] RUN: synthesise novel agent body" >&2
add_card "$S_HANDIN" "$R3" "OS synthesises a NOVEL agent body (new code, not template/compose) — the step the map never reached"

# ===========================================================================
# 2. New activity column: GENERATE (the orchestrator's own pipeline)
# ===========================================================================
echo "[delta] new activity: GENERATE" >&2
A_GEN=$(add_activity "Generate an agent from a stated purpose" "generate")

S_ELICIT=$(add_step   "$A_GEN" "Elicit the spec (question until KISS-clear)" "elicit-spec")
S_WMAN=$(add_step     "$A_GEN" "Write the manifest"                          "gen-manifest")
S_WJUDGE=$(add_step    "$A_GEN" "Write the judge (LLM-judged eval-lite)"      "write-judge")
S_WAGENT=$(add_step    "$A_GEN" "Write the novel agent"                       "write-agent")
S_SECREV=$(add_step    "$A_GEN" "Security review (reads code+manifest+purpose)" "security-review")
S_DEPLOY=$(add_step    "$A_GEN" "Deploy on green (judge AND security)"        "deploy-on-green")

# all GENERATE cards live in the v3 release
add_card "$S_ELICIT" "$R3" "Question the user until purpose is clear; minimise everything (KISS) — this is the real defence against spec-misread"
add_card "$S_WMAN"   "$R3" "Emit manifest from elicited spec; the human-readable manifest is THE safety artifact"
add_card "$S_WJUDGE" "$R3" "Synthesise tests; LLM-judged, non-deterministic; certifies code-matches-manifest, not manifest-matches-intent"
add_card "$S_WAGENT" "$R3" "Synthesise novel agent body (Python/PydanticAI across the port boundary)"
add_card "$S_SECREV" "$R3" "New agent: reads code+manifest+purpose, judges 'written to satisfy purpose without breaching manifest' — smoke detector, not firewall"
add_card "$S_DEPLOY" "$R3" "On pass from judge AND security review, deploy with no further human input — sound ONLY in world B"

# ===========================================================================
# 3. GATE cards specific to checking machine-written CODE + commitments
# ===========================================================================
echo "[delta] GATE: code-level checks + commitments" >&2
add_card "$S_VALIDATE" "$R3" "Gate must hold against machine-written CODE: post-deploy safety rests on the gate, not the security LLM's reading (world B)"
add_card "$S_VALIDATE" "$R3" "Manifest is NOT readable by the agent (privileged-read for the gate only) — agent can't hug a boundary it can't see"

# ===========================================================================
# 4. OBSERVE: make the security verdict legible in the inventory
# ===========================================================================
echo "[delta] OBSERVE: security-review verdict visible" >&2
add_card "$S_INVENTORY" "$R3" "Security-review verdict + judge result shown in the standing inventory (never 'ask the agent')"

echo >&2
echo "[delta] done. Rendering:" >&2
echo >&2
run show
