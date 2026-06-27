#!/usr/bin/env bash
#
# build_agent_os_map.sh
#
# Drives the `usm` CLI to construct the Agent OS user story map.
#
# Map shape:
#   Activities (columns)  = the 7 operator activities (DECLARE..SUPERVISE)
#   Steps (task rows)     = the tasks under each activity
#   Cards (cell contents) = the v0..v3 release-row entries, placed at the
#                           (step, release) intersection.
#
# Each card lives in exactly ONE (step, release) cell — matching
# `usm add card <step_id> <release_id> <name>`. Where my map showed an
# em-dash ("unchanged / already satisfied"), no card is added.
#
# ---------------------------------------------------------------------------
# ASSUMPTIONS (correct these here if the CLI differs — they are the only guesses)
# ---------------------------------------------------------------------------
#   1. Sub-commands & arg order are exactly as `usm` usage prints:
#        usm add release  <name>
#        usm add activity <name> <slug>
#        usm add step     <activity_id> <name> <slug>
#        usm add card     <step_id> <release_id> <name>
#   2. A create command echoes the new element's machine id as "{#hash}"
#      somewhere in stdout. extract_id() parses that. If your CLI prints
#      ids another way, fix extract_id() ONLY.
#   3. -f/--file selects the target db file. We pass it on every call.
#
# Per AGENTS.md rule 1 this script performs NO raw markdown edits — every
# mutation goes through the CLI so slugs cascade and hashes stay intact.
# ---------------------------------------------------------------------------

set -euo pipefail

# --- config ----------------------------------------------------------------
USM="${USM:-usm}"                      # CLI binary (override: USM=./usm ...)
FILE="${1:-agent_os.md}"               # target db file (arg 1, default agent_os.md)
USM_FILE_FLAG=(-f "$FILE")

# --- helpers ---------------------------------------------------------------

# Run a usm command, echo it for traceability, return its stdout.
run() {
  echo "  \$ $USM ${USM_FILE_FLAG[*]} $*" >&2
  "$USM" "${USM_FILE_FLAG[@]}" "$@"
}

# Extract the first {#hash} machine id from text. Errors loudly if none.
extract_id() {
  local out="$1" id
  id="$(printf '%s' "$out" | grep -oE '\{#[a-zA-Z0-9]+\}' | head -n1 | tr -d '{}#')"
  if [[ -z "$id" ]]; then
    echo "FATAL: could not parse a {#hash} machine id from CLI output:" >&2
    printf '%s\n' "$out" >&2
    echo "Fix extract_id() to match your CLI's id-printing format." >&2
    exit 1
  fi
  printf '%s' "$id"
}

add_release()  { extract_id "$(run add release "$1")"; }
add_activity() { extract_id "$(run add activity "$1" "$2")"; }
add_step()     { extract_id "$(run add step "$1" "$2" "$3")"; }
add_card()     { run add card "$1" "$2" "$3" >/dev/null; }

echo "Building Agent OS story map in: $FILE" >&2
echo >&2

# ===========================================================================
# 1. RELEASES (v0..v3)  — order = top-to-bottom row order
# ===========================================================================
echo "[releases]" >&2
R0=$(add_release "v0 — Walking skeleton")
R1=$(add_release "v1 — Isolation")
R2=$(add_release "v2 — Manifest enforcement")
R3=$(add_release "v3 — Generation (MVP)")

# ===========================================================================
# 2. ACTIVITIES (columns) + their STEPS (task rows)
#    Steps are added immediately under each activity so slugs scope cleanly.
# ===========================================================================

# --- DECLARE ---------------------------------------------------------------
echo "[activity: declare]" >&2
A_DECLARE=$(add_activity "Declare an agent" "declare")
S_WRITE=$(add_step   "$A_DECLARE" "Write a manifest"          "write-manifest")
S_PURPOSE=$(add_step "$A_DECLARE" "State purpose"             "state-purpose")
S_GRANT=$(add_step   "$A_DECLARE" "Grant connectors & mounts" "grant-caps")
S_SPEND=$(add_step   "$A_DECLARE" "Set spend cap"             "set-spend")

# --- PROVISION -------------------------------------------------------------
echo "[activity: provision]" >&2
A_PROV=$(add_activity "Provision it from the declaration" "provision")
S_INSTANTIATE=$(add_step "$A_PROV" "Instantiate from declaration" "instantiate")
S_MOUNT=$(add_step       "$A_PROV" "Mount state"                  "mount-state")
S_WIRE=$(add_step        "$A_PROV" "Wire credentials"            "wire-creds")

# --- TRIGGER ---------------------------------------------------------------
echo "[activity: trigger]" >&2
A_TRIG=$(add_activity "Trigger it into motion" "trigger")
S_CLOCK=$(add_step   "$A_TRIG" "Wake on clock (time)"            "trig-time")
S_EVENT=$(add_step   "$A_TRIG" "Wake on event (world)"           "trig-event")
S_MSG=$(add_step     "$A_TRIG" "Wake on message / approval"      "trig-message")

# --- RUN -------------------------------------------------------------------
echo "[activity: run]" >&2
A_RUN=$(add_activity "Run it (LLM does the work)" "run")
S_HANDIN=$(add_step  "$A_RUN" "Hand input to Python agent"   "hand-input")
S_REASON=$(add_step  "$A_RUN" "Reason over sanitized input"  "reason")
S_PROPOSE=$(add_step "$A_RUN" "Propose enumerated actions"   "propose")

