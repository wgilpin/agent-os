# Exclude container/docker tests by default to keep the local suite hermetic.
# Run them explicitly via: mix test --include docker
ExUnit.start(exclude: [:docker])
