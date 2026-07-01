# UI Contract: Consent Screen UI

The `AgentOSWeb.ConsentLive` LiveView exposes endpoints and handles interaction events to transition the deployment approval state.

## 1. HTTP Endpoint (Mount)

- **Path**: `/consent`
- **Method**: `GET`
- **Query Parameters**:
  - `manifest` (required): Project-relative path to the agent manifest file (e.g. `manifests/discovery.md`).

### Response States

- **200 OK (Pending State)**:
  - Rendered when a valid manifest is loaded and no action has been clicked yet.
  - Includes explicit **Approve** and **Reject** controls.
- **200 OK (Error State)**:
  - Rendered when `AgentOS.Manifest.load/1` fails or `AgentOS.CapabilityRender.entries/1` raises an exception.
  - The exact exception/error message is rendered on the screen.
- **200 OK (Approved State)**:
  - Rendered after the user clicks **Approve**.
  - Displays a confirmation message.
- **200 OK (Rejected State)**:
  - Rendered after the user clicks **Reject**.
  - Displays a rejection confirmation message.

---

## 2. Interaction Events

### Approve Action
- **Event**: `phx-click="approve"`
- **Preconditions**:
  - `socket.assigns.status == :pending`
- **Behavior**:
  1. Record provenance status as `:reviewed_human` with the manifest hash.
  2. If `ref` is present, submit `{:approval, :approve, ref}` to `TriggerGateway`.
  3. Set `socket.assigns.status` to `:approved`.

### Reject Action
- **Event**: `phx-click="reject"`
- **Preconditions**:
  - `socket.assigns.status == :pending`
- **Behavior**:
  1. If `ref` is present, submit `{:approval, :deny, ref}` to `TriggerGateway`.
  2. Set `socket.assigns.status` to `:rejected`.
