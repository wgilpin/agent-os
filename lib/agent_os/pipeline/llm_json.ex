defmodule AgentOS.Pipeline.LlmJson do
  @moduledoc """
  Decodes a JSON document out of an LLM completion.

  Models routinely wrap JSON output in a markdown code fence (```json ... ```)
  despite instructions not to. The fence is presentation, not content, so it is
  stripped before decoding. Use this for every decode of model-authored JSON;
  plain `Jason.decode/1` remains correct for JSON the substrate wrote itself.
  """

  @spec decode(String.t()) :: {:ok, term()} | {:error, Jason.DecodeError.t()}
  def decode(completion) when is_binary(completion) do
    completion
    |> String.trim()
    |> String.replace(~r/\A```(?:json)?\s*/i, "")
    |> String.replace(~r/```\z/, "")
    |> String.trim()
    |> Jason.decode()
  end
end
