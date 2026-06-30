# Quickstart: Stage 1 Elicit Spec

This guide explains how to run and test the conversational elicitation flow for creating a novel agent specification.

## 1. Start Elicitation Session

To start a new elicitation session from the CLI:

```bash
mix agent_os.elicit "reply to recruiter emails"
```

This starts a local GenServer managing the session and boots the Elicitor Agent.

## 2. Interactive Loop

The terminal will prompt you for answers to clarifying questions:

```text
[Elicitor] I noticed you want to read email and respond. Which email provider/service do you use? (e.g. Gmail)
User > Gmail

[Elicitor] Great. Should the agent send emails directly or just save drafts?
User > Just save drafts, and delete recruiter emails.

[Elicitor] (KISS Check) Deleting emails is not necessary to reply. We have excluded 'gmail_delete' from the capability list to keep permissions minimal.
Next question: Do you confirm this minimised specification?
  - Purpose: reply to recruiter emails and save drafts
  - Capabilities: gmail_read, gmail_draft
  - Boundaries: egress to gmail.googleapis.com
  - Spend Cap: $0.05
Confirm? (yes/no)
User > yes
```

## 3. Outputs

On confirmation, the structured spec is written to disk:

- **Location**: `specs/012-elicit-spec/elicited_spec.json`
- **Output State**: `confirmed: true`

This JSON file is consumed by Stage 2 (`mix agent_os.gen_manifest`) to automatically author the manifest.
