# Quickstart: Queryable State Store (Agent-Invisible Namespaces)

This guide shows how to configure and verify the queryable state store.

## 1. Manifest Configuration

In the agent's markdown manifest frontmatter, define a grant mapping a logical handle to a real namespace:

```yaml
grants:
  - connector: store_append
    handle: "feedback"
    namespace: "prod_agent_feedback_v2"
  - connector: store_find
    handle: "feedback"
    namespace: "prod_agent_feedback_v2"
```

The agent uses the logical handle `"feedback"` in its payload, never the real namespace name.

## 2. Example Query Action

An agent can query prior feedback records using a predicate:

```json
{
  "type": "store_find",
  "method": "feedback",
  "payload": {
    "predicates": [
      {"field": "score", "operator": ">=", "value": 4}
    ],
    "limit": 5,
    "order_by": "created_at",
    "order": "desc"
  }
}
```

The Gate matches this to the grant, resolves the namespace to `"prod_agent_feedback_v2"`, and retrieves matching records from `data/store/prod_agent_feedback_v2.db`.

## 3. Running Verification Tests

```bash
# Run the queryable store integration tests
mix test test/agent_os/queryable_store_test.exs
```
