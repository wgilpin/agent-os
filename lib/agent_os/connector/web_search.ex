defmodule AgentOS.Connector.WebSearch do
  @behaviour AgentOS.Connector

  alias AgentOS.ProposedAction
  alias AgentOS.Manifest.Grant

  @impl AgentOS.Connector
  def metadata do
    %{
      name: "web_search",
      mutating?: false,
      requires_deploy_consent?: false,
      requires_runtime_approval?: false,
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

  @tavily_search_url "https://api.tavily.com/search"

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
          perform_search(query, String.trim(secret))
        end
    end
  end

  defp perform_search(query, api_key) do
    transport_fn = Application.get_env(:agent_os, :web_search_transport, &Req.post/2)
    url = Application.get_env(:agent_os, :web_search_url, @tavily_search_url)

    opts = [
      json: %{
        api_key: api_key,
        query: query,
        max_results: 5
      },
      headers: [
        {"authorization", "Bearer #{api_key}"}
      ]
    ]

    case transport_fn.(url, opts) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, format_response(query, body)}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http_status, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp format_response(query, body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> format_response(query, decoded)
      _ -> "Search results for '#{query}': #{body}"
    end
  end

  defp format_response(query, %{} = body) do
    results = Map.get(body, "results") || Map.get(body, :results) || []

    case results do
      [_ | _] ->
        formatted =
          results
          |> Enum.with_index(1)
          |> Enum.map_join("\n", fn {item, idx} -> format_item(item, idx) end)

        "Search results for '#{query}':\n#{formatted}"

      _ ->
        "Search results for '#{query}': no results found."
    end
  end

  defp format_response(query, _other) do
    "Search results for '#{query}': no results found."
  end

  defp format_item(item, idx) when is_map(item) do
    title = Map.get(item, "title") || Map.get(item, :title) || "Untitled"
    url = Map.get(item, "url") || Map.get(item, :url)
    content = Map.get(item, "content") || Map.get(item, :content) || ""

    header =
      if is_binary(url) and url != "" do
        "[#{idx}] #{title} (#{url})"
      else
        "[#{idx}] #{title}"
      end

    if is_binary(content) and String.trim(content) != "" do
      "#{header}: #{String.trim(content)}"
    else
      header
    end
  end

  defp format_item(item, idx), do: "[#{idx}] #{inspect(item)}"

  @impl AgentOS.Connector
  def render(_grant) do
    "SEARCH THE WEB FOR INFORMATION"
  end
end
