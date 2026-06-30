# Quickstart: Manifest Projection

How to invoke and use the Stage 2 manifest projector programmatically.

## Usage

### 1. Projecting a Spec to a Manifest Struct

```elixir
# Load a confirmed elicited spec struct
spec = %AgentOS.ElicitedSpec{
  purpose: "watch and report recruiter emails",
  capabilities: ["gmail_read", "external_send"],
  boundaries: %{
    egress_domains: ["recruiter-inbox@example.com"],
    target_locations: []
  },
  spend_limits: %{dollar_cap: 0.10, token_limit: 0},
  confirmed: true
}

# Run the projection
{:ok, manifest} = AgentOS.Manifest.Projection.project(spec)
```

### 2. Serializing to YAML/Markdown

```elixir
# Convert the manifest to a YAML frontmatter markdown string
markdown_text = AgentOS.Manifest.Projection.serialize(manifest)

# Write to the destination path
AgentOS.Manifest.Projection.write(manifest, "manifests/my_agent.md")
```

### 3. Rendering the Consent View

```elixir
# Render the deterministic capability consent view
view_text = AgentOS.Manifest.Projection.consent_view(manifest)
IO.puts(view_text)
# Output:
# CAPABILITIES:
#   - READ INCOMING EMAILS FROM GMAIL
#   - [EXTERNAL] SEND MESSAGES OUT TO EXTERNAL RECIPIENTS (recipients: ["recruiter-inbox@example.com"], methods: ["send"])
```
