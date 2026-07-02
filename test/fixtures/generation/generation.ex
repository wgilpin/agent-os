defmodule AgentOS.Fixtures.Generation do
  @moduledoc """
  Fixtures and helper functions for generation pipeline testing.
  """

  alias AgentOS.ElicitedSpec

  @doc """
  Returns a confirmed ElicitedSpec for "reply to recruiter emails".
  """
  def recruiter_confirmed_spec do
    %ElicitedSpec{
      purpose: "reply to recruiter emails",
      capabilities: ["kv_append", "external_send"],
      boundaries: %{
        egress_domains: ["owner-inbox"],
        target_locations: []
      },
      spend_limits: %{dollar_cap: 0.003, token_limit: 100_000},
      confirmed: true
    }
  end

  @doc """
  A fixed Stage-4 agent body files map.
  """
  def stub_agent_body do
    %{
      "main.py" => """
      import sys
      import json
      import socket
      import os
      from pydantic import BaseModel
      from models import InputModel, OutputModel

      def call_inference_broker(model: str, messages: list[dict[str, str]]) -> dict:
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
          os.write(s.fileno(), request.encode("utf-8"))
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

      def main():
          line = sys.stdin.readline()
          if not line:
              return
          data = json.loads(line)
          input_obj = InputModel(**data)
          output = OutputModel(actions=[])
          print(json.dumps(output.model_dump()))

      if __name__ == "__main__":
          main()
      """,
      "models.py" => """
      from pydantic import BaseModel

      class InputModel(BaseModel):
          items: list
          state: dict

      class ActionEntry(BaseModel):
          type: str
          method: str
          payload: dict = {}

      class OutputModel(BaseModel):
          actions: list[ActionEntry]
      """
    }
  end

  # Stubbed provider functions
  def judge_pass do
    fn _model, _msgs, _secret ->
      %{
        input_tokens: 10,
        output_tokens: 10,
        completion: "{\"verdict\": \"pass\", \"reasoning\": \"stubbed judge pass\"}"
      }
    end
  end

  def security_pass do
    fn _model, _msgs, _secret ->
      %{
        input_tokens: 10,
        output_tokens: 10,
        completion: "{\"status\": \"pass\", \"reasoning\": \"stubbed security pass\"}"
      }
    end
  end

  def security_fail do
    fn _model, _msgs, _secret ->
      %{
        input_tokens: 10,
        output_tokens: 10,
        completion: "{\"status\": \"fail\", \"reasoning\": \"stubbed security fail\"}"
      }
    end
  end

  def crashing_provider do
    fn _model, _msgs, _secret ->
      raise RuntimeError, "Stubbed model provider crashed"
    end
  end

  @doc """
  Generates a map of unique temporary directories under System.tmp_dir!()
  """
  def tmp_dirs do
    rand = System.unique_integer([:positive])
    spec_dir = Path.join(System.tmp_dir!(), "agents_spec_#{rand}")
    manifest_dir = Path.join(System.tmp_dir!(), "manifests_#{rand}")
    File.mkdir_p!(spec_dir)
    File.mkdir_p!(manifest_dir)

    %{
      spec_dir: spec_dir,
      manifest_dir: manifest_dir
    }
  end
end
