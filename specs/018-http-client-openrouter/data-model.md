# Data Model: HTTP Client & OpenRouter Transport

## Entities

### 1. Inference Request
Represents the request payload passed to `AgentOS.InferenceBroker.complete/2`.

- **Attributes**:
  - `run_token` (String): The token identifying the active agent execution run.
  - `model` (String): The destination model string (e.g. `google/gemini-2.5-flash`).
  - `messages` (List of Message maps): The message history. Each message maps to:
    - `role` (String): Either `"user"`, `"system"`, or `"assistant"`.
    - `content` (String): The message text.

---

### 2. OpenRouter Completion Request
The JSON payload POSTed to OpenRouter.

- **Attributes**:
  - `model` (String): The model identifier string.
  - `messages` (List of Message maps): The OpenAI-compatible messages array.

---

### 3. OpenRouter Completion Response
The expected response shape returned by OpenRouter's API on success.

- **Attributes**:
  - `choices` (List): An array of choice objects. Each choice contains:
    - `message` (Map): The model's response message:
      - `content` (String): The text completion.
  - `usage` (Map): The token usage statistics:
    - `prompt_tokens` (Integer): Count of input tokens.
    - `completion_tokens` (Integer): Count of output tokens.
