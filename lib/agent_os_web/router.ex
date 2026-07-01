defmodule AgentOSWeb.Router do
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :put_root_layout, html: {AgentOSWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/", AgentOSWeb do
    pipe_through :browser

    live "/", ElicitationLive, :index
    live "/consent", ConsentLive, :index
  end
end
