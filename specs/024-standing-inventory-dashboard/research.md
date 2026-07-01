# Research: Standing Inventory Dashboard

## Deciding the Accessor Structure

To keep one derivation path feeding both the CLI text `render/1` and the LiveView, we need to extract a structured accessor `AgentOS.Inventory.data(opts)`.

### Current Design (`AgentOS.Inventory.render/1`)
Currently, `render/1` loads a manifest, fetches snapshot records, parses the last run, retrieves spend details, pending approvals, formats capabilities, and gets provenance and conformance information. All of this is formatted inside a multiline string.

### New Design (`AgentOS.Inventory.data/1`)
We will extract all the data fetching and computing logic into `AgentOS.Inventory.data(opts \\ [])`. It will return:
* `{:ok, data_map}` on success
* `{:error, reason}` if the manifest could not be loaded

The `data_map` will contain the following keys:
* `:agent_name` (string, e.g. `"discovery"`)
* `:purpose` (string)
* `:triggers` (list of strings/terms)
* `:mounts` (list of terms)
* `:owner` (string)
* `:supervision` (string)
* `:spend` - a map containing:
  * `:cap` (integer in micro-dollars)
  * `:window` (atom/string)
  * `:spent` (integer in micro-dollars)
* `:records_count` (integer)
* `:last_digest` (string)
* `:last_run` - a map containing:
  * `:status` (string/atom)
  * `:trigger` (string)
  * `:actions` (string/integer)
  * `:exit_code` (string/integer or nil)
  * `:failure_cause` (string or nil)
  * `:items_in` (string/integer)
  * `:items_dropped` (string/integer)
* `:provenance` (map or nil)
* `:conformance` (AgentOS.ConformanceAuditor.Verdict struct or nil)
* `:judge` (map or nil)
* `:security_review` (map or nil)
* `:pending_approvals` (list of maps containing `:ref`, `:action`, `:grant`)
* `:capabilities` (list of AgentOS.CapabilityRender.Entry structs)

### Formatting in `render/1`
`render/1` will simply call `data(opts)` and, if successful, format the returned map into the exact same string structure as before. If an error is returned, it will format the error string, preserving compatibility.

---

## Listing Agents Dynamically

We need to scan `manifests/*.md` to enumerate agents instead of hardcoding a single manifest path.
* We will use `Path.wildcard("manifests/*.md")` to find all manifests.
* For each manifest file, we extract the agent name using `Path.basename(path, ".md")`.
* In the LiveView, we will fetch the data for all agents by calling `AgentOS.Inventory.data(manifest_path: path, run_log_path: "data/run_log.md")` (or utilizing the defaults).

---

## UI and Polling Design

The LiveView will mount at `/inventory` and perform a timed poll using `Process.send_after/3`.
* Tick interval: 5 seconds.
* On each tick, the LiveView re-scans the manifests directory and re-fetches the structured inventory data for each agent.
* Visual layout:
  * A main grid containing agent cards.
  * Each card has three panels: Roster, Spend, and Audit Log.
  * Spend displays spent vs cap in dollars (e.g. `$0.000000 / $0.500000 per daily`).
  * If spend is near cap (>= 80%) or over cap, a high-visibility alert indicator (using standard CSS classes) is rendered.
  * Audit Log lists the run trail: recent `RunRecords` using `AgentOS.RunLog.read_records/2` (returning structured records), conformance verdict flags, and pending approvals.