# --- GATE ------------------------------------------------------------------
echo "[activity: gate]" >&2
A_GATE=$(add_activity "Gate its outputs before effect" "gate")
S_VALIDATE=$(add_step "$A_GATE" "Validate action vs grants" "validate")
S_INJECT=$(add_step   "$A_GATE" "Inject credential"         "inject-cred")
S_METER=$(add_step    "$A_GATE" "Meter spend"               "meter-spend")
S_ACT=$(add_step      "$A_GATE" "Act on agent's behalf"     "act")

# --- OBSERVE ---------------------------------------------------------------
echo "[activity: observe]" >&2
A_OBS=$(add_activity "Observe what exists & what it did" "observe")
S_INVENTORY=$(add_step "$A_OBS" "List what exists"          "inventory")
S_TRACE=$(add_step     "$A_OBS" "Read run-trace"            "run-trace")
S_SEESPEND=$(add_step  "$A_OBS" "See spend"                 "see-spend")
S_CONFORM=$(add_step   "$A_OBS" "Check conformance"         "conformance")

# --- SUPERVISE -------------------------------------------------------------
echo "[activity: supervise]" >&2
A_SUP=$(add_activity "Supervise its lifecycle & failures" "supervise")
S_RESTART=$(add_step "$A_SUP" "Restart policy"            "restart")
S_KILL=$(add_step    "$A_SUP" "Kill on breach"           "kill-breach")
S_CRASH=$(add_step   "$A_SUP" "Surface child crash"      "child-crash")

# ===========================================================================
# 3. CARDS — placed at (step, release). Earliest release only; no forward dupes.
# ===========================================================================
echo "[cards]" >&2

# --- DECLARE ---------------------------------------------------------------
add_card "$S_WRITE"   "$R0" "Hand-write a markdown manifest, human-kept-in-sync"
add_card "$S_WRITE"   "$R2" "Manifest gains boundary-contract fields (recipient scoping, on_breach, approval-as-event)"
add_card "$S_PURPOSE" "$R0" "Purpose stated as a one-line contract"
add_card "$S_PURPOSE" "$R3" "Declare a purpose; OS emits the manifest"
add_card "$S_GRANT"   "$R0" "Connectors & mounts listed by hand"
add_card "$S_SPEND"   "$R0" "Spend cap as a number (no on_breach yet)"
add_card "$S_SPEND"   "$R2" "Spend becomes {cap, window, on_breach}"

# --- PROVISION -------------------------------------------------------------
add_card "$S_INSTANTIATE" "$R0" "Hard-wired config (not provisioned from manifest)"
add_card "$S_INSTANTIATE" "$R1" "Provision agent into a container"
add_card "$S_INSTANTIATE" "$R2" "Substrate provisions from the enforced manifest"
add_card "$S_INSTANTIATE" "$R3" "OS composes/selects template, validates generated manifest is well-formed & minimally-scoped"
add_card "$S_MOUNT"       "$R0" "Roster/trust state mounted to single-writer GenServer"
add_card "$S_WIRE"        "$R2" "Credential proxy holds caps, injects at request time"

# --- TRIGGER ---------------------------------------------------------------
add_card "$S_CLOCK" "$R0" "One timer (daily 07:00 emergence signal)"
add_card "$S_EVENT" "$R2" "Event-trigger + approval-as-event-trigger"
add_card "$S_MSG"   "$R2" "Message-trigger (you, via chat, are another process)"

# --- RUN -------------------------------------------------------------------
add_card "$S_HANDIN"  "$R0" "One port → human-written Python discovery agent"
add_card "$S_HANDIN"  "$R1" "Agent runs sandboxed; safe against injected bookmark/tweet"
add_card "$S_REASON"  "$R0" "LLM reasons over input (unsanitized at v0)"
add_card "$S_REASON"  "$R1" "Reasons over sanitized untrusted web input"
add_card "$S_PROPOSE" "$R0" "Proposes enumerated actions"

# --- GATE ------------------------------------------------------------------
add_card "$S_VALIDATE" "$R0" "Minimal output check (not enforcement)"
add_card "$S_VALIDATE" "$R2" "Deterministic gate: every action validated vs enumerated grants + constraints"
add_card "$S_VALIDATE" "$R3" "Gate now checks a machine-written manifest (new trust posture)"
add_card "$S_INJECT"   "$R2" "Credential proxy injects at the chokepoint"
add_card "$S_METER"    "$R2" "Spend metered at the deterministic chokepoint"
add_card "$S_ACT"      "$R0" "Privileged action on agent's behalf (deterministic)"

# --- OBSERVE ---------------------------------------------------------------
add_card "$S_INVENTORY" "$R0" "Standing inventory of what exists"
add_card "$S_TRACE"     "$R0" "A legible run-log"
add_card "$S_SEESPEND"  "$R2" "Per-agent spend visible from the chokepoint"
add_card "$S_CONFORM"   "$R3" "Conformance auditor: stated purpose vs observed behaviour, flag-only"

# --- SUPERVISE -------------------------------------------------------------
add_card "$S_RESTART" "$R0" "Restart-once-and-alert policy"
add_card "$S_KILL"    "$R2" "Spend-cap-on-breach becomes a real kill"
add_card "$S_CRASH"   "$R1" "Child OOM/crash surfaces as clean BEAM exit"
add_card "$S_CONFORM" "$R3" "Auditor flags drift to human; human stays on approve-path"

echo >&2
echo "Done. Rendering map:" >&2
echo >&2
run show
