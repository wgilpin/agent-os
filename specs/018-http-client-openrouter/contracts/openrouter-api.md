# API Contract: OpenRouter Chat Completions

This contract documents the HTTP API interface consumed by the `AgentOS.InferenceBroker`.

## Endpoint Reference

- **URL**: `https://openrouter.ai/api/v1/chat/completions`
- **Method**: `POST`
- **Headers**:
  - `Authorization: Bearer <API_KEY>`
  - `Content-Type: application/json`

---

## Request Schema

```json
{
  "model": "google/gemini-2.5-flash",
  "messages": [
    {
      "role": "user",
      "content": "Write a 3-word slogan."
    }
  ]
}
```

---

## Response Schema

### 1. Success (200 OK)

```json
{
  "id": "gen-...",
  "object": "chat.completion",
  "created": 1719840212,
  "model": "google/gemini-2.5-flash",
  "choices": [
    {
      "message": {
        "role": "assistant",
        "content": "Think, Build, Scale."
      },
      "finish_reason": "stop"
    }
  ],
  "usage": {
    "prompt_tokens": 12,
    "completion_tokens": 6,
    "total_tokens": 18
  }
}
```

### 2. Error Cases

Non-200 responses return standard HTTP error status codes (e.g. 401, 429, 500) and may contain error details in the JSON body:

```json
{
  "error": {
    "message": "Invalid API key",
    "code": 401
  }
}
```
