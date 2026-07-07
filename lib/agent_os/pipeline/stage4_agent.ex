defmodule AgentOS.Pipeline.Stage4.GeneratedFile do
  @moduledoc """
  One file the synthesis call proposed to write, prior to any guard or write.
  """
  @derive {Jason.Encoder, only: [:path, :content]}
  @enforce_keys [:path, :content]
  defstruct [:path, :content]

  @type t :: %__MODULE__{path: String.t(), content: String.t()}
end

defmodule AgentOS.Pipeline.Stage4.AgentBody do
  @moduledoc """
  The root structure of a successful Stage 4 synthesis result.
  """
  @derive {Jason.Encoder, only: [:agent_name, :purpose, :files]}
  @enforce_keys [:agent_name, :purpose, :files]
  defstruct [:agent_name, :purpose, :files]

  @type t :: %__MODULE__{
          agent_name: String.t(),
          purpose: String.t(),
          files: [AgentOS.Pipeline.Stage4.GeneratedFile.t()]
        }
end

defmodule AgentOS.Pipeline.Stage4 do
  @moduledoc """
  Stage 4: Write the Novel Agent Body.

  Synthesizes a novel Python/PydanticAI agent body (`main.py` + `models.py`) from a
  confirmed purpose and a machine-written manifest, and writes it to
  `agents/<agent_name>/`. This is the headline Phase-4 claim made literal: the OS
  authors an agent.

  ### Judge-blindness (design doc:116, :223)
  `generate/3`'s ONLY domain parameters are `agent_name` and the structured `manifest`
  (whose `purpose` field supplies the confirmed purpose). There is no parameter or opt
  capable of carrying judge-spec content, and the implementation never reads
  `judge_spec.json` or any path under the agent's directory other than the two files it
  writes. This is stronger than Stage 3's keyword-blocklist guard
  (`AgentOS.Pipeline.Stage3`'s `@forbidden_context_keys`): here, the contract simply has
  no slot through which judge content could be threaded, because a judge spec is not a
  valid-but-forbidden input shape for this stage — it isn't an input at all. Judge and
  agent each derive independently from manifest + purpose, so a misread spec cannot be
  laundered into spurious agreement between the code and its own tests.

  ### Manifest-not-readable by the generated agent (Constitution III/X; design doc:204)
  The emitted body is never given the manifest, its grants, its spend cap, or a
  credential. Before any file is written, the synthesized content is checked against the
  manifest's own literal values and a small set of credential-shaped patterns
  (`guard_no_manifest_leak/2`) and against a denylist of direct model-provider
  hosts/SDKs (`guard_no_direct_provider/1`) — these are structural smoke-detector
  checks, not an adversarial code review (that is the explicit job of the security-review
  stage, 04-08).

  ### Generated code is untrusted by construction (Constitution X/XI)
  The fact the OS wrote this code confers no authority. The emitted body is checked only
  for the structural properties this stage's requirements make non-negotiable (typed
  contract present, no manifest/credential leak, no direct provider path, valid Python
  syntax) and is never run here. Runtime enforcement of whatever it does happens later,
  at the existing deterministic gate — unchanged by this stage.

  ### Single inference chokepoint, both ways (Constitution X)
  The authoring call (this module generating code) routes through
  `AgentOS.InferenceBroker.complete/2`, the same metered, credential-isolated chokepoint
  Stage 3 already uses. The emitted body's OWN runtime inference is not made by this
  module at all — it is Python source text instructing the body to call back through the
  `INFERENCE_SOCKET` UDS path (the same pattern `agents/discovery/main.py` already uses),
  checked structurally by `guard_no_direct_provider/1`.

  Any guard failure or broker failure fails closed: `generate/3` returns
  `{:error, reason}` and writes NO file (no partial write, no fallback body).
  """

  alias AgentOS.Pipeline.Stage4.{GeneratedFile, AgentBody}
  alias AgentOS.Manifest
  alias AgentOS.InferenceBroker


  # Opts forwarded verbatim to InferenceBroker.complete/2 (deterministic-test seams).
  @broker_opt_keys [:provider_fn, :prices, :now]

  # Credential-shaped patterns that must never appear in a synthesized agent body —
  # a hard-coded secret would bypass the credential-proxy chokepoint entirely.
  @credential_patterns [
    ~r/api[_-]?key\s*=\s*["'][^"']+["']/i,
    ~r/Authorization:\s*Bearer\s+[A-Za-z0-9._-]+/,
    ~r/sk-[A-Za-z0-9]{10,}/
  ]

  # Known direct model-provider hostnames/SDK import names. Their presence means the
  # generated code is reaching for a second, unmetered inference path instead of the
  # substrate's InferenceBroker UDS chokepoint.
  @direct_provider_patterns [
    ~r/\bopenai\b/i,
    ~r/\banthropic\b/i,
    ~r/api\.openai\.com/i,
    ~r/generativelanguage\.googleapis\.com/i,
    ~r/api\.anthropic\.com/i
  ]

  # Patterns indicating the code performs network I/O outside the local Unix domain
  # socket chokepoint (a direct internet-facing call), which must never appear without
  # also being scoped to INFERENCE_SOCKET (gate/effector/credential-proxy interactions
  # are out-of-process action proposals, not direct sockets, by construction of the
  # typed-contract guard).
  @direct_network_patterns [
    ~r/\bimport\s+requests\b/,
    ~r/\bimport\s+urllib\b/,
    ~r/\bimport\s+httpx\b/,
    ~r/\bhttp\.client\b/,
    ~r/AF_INET\b/
  ]

  @doc """
  Stage 4 entrypoint: synthesizes a novel agent body from `agent_name` and the
  structured `manifest` (purpose included), routes the authoring call through
  `AgentOS.InferenceBroker`, structurally verifies the result, and writes
  `agents/<agent_name>/main.py` + `agents/<agent_name>/models.py`.

  Returns `{:ok, %AgentBody{}}` on success. On ANY failure (missing token, broker
  timeout/error/breach, malformed synthesis output, or a failed guard) returns
  `{:error, reason}` and writes NO file.

  ## Options
    - `:run_token` - REQUIRED metered run token (registered with the broker).
    - `:model` - Authoring model name (defaults to `:agent_codegen_model` config).
    - `:spec_dir` - Base dir for the agents tree (defaults to `"agents"`).
    - `:provider_fn`, `:prices`, `:now` - forwarded to the broker (test seams).
  """
  @spec generate(String.t(), Manifest.t(), keyword()) :: {:ok, AgentBody.t()} | {:error, any()}
  def generate(agent_name, manifest, opts \\ [])

  def generate(agent_name, %Manifest{} = manifest, opts) when is_binary(agent_name) do
    with {:ok, run_token} <- require_token(opts),
         :ok <- guard_tool_declarations(manifest),
         request = %{
           run_token: run_token,
           model: codegen_model(opts),
           messages: synthesis_messages(agent_name, manifest)
         },
         {:ok, %{completion: completion}} <- broker_complete(request, opts),
         {:ok, files} <- parse_files(completion),
         :ok <- guard_path_safety(files),
         :ok <- guard_typed_contract(files),
         :ok <- guard_no_manifest_leak(files, manifest),
         :ok <- guard_no_direct_provider(files),
         :ok <- guard_python_syntax(files),
         :ok <- write_files(agent_name, files, opts) do
      {:ok, %AgentBody{agent_name: agent_name, purpose: manifest.purpose, files: files}}
    else
      {:breach, :spend} -> {:error, :spend_breach}
      {:error, reason} -> {:error, reason}
    end
  end

  # --- Synthesis prompt -----------------------------------------------------

  # Reference implementation of the InferenceBroker UDS call, copied verbatim from
  # agents/discovery/main.py, supplied to the model so it reproduces the existing
  # known-good chokepoint protocol rather than inventing its own transport.
  @broker_call_reference """
  def call_inference_broker(model: str, messages: list[dict[str, str]]) -> dict:
      \"\"\"Routes an inference call to the substrate broker over the mounted UDS.\"\"\"
      run_token = os.environ.get("RUN_TOKEN")
      socket_path = os.environ.get("INFERENCE_SOCKET")

      if not run_token or not socket_path:
          raise RuntimeError("Inference environment variables not set")

      s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
      s.connect(socket_path)

      payload = {"run_token": run_token, "model": model, "messages": messages}
      body = json.dumps(payload)
      request = (
          f"POST /v1/inference HTTP/1.1\\r\\n"
          f"Host: localhost\\r\\n"
          f"Content-Type: application/json\\r\\n"
          f"Content-Length: {len(body)}\\r\\n"
          f"Connection: close\\r\\n\\r\\n"
          f"{body}"
      )
      s.sendall(request.encode("utf-8"))

      response_data = b""
      while True:
          chunk = s.recv(4096)
          if not chunk:
              break
          response_data += chunk
      s.close()

      response_str = response_data.decode("utf-8")
      headers_str, response_body = response_str.split("\\r\\n\\r\\n", 1)
      status_code = int(headers_str.split("\\r\\n")[0].split(" ")[1])
      response_json = json.loads(response_body)
      if status_code != 200:
          raise RuntimeError(f"Inference broker error: status {status_code}")
      return response_json
  """

  # Builds the system/user message pair for the authoring call. Reuses
  # CapabilityRender.render/1 (the same deterministic, drift-free grant description
  # Stage 3 and the 04-01 consent view already use) so the prompt's description of
  # "what this agent may do" can never diverge from the actual grants, while never
  # exposing the raw manifest struct to anything downstream of this prompt-build step.
  defp synthesis_messages(agent_name, %Manifest{} = manifest) do
    system = """
    You are a code-synthesis agent inside an OS that authors its own agents. Given an
    agent's name, purpose, and a natural-language description of its capability grants,
    write a NOVEL Python/PydanticAI agent body that fulfils that purpose. Do not produce
    a parameterised template or a composition of canned components — write code specific
    to this purpose.

    Output exactly two files, matching this existing port-workload contract:
    - "main.py": reads ONE line of JSON from stdin, parses it as a generic dictionary
      (do NOT validate it against a strict Pydantic model so it can handle any dynamic
      test input), reasons over it, acts through the substrate's native tool-call channel
      (see below), and prints a single line of JSON to stdout containing a terminal outcome
      record (an "outcome" string and a "reason" string), then exits 0.
    - "models.py": Pydantic BaseModel classes for the terminal outcome record ONLY.

    If the agent needs inference at runtime, it MUST call back through the substrate's
    InferenceBroker over the existing Unix domain socket, by reproducing this EXACT
    reference implementation in main.py (adapt the messages/model as needed, do not
    invent a different transport, do not import any model-provider SDK, do not call any
    model-provider HTTP host directly):

    ```python
    #{@broker_call_reference}
    ```

    The inference broker injects your granted capabilities as native tool declarations and
    gates every tool call the model makes against the manifest — you neither see nor name any
    connector, method, or recipient. Let the model act by emitting tool calls; the substrate
    validates, performs, and records each one for you. Do NOT hand-author a list of proposed
    effects, do NOT reproduce any tool call as a free-text JSON blob, and do NOT invent your
    own action schema. After the model is done, terminate with a single-line outcome record.

    ```python
    model = os.environ.get("AGENT_MODEL", "")
    response = call_inference_broker(model, messages)
    # The substrate has already gated, performed, and recorded any tool calls the model made.
    # Terminate with a single-line outcome record — never a list of proposed effects.
    print(json.dumps({"outcome": "completed", "reason": "handled via tool channel"}))
    ```


    Hard rules:
    - You must terminate by writing exactly one line of JSON to stdout and exiting 0.
    - If the input asks for something outside your purpose or grants, you MUST refuse: make no tool calls, print an outcome record with `"outcome"` set to `"refused"` and a short `"reason"`, then exit 0 (e.g. `{"outcome": "refused", "reason": "out of scope"}`). Do NOT crash.
    - You MUST use `os.environ.get("AGENT_MODEL", "")` exactly for the fallback model. DO NOT change the default fallback string.
    - NEVER read, embed, or hard-code the manifest, any grant detail, a spend cap, a
      credential, or any environment variable other than INFERENCE_SOCKET and RUN_TOKEN.
      The capability description below is context describing the purpose's scope ONLY —
      it is not data to embed in the code.
    - DO NOT use Literal[...] types for connectors or methods in your Pydantic models.
      Use generic `str` fields, otherwise you will trigger a security violation for leaking capabilities.
    - NEVER hardcode the value of the `method` string or `connector` string inside your Python logic
      (e.g. do not write `method="send_email"` or `provider="gmail"`). You must dynamically extract these
      strings from the inference response JSON so that your Python code remains completely agnostic to
      the specific capabilities granted by the OS.
    - You MUST instruct the inference broker (the LLM) in your system prompt to strictly use the exact `connector_id` and `methods` strings that are listed in its granted capabilities context.
    - NEVER perform a privileged effect directly; only ever PROPOSE actions in the
      stdout JSON for the substrate to validate and perform.
    - If you encounter an unexpected exception (e.g. KeyError, JSONDecodeError), you MUST exit
      with a non-zero status code (e.g., `sys.exit(1)`). Do NOT swallow exceptions with a silent
      `sys.exit(0)`, as this breaks the OS testing harness.
    - Respond with JSON ONLY, of the exact form:
      {"files": [{"path": "main.py", "content": "..."}, {"path": "models.py", "content": "..."}]}
    """

    user = """
    Agent: #{agent_name}
    Purpose: #{manifest.purpose}
    """

    [
      %{role: "system", content: system},
      %{role: "user", content: user}
    ]
  end

  # --- Parsing ---------------------------------------------------------------

  # Decodes the broker's `{"files": [...]}` completion into typed GeneratedFile structs,
  # rejecting (not raising on) any malformed shape — mirrors Stage3.parse_tests/1.
  defp parse_files(completion) when is_binary(completion) do
    case lenient_decode(completion) do
      {:ok, decoded} -> parse_files(decoded)
      :error -> {:error, :invalid_synthesis_output}
    end
  end

  # Decodes the model's synthesis output tolerantly: different authoring models wrap the
  # JSON differently (```json fences, ```python fences, or prose around it). Try a direct
  # decode after stripping outer fences, then fall back to decoding the outermost {...}
  # object or [...] array span extracted from the text.
  defp lenient_decode(completion) do
    stripped =
      completion
      |> String.trim()
      |> String.replace(~r/^```[a-zA-Z0-9]*\s*/, "")
      |> String.replace(~r/```\s*$/, "")
      |> String.trim()

    [stripped, extract_span(stripped, "{", "}"), extract_span(stripped, "[", "]")]
    |> Enum.find_value(:error, fn
      nil ->
        false

      candidate ->
        case Jason.decode(candidate) do
          {:ok, decoded} -> {:ok, decoded}
          {:error, _} -> false
        end
    end)
  end

  # Slices the substring from the first `open` bracket to the last `close` bracket,
  # or nil if either is absent. Lets us pull a JSON payload out of surrounding prose.
  defp extract_span(text, open, close) do
    with {start, _} <- :binary.match(text, open),
         [_ | _] = matches <- :binary.matches(text, close),
         {stop, len} <- List.last(matches),
         true <- stop >= start do
      binary_part(text, start, stop + len - start)
    else
      _ -> nil
    end
  end

  defp parse_files(%{"files" => files}) when is_list(files), do: parse_file_list(files)
  defp parse_files(files) when is_list(files), do: parse_file_list(files)
  defp parse_files(_), do: {:error, :invalid_synthesis_output}

  defp parse_file_list(files_raw) do
    try do
      files =
        Enum.map(files_raw, fn
          %{"path" => path, "content" => content}
          when is_binary(path) and is_binary(content) ->
            %GeneratedFile{path: path, content: content}

          _ ->
            throw(:invalid_file_entry)
        end)

      {:ok, files}
    catch
      :invalid_file_entry -> {:error, :invalid_synthesis_output}
    end
  end

  # --- Guards ------------------------------------------------------------

  # Every emitted path must be a bare relative filename ending in .py, with no
  # directory separator and no parent-directory traversal — prevents the synthesis
  # output from ever naming a path outside agents/<agent_name>/.
  defp guard_tool_declarations(manifest) do
    registry = AgentOS.Connector.registry()

    Enum.reduce_while(manifest.grants, :ok, fn grant, acc ->
      case Map.fetch(registry, grant.connector) do
        {:ok, %{tool_declaration: declaration}} when not is_nil(declaration) ->
          {:cont, acc}

        _ ->
          IO.warn("Missing tool_declaration for connector: #{grant.connector}")
          {:halt, {:error, :missing_tool_declaration}}
      end
    end)
  end

  defp guard_path_safety(files) do
    unsafe? =
      Enum.any?(files, fn %GeneratedFile{path: path} ->
        String.contains?(path, "/") or
          String.contains?(path, "..") or
          not String.ends_with?(path, ".py")
      end)

    if unsafe?, do: {:error, :unsafe_path}, else: :ok
  end

  # The file set must show evidence of the typed stdin/stdout port-workload contract: a
  # pydantic import somewhere (the input/output model classes typically live in
  # models.py and are imported into main.py, as agents/discovery already does), and
  # main.py specifically must read from sys.stdin and emit JSON to stdout. A textual
  # smoke check, not a semantic proof — deep review is the security-review stage's job.
  defp guard_typed_contract(files) do
    case Enum.find(files, &(&1.path == "main.py")) do
      nil ->
        {:error, :missing_typed_contract}

      %GeneratedFile{content: main_content} ->
        joined = Enum.map_join(files, "\n", & &1.content)

        has_pydantic = joined =~ ~r/pydantic/
        has_stdin = main_content =~ ~r/sys\.stdin/
        has_json_out = main_content =~ ~r/json\.dumps/

        if has_pydantic and has_stdin and has_json_out do
          :ok
        else
          {:error, :missing_typed_contract}
        end
    end
  end

  # The emitted body must not contain the manifest's spend cap, any grant's
  # connector/recipient/method as a literal, or a credential-shaped string.
  defp guard_no_manifest_leak(files, %Manifest{} = manifest) do
    joined = Enum.map_join(files, "\n", & &1.content)

    manifest_literals =
      [to_string(manifest.spend.cap)] ++
        Enum.flat_map(manifest.grants, fn grant ->
          [grant.connector] ++ (grant.recipients || []) ++ (grant.methods || [])
        end)

    leaked_literal =
      Enum.find(manifest_literals, fn literal ->
        literal != "" and String.contains?(joined, literal)
      end)

    leaks_credential? = Enum.any?(@credential_patterns, &(joined =~ &1))

    if leaked_literal || leaks_credential? do
      if leaked_literal do
        IO.puts("\n\n=== MANIFEST LEAK DETECTED ===")
        IO.puts("Leaked string: #{inspect(leaked_literal)}")
        IO.puts("Generated code:\n#{joined}")
        IO.puts("==============================\n\n")
      end
      {:error, :manifest_leak_detected}
    else
      :ok
    end
  end

  # The emitted body must not reference a direct model-provider hostname/SDK, and any
  # direct (non-UDS) network I/O it performs must be absent entirely — runtime
  # inference must go through INFERENCE_SOCKET only.
  defp guard_no_direct_provider(files) do
    joined = Enum.map_join(files, "\n", & &1.content)

    references_provider? = Enum.any?(@direct_provider_patterns, &(joined =~ &1))
    performs_direct_network? = Enum.any?(@direct_network_patterns, &(joined =~ &1))

    if references_provider? or performs_direct_network? do
      {:error, :direct_provider_path_detected}
    else
      :ok
    end
  end

  # Each .py file's content must parse as valid Python. Writes content to a tmp file
  # and shells out to `python3 -c "ast.parse(...)"` — a pure syntax parse, not an
  # execution of the generated logic, so this never runs untrusted agent behavior.
  # (Implemented via System.cmd/3 directly rather than AgentOS.PortRunner: the
  # port_wrapper.sh stdin-guard reads exactly ONE line from stdin, which cannot carry
  # multi-line Python source; a temp-file argument sidesteps that constraint cleanly.)
  defp guard_python_syntax(files) do
    py_files = Enum.filter(files, &String.ends_with?(&1.path, ".py"))

    invalid? =
      Enum.any?(py_files, fn %GeneratedFile{content: content} ->
        tmp_path =
          Path.join(System.tmp_dir!(), "stage4_syntax_#{System.unique_integer([:positive])}.py")

        File.write!(tmp_path, content)

        result =
          System.cmd(
            "python3",
            ["-c", "import ast; ast.parse(open(__import__('sys').argv[1]).read())", tmp_path],
            stderr_to_stdout: true
          )

        File.rm(tmp_path)

        case result do
          {_output, 0} -> false
          {_output, _nonzero} -> true
        end
      end)

    if invalid?, do: {:error, :invalid_python_syntax}, else: :ok
  end

  # --- Write -------------------------------------------------------------

  # Writes all guard-passed files under spec_dir/<agent_name>/. Only called once every
  # guard above has returned :ok, so this is the sole side effect of a successful run.
  defp write_files(agent_name, files, opts) do
    base = Keyword.get(opts, :spec_dir, "agents")
    dir = Path.join([base, agent_name])
    File.mkdir_p!(dir)

    Enum.reduce_while(files, :ok, fn %GeneratedFile{path: path, content: content}, :ok ->
      case File.write(Path.join(dir, path), content) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:write_failed, reason}}}
      end
    end)
  end

  # --- Broker plumbing -----------------------------------------------------

  defp require_token(opts) do
    case Keyword.get(opts, :run_token) do
      token when is_binary(token) and token != "" -> {:ok, token}
      _ -> {:error, :missing_run_token}
    end
  end

  defp broker_complete(request, opts) do
    InferenceBroker.complete(request, Keyword.take(opts, @broker_opt_keys))
  end

  defp codegen_model(opts) do
    Keyword.get(opts, :model) ||
      Application.get_env(:agent_os, :agent_codegen_model, "agent-codegen-model")
  end
end
