# Data Model: File Connectors

## Entities

### `AgentOS.Manifest.Grant`
- **Fields**: Adds `path: String.t() | nil`
- **Description**: Bound by the author/substrate; strictly agent-invisible.

### `AgentOS.Connector.FileRead`
- **Behaviour**: `AgentOS.Connector`
- **Metadata**:
  - `mutating?`: false
  - `requires_deploy_consent?`: false
  - `requires_runtime_approval?`: false
  - `credential`: nil

### `AgentOS.Connector.FileWrite`
- **Behaviour**: `AgentOS.Connector`
- **Metadata**:
  - `mutating?`: true
  - `requires_deploy_consent?`: true
  - `requires_runtime_approval?`: false
  - `credential`: nil
