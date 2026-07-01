# API Contract: OpenRouter Models Pricing API

This contract documents the public models HTTP API interface consumed by the `AgentOS.InferencePriceSync` service to sync token prices.

## Endpoint Reference

- **URL**: `https://openrouter.ai/api/v1/models`
- **Method**: `GET`
- **Headers**:
  - `Content-Type: application/json`
- **Authentication**: None required (public endpoint).

---

## Response Schema

### 1. Success (200 OK)
Returns a list of all models with their metadata and per-token pricing details.

```json
{
  "data": [
    {
      "id": "google/gemini-2.5-flash",
      "name": "Google: Gemini 2.5 Flash",
      "created": 1715644800,
      "description": "...",
      "context_length": 1048576,
      "architecture": {
        "modality": "text+image->text",
        "tokenizer": "Gemini",
        "instruct_type": "gemma"
      },
      "pricing": {
        "prompt": "0.000000075",
        "completion": "0.00000025",
        "request": "0.0",
        "image": "0.0"
      }
    }
  ]
}
```

### 2. Error Cases
Standard network errors or HTTP status code failures (e.g. 500, 502, 503, 504) are handled gracefully by logging the failure and falling back to the configured static fallback prices.
