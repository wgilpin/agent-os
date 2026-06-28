defmodule AgentOS.Manifest do
  @moduledoc """
  Parser for the hand-written, human-kept declarative manifest (the source of truth for
  what an agent is). A manifest is a markdown file with a YAML frontmatter block holding
  the seven core fields (CON-manifest-seven-fields): purpose, triggers, connectors,
  mounts, outputs, spend, owner/supervision.

  At v0 the manifest is intentionally human-readable and git-tracked (legibility).
  Manifest-not-agent-readable enforcement is a Phase 3/4 concern.
  """

  @doc """
  Loads and parses a manifest file.

  ## Parameters
    - `path`: The absolute or relative path to the markdown manifest file.

  ## Returns
    - `{:ok, parsed_yaml_map}` where keys are strings (from YamlElixir).
    - `{:error, reason}` if the file does not exist, cannot be read, or lacks frontmatter.
  """
  def load(path) do
    # File.read/1 returns {:ok, binary_content} or {:error, reason}
    case File.read(path) do
      {:error, reason} ->
        # Returns the error tuple directly, forwarding the file read error reason
        {:error, reason}

      {:ok, content} ->
        # Frontmatter delimiters are `---` on their own line, including the very first
        # line of the file — so anchor with multiline `^` rather than requiring a leading
        # newline. Split yields ["", <frontmatter>, <body>] when matched correctly.
        # ~r/.../m is the regex sigil with the multiline modifier 'm'.
        case String.split(content, ~r/^-{3,}\s*\n/m, parts: 3) do
          [_leading, frontmatter, _body] ->
            # YamlElixir parses the extracted frontmatter string into a map with string keys.
            YamlElixir.read_from_string(frontmatter)

          _ ->
            # Fallback when the regex split didn't yield exactly 3 parts (i.e. no frontmatter exists).
            {:error, :no_frontmatter}
        end
    end
  end
end
