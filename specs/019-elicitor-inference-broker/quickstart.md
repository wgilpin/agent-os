# Quickstart: Run Elicitation with Centralized Inference

To run specifications elicitation interactively:

1. Ensure the `MODEL_KEY` environment variable is set for the substrate (it is the sole holder of the credentials):
   ```bash
   export MODEL_KEY="sk-or-v1-..."
   ```

2. Start the elicitation CLI task (this will spin up the `InferenceBroker` and socket, then run the interactive elicitation):
   ```bash
   mix agent_os.elicit "reply to recruiter emails"
   ```

3. The elicitation spend can be checked in the spend ledger:
   ```elixir
   AgentOS.StateStore.snapshot("spend_ledger")
   ```
