# Walkthrough: Stage 4 Write the Novel Agent Body (write-novel-agent)

Walkthrough and verification logs for the implementation of the novel agent body synthesis engine.

## Changes Made

1. **Novel Agent Body Synthesis Module**:
   - Path: [stage4_agent.ex](file:///Users/will/projects/agent_os/lib/agent_os/pipeline/stage4_agent.ex)
   - Functionality: Implements `AgentOS.Pipeline.Stage4.generate/3` to synthesise Python/PydanticAI agent code (`main.py` + `models.py`) from a confirmed purpose + Stage 2 manifest.
   - Enforced strict constraints: require_token guard, broker complete, file extraction/parse helpers, path-safety check (no `/` or `..`, must end in `.py`), typed-contract checks (requiring `BaseModel`, `stdin` read, stdout JSON print), manifest leak detection (check for cap, connector name, or credential formats), direct provider denylist (reject openai, etc.), and Python syntax AST check (`python3 -c`).
2. **Unit & Integration Tests**:
   - Path: [stage4_agent_test.exs](file:///Users/will/projects/agent_os/test/agent_os/pipeline/stage4_agent_test.exs)
   - Covered: happy path synthesis, two distinct purposes output checks, judge-blindness fixture validation, leak detection failures, direct provider denylist checks, and InferenceBroker error/breach fail-closed behaviors.
3. **Repository Settings**:
   - Path: [.gitignore](file:///Users/will/projects/agent_os/.gitignore)
   - Updated to ignore the new `judge_results` StateStore term files.

## Verification Results

### ExUnit Test Runs

All 17 new unit tests passed successfully:

```text
mix test test/agent_os/pipeline/stage4_agent_test.exs
Excluding tags: [:docker]

.......
23:56:55.306 [error] Inference failed: provider response missing usage information
....
23:56:55.354 [warning] Inference breach: agent 'recruiter_agent' spent (40000000) crossed cap (750000)
......
Finished in 0.4 seconds (0.00s async, 0.4s sync)

Result: 17 passed
```

Full test suite execution:
```text
mix test
Finished in 4.7 seconds (0.4s async, 4.3s sync)

Result: 208 passed, 6 excluded
```

### Formatter Checks

Ran `mix format` to guarantee syntactic cleanliness:
```bash
mix format
```
Completed with exit status 0 (no errors).
