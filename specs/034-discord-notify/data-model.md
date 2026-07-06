# Data Model: discord-notify

## Types

There are no new database schemas or persistent entities. The relevant data models are existing structs:
- `AgentOS.Connector.Grant`: Provided to `scope/1` and `execute/2`.
- `Req.Response`: The response from the POST request.

The request payload:
```json
{
  "content": "message text"
}
```
