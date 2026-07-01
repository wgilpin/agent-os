# Data Model: LiveView State & Assigns

The LiveView process maintains the state of the interactive elicitation workspace in its socket assigns.

## Socket Assigns Schema

| Assign Key | Type | Description |
|---|---|---|
| `session_pid` | `pid()` \| `nil` | The process identifier of the running `AgentOS.ElicitationSession` GenServer. |
| `session` | `%AgentOS.ConversationSession{}` \| `nil` | The conversation history, draft spec, and status synced from the session GenServer. |
| `creep_warning` | `String.t()` \| `nil` | The pushback message if scope creep is detected, or `nil` if not. |
| `show_confirm` | `boolean()` | If `true`, renders the spec confirmation/refinement card instead of the message input. |
| `success_message` | `String.t()` \| `nil` | A success indicator shown after the specification is written to disk. |

---

## State Transitions

```mermaid
state_id: StateDiagram
state "Landing State" as Landing
state "Conversation Loop" as Loop
state "Scope Creep Alert" as Alert
state "Confirmation Card" as Confirm
state "Specification Written" as Success

[*] --> Landing : Page Load (session_pid: nil)
Landing --> Loop : Submit initial purpose\n(start_link/1 -> session_pid set)
Loop --> Alert : submit_message/2\nreturns creep=true
Alert --> Loop : submit_message/2\nreturns creep=false (dismisses warning)
Loop --> Confirm : Elicitor finishes\n(status: :confirmed or empty question)
Confirm --> Success : Click "Confirm"\n(write_spec/2 -> GenServer stopped)
Confirm --> Loop : Click "Refine"\n(show_confirm: false)
Success --> [*] : Done
```
