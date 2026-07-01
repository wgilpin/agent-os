# Data Views & Validation: Consent Screen UI

## LiveView Assigns Schema
The `AgentOSWeb.ConsentLive` module maintains the following socket assigns representing the UI state:

| Key | Type | Description |
|-----|------|-------------|
| `manifest_path` | `String.t() \| nil` | The filesystem path of the loaded manifest. |
| `agent_name` | `String.t() \| nil` | Derived agent identifier (basename of manifest). |
| `manifest` | `%AgentOS.Manifest{} \| nil` | Parsed manifest struct. |
| `entries` | `[%AgentOS.CapabilityRender.Entry{}] \| nil` | Ordered capability entries. |
| `spend` | `%AgentOS.Manifest.Spend{} \| nil` | Spend limits section of the manifest. |
| `ref` | `String.t() \| nil` | The matching reference in `pending_approvals`. |
| `status` | `:pending \| :approved \| :rejected \| :error` | The current approval state. |
| `error_message` | `String.t() \| nil` | Surfaces registry or parse error messages. |
| `manifest_hash` | `String.t() \| nil` | The hex-encoded SHA-256 hash of the manifest file. |

## Validation & Verification Rules

1. **Manifest Existence & Format Validation**:
   - The manifest path must be loaded via `AgentOS.Manifest.load/1`.
   - If the file is missing or contains invalid YAML structure, `Manifest.load/1` returns `{:error, reason}`, and the LiveView sets `status` to `:error` and `error_message` to the parsed failure reason.

2. **Capability Registry Lookup Validation**:
   - Connector lookup is performed deterministically by `AgentOS.CapabilityRender.entries/1`.
   - If any connector is not registered in the substrate registry, it raises a `RuntimeError` containing the string `"missing from the capability registry"`. The LiveView rescues this error and displays it.

3. **Pending Approval Linkage**:
   - An approval is matching if its `action.method` matches `manifest_path`.
   - If found, `ref` is bound to the corresponding approval reference.

4. **Provenance State Recording**:
   - On approval, the provenance StateStore is updated under the key `agent_name` using `AgentOS.Provisioner.record_provenance/3`.
   - The status is recorded as `:reviewed_human` along with the SHA-256 hash of the manifest.
