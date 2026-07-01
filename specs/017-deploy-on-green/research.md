# Research: Stage 6 Deploy-on-Green

## 1. Integration with Existing Verdict Stores

- **Decision**: Read verdicts from the `judge_results` and `security_review_results` state store collections by taking a snapshot of each store at deploy time.
- **Rationale**: The substrate already uses `StateStore.snapshot("judge_results")` and `StateStore.snapshot("security_review_results")` to fetch results in `AgentOS.Inventory.render/1`. Gating logic should query these same collections.
- **Alternatives considered**: Querying a database (rejected: the system uses Elixir term files via StateStore), querying the agent process (rejected: agents are transient, and the substrate owns lifecycle and state).

## 2. Code Hash Verification ("Stale Verdicts")

- **Decision**: 
  1. Modify `AgentOS.Pipeline.Stage5.Verdict` struct to add a `code_hash` field, and compute the hash of `code_files` during security-review run time to persist it.
  2. Compute and store the code hash in `judge_results` entries when `stage3_judge.ex` runs.
  3. At deploy time, compute the SHA-256 hash of the generated agent's current files on disk (`main.py` and `models.py`) and compare it against the hashes stored in the judge and security-review results.
  4. If either hash does not match the current code hash, or if a verdict is missing, fail deployment with a distinct reason (`:stale_verdict` or `:missing_verdict`).
- **Rationale**: This prevents a developer or pipeline from modifying the code after it has been judged or reviewed, ensuring the deployed agent exactly matches the reviewed code.
- **Alternatives considered**: Comparing file modification times (rejected: file timestamps are not deterministic or reliable across environments).

## 3. Manifest Invisibility Verification (World-B Verification)

- **Decision**: Re-verify that the manifest-not-readable-by-agent invariant still holds when the manifest is machine-written by running the existing `world_b_test.exs` verification suite, modifying a test to use a machine-written manifest.
- **Rationale**: Using the existing test suite guarantees we maintain identical safety guarantees without duplicating test logic.
- **Alternatives considered**: Authoring a new test suite (rejected: violates Simplicity First).
