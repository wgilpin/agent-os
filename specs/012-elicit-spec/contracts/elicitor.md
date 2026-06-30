# Interface Contract: Elicitor Agent Port

This contract defines the communication protocol between the BEAM/OTP control plane (substrate) and the Python Elicitor Agent process running across the port boundary.

## 1. Execution Boundary

- **Command**: `python`
- **Arguments**: `["agents/elicitor/main.py"]`
- **Environment**: Needs `GEMINI_API_KEY` for LLM execution.
- **Process Isolation**: Invoked as a short-lived port process. It takes input on `stdin`, processes the step, outputs JSON to `stdout`, and exits immediately.

---

## 2. Input Protocol (stdin)

The control plane sends a JSON payload on `stdin` containing the full session history and the current spec draft (if any).

### Payload Schema
```json
{
  "session_id": "session-123",
  "original_purpose": "reply to recruiter emails",
  "transcript": [
    {
      "role": "user",
      "content": "I want an agent that replies to recruiter emails"
    },
    {
      "role": "assistant",
      "content": "Sure, which email service do you use? And do you want it to send the reply directly or save a draft?"
    },
    {
      "role": "user",
      "content": "I use Gmail, and it should just save a draft. No direct send."
    }
  ],
  "spec_draft": {
    "purpose": "reply to recruiter emails",
    "capabilities": [],
    "boundaries": {
      "egress_domains": [],
      "target_locations": []
    },
    "spend_limits": {
      "dollar_cap": 0.0,
      "token_limit": 0
    },
    "confirmed": false
  }
}
```

---

## 3. Output Protocol (stdout)

The Python process parses the input, interacts with the Gemini API to analyze intent/KISS-compliance, and writes a single JSON line to `stdout` before exiting.

### Payload Schema
```json
{
  "spec_draft": {
    "purpose": "reply to recruiter emails and save drafts",
    "capabilities": ["gmail_read", "gmail_draft"],
    "boundaries": {
      "egress_domains": ["gmail.googleapis.com"],
      "target_locations": []
    },
    "spend_limits": {
      "dollar_cap": 0.05,
      "token_limit": 100000
    },
    "confirmed": false
  },
  "next_question": "Do you want to restrict the replies to emails received in a specific folder, or matching specific keywords?",
  "scope_creep_detected": false,
  "pushback_message": ""
}
```

If the user tries to request an excessive capability, `scope_creep_detected` will be `true`, and the `pushback_message` explains the violation:

```json
{
  "spec_draft": {
    "purpose": "reply to recruiter emails and save drafts",
    "capabilities": ["gmail_read", "gmail_draft"],
    "boundaries": {
      "egress_domains": ["gmail.googleapis.com"],
      "target_locations": []
    },
    "spend_limits": {
      "dollar_cap": 0.05,
      "token_limit": 100000
    },
    "confirmed": false
  },
  "next_question": "Can we proceed with the current minimised configuration?",
  "scope_creep_detected": true,
  "pushback_message": "Warning: Deleting emails was requested, but is not needed to reply. We have excluded delete capability to keep permissions minimal."
}
```

---

## 4. Error Protocol (stderr)

- Any parsing errors, missing configuration (e.g. `GEMINI_API_KEY` missing), or LLM failure MUST write details to `stderr` and exit with a non-zero code.
- The control plane supervises the exit status and logs all `stderr` output to the system run log (Principle VI Loud Failures).
