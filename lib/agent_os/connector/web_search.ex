defmodule AgentOS.Connector.WebSearch do
  @behaviour AgentOS.Connector

  alias AgentOS.ProposedAction
  alias AgentOS.Manifest.Grant

  @impl AgentOS.Connector
  def metadata do
    %{
      name: "web_search",
      mutating?: false,
      requires_approval?: false,
      credential: :search_api_key,
      cost: 1000,
      tool_declaration: %{
        "type" => "function",
        "function" => %{
          "name" => "web_search",
          "description" => "Search the web for queries synchronously.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "query" => %{
                "type" => "string",
                "description" => "The search query term."
              }
            },
            "required" => ["query"]
          }
        }
      }
    }
  end

  @impl AgentOS.Connector
  def scope(_boundaries) do
    %Grant{
      connector: "web_search",
      recipients: nil,
      methods: ["search"]
    }
  end

  @impl AgentOS.Connector
  def execute(%ProposedAction{} = action, secret) do
    execute_tool(action.payload, secret)
  end

  @impl AgentOS.Connector
  def execute_tool(arguments, secret) do
    query = Map.get(arguments, "query") || Map.get(arguments, :query) || ""

    case Application.get_env(:agent_os, :web_search_mock_fn) do
      mock_fn when is_function(mock_fn, 2) ->
        mock_fn.(query, secret)

      mock_fn when is_function(mock_fn, 1) ->
        mock_fn.(query)

      _ ->
        if is_nil(secret) or String.trim(secret) == "" do
          {:error, :missing_credential}
        else
          {:ok,
           "Search results for '#{query}': [1] Elixir 1.16 Released. [2] Erlang OTP 27 features."}
        end
    end
  end

  @impl AgentOS.Connector
  def render(_grant) do
    "SEARCH THE WEB FOR INFORMATION"
  end
end
