defmodule AgentOSWeb.Layouts do
  use Phoenix.Component

  import Plug.CSRFProtection, only: [get_csrf_token: 0]

  # Embed templates inside layouts/ subdirectory.
  embed_templates("layouts/*")
end
