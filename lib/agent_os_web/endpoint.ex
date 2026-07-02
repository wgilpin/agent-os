defmodule AgentOSWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :agent_os

  @session_options [
    store: :cookie,
    key: "_agent_os_key",
    signing_salt: "some_signing_salt_must_be_at_least_32_bytes_long_123456789"
  ]

  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]])

  # Serve static files from priv/static
  plug(Plug.Static,
    at: "/",
    from: :agent_os,
    gzip: false,
    only: ~w(assets fonts images favicon.ico robots.txt app.css app.js)
  )

  # Expose phoenix and live_view assets directly from dependencies
  plug(Plug.Static,
    at: "/phoenix",
    from: {:phoenix, "priv/static"},
    gzip: false
  )

  plug(Plug.Static,
    at: "/phoenix_live_view",
    from: {:phoenix_live_view, "priv/static"},
    gzip: false
  )

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Plug.Session, @session_options)
  plug(AgentOSWeb.Router)
end
