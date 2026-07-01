# Data Model & Component Contracts: Secure Secret Provisioning

## Key Components & Data Structures

### 1. `CredentialSource` (Dynamic Resolver)
A stateless module responsible for reading, parsing, and validating environment credentials.

- **Inputs**:
  - The OS Environment (`System.get_env/1`)
  - Optional `.env` file in project root
- **Outputs**:
  - A map containing valid credentials:
    ```elixir
    %{
      optional(atom()) => String.t()
    }
    ```
- **Validation Rules**:
  - String values must be trimmed.
  - If a value is `nil`, `""`, or contains only whitespace characters, it is discarded and excluded from the output map.

---

### 2. `CredentialProxy` (In-Memory GenServer State)
A stateful GenServer that holds the resolved credentials in memory during application runtime.

- **State Structure**:
  - Map of valid credentials, keyed by atom IDs:
    ```elixir
    %{
      model_key: String.t(),
      outbound_token: String.t()
    }
    ```
- **Invariants**:
  - Starts Link on application boot.
  - State is strictly private; secrets are never logged, persisted, or returned to callers.
  - Closure execution is run inside the caller process.
