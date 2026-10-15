defmodule AgentOS.Connector.WebSearchTest do
  use ExUnit.Case, async: false

  alias AgentOS.Connector.WebSearch
  alias AgentOS.ProposedAction

  setup do
    prev_transport = Application.get_env(:agent_os, :web_search_transport)
    prev_mock = Application.get_env(:agent_os, :web_search_mock_fn)
    Application.delete_env(:agent_os, :web_search_mock_fn)

    on_exit(fn ->
      if prev_transport do
        Application.put_env(:agent_os, :web_search_transport, prev_transport)
      else
        Application.delete_env(:agent_os, :web_search_transport)
      end

      if prev_mock do
        Application.put_env(:agent_os, :web_search_mock_fn, prev_mock)
      else
        Application.delete_env(:agent_os, :web_search_mock_fn)
      end
    end)

    :ok
  end

  test "execute_tool/2 returns :missing_credential when secret is nil or blank" do
    assert {:error, :missing_credential} = WebSearch.execute_tool(%{"query" => "elixir"}, nil)
    assert {:error, :missing_credential} = WebSearch.execute_tool(%{"query" => "elixir"}, "   ")
  end

  test "execute_tool/2 sends Tavily POST request with query and api_key and formats results" do
    parent = self()

    Application.put_env(:agent_os, :web_search_transport, fn url, opts ->
      send(parent, {:tavily_request, url, opts})

      {:ok,
       %Req.Response{
         status: 200,
         body: %{
           "results" => [
             %{
               "title" => "Elixir Lang",
               "url" => "https://elixir-lang.org",
               "content" => "Dynamic, functional language."
             },
             %{
               "title" => "Hex.pm",
               "url" => "https://hex.pm",
               "content" => "Package manager for the BEAM."
             }
           ]
         }
       }}
    end)

    assert {:ok, formatted} =
             WebSearch.execute_tool(%{"query" => "elixir beam"}, "tvly-test-key-123")

    assert_receive {:tavily_request, "https://api.tavily.com/search", opts}
    assert Keyword.get(opts, :json) == %{
             api_key: "tvly-test-key-123",
             query: "elixir beam",
             max_results: 5
           }

    assert {"authorization", "Bearer tvly-test-key-123"} in Keyword.get(opts, :headers, [])

    assert formatted =~ "Search results for 'elixir beam':"
    assert formatted =~ "[1] Elixir Lang (https://elixir-lang.org): Dynamic, functional language."
    assert formatted =~ "[2] Hex.pm (https://hex.pm): Package manager for the BEAM."
  end

  test "execute_tool/2 handles empty results list" do
    Application.put_env(:agent_os, :web_search_transport, fn _url, _opts ->
      {:ok, %Req.Response{status: 200, body: %{"results" => []}}}
    end)

    assert {:ok, "Search results for 'obscure': no results found."} =
             WebSearch.execute_tool(%{"query" => "obscure"}, "tvly-key")
  end

  test "execute_tool/2 returns http_status error tuple on non-2xx response" do
    Application.put_env(:agent_os, :web_search_transport, fn _url, _opts ->
      {:ok, %Req.Response{status: 401, body: %{"detail" => "Invalid API key"}}}
    end)

    assert {:error, {:http_status, 401, %{"detail" => "Invalid API key"}}} =
             WebSearch.execute_tool(%{"query" => "elixir"}, "bad-key")
  end

  test "execute_tool/2 propagates transport errors" do
    Application.put_env(:agent_os, :web_search_transport, fn _url, _opts ->
      {:error, :timeout}
    end)

    assert {:error, :timeout} = WebSearch.execute_tool(%{"query" => "elixir"}, "tvly-key")
  end

  test "execute/2 delegates ProposedAction payload to execute_tool/2" do
    Application.put_env(:agent_os, :web_search_transport, fn _url, _opts ->
      {:ok,
       %Req.Response{
         status: 200,
         body: %{
           "results" => [
             %{"title" => "OTP 27", "url" => "https://erlang.org", "content" => "Released."}
           ]
         }
       }}
    end)

    action = %ProposedAction{
      type: "web_search",
      method: "search",
      payload: %{"query" => "otp 27"}
    }

    assert {:ok, result} = WebSearch.execute(action, "tvly-key")
    assert result =~ "Search results for 'otp 27':"
    assert result =~ "[1] OTP 27 (https://erlang.org): Released."
  end
end
