# Quickstart: Interactive Elicitation UI

Follow these instructions to start, verify, and run tests for the Phoenix/LiveView web interface.

## 1. Installation

Add the required dependencies to `mix.exs`:
```elixir
{:phoenix, "~> 1.7.10"},
{:phoenix_live_view, "~> 0.20.2"},
{:phoenix_html, "~> 4.0"},
{:plug_cowboy, "~> 2.6"}
```

Get dependencies:
```bash
mix deps.get
```

---

## 2. Running Locally

Start the interactive development shell with the web server active:
```bash
iex -S mix
```

Once running, navigate to:
```text
http://localhost:4000/
```

---

## 3. Manual Verification Steps

1. **Start Elicitation**: On the landing state, enter a purpose:
   `"Watch customer reviews on Shopify and send a summary every Monday."`
2. **Submit turn**: Check that the screen splits into chat on the left and Live Spec sidebar on the right.
3. **Conversational turn**: Answer the question presented by the elicitor. Watch the Live Spec update.
4. **Creep Warning**: Enter a broad scope change (e.g. `"I also want it to purchase items automatically and post on Twitter"`) and assert the Kiss Check warning banner appears.
5. **Confirm Spec**: When the conversation completes, assert the Confirmation Card is shown. Click "Confirm" and check that:
   - Success message is displayed.
   - `specs/012-elicit-spec/elicited_spec.json` is created or updated.

---

## 4. Run Automated Tests

To run the integration tests:
```bash
mix test test/agent_os_web/elicitation_live_test.exs
```
