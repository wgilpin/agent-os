defmodule AgentOS.MixProject do
  use Mix.Project

  def project do
    [
      app: :agent_os,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      # Env-driven deps/build paths (feature 045): the containerized substrate points these at
      # container-local dirs so its Linux-compiled artifacts never clash with the host macOS
      # `_build`/`deps` when the repo is bind-mounted at the identical path. Unset on the host
      # (default `deps`/`_build`), so the host workflow is byte-for-byte unchanged.
      deps_path: System.get_env("MIX_DEPS_PATH") || "deps",
      build_path: System.get_env("MIX_BUILD_PATH") || "_build",
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {AgentOS.Application, []}
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:yaml_elixir, "~> 2.12"},
      {:req, "~> 0.5"},
      {:phoenix, "~> 1.7.10"},
      {:phoenix_live_view, "~> 0.20.2"},
      {:phoenix_html, "~> 4.0"},
      {:plug_cowboy, "~> 2.6"},
      {:websockex, "~> 0.5.1"},
      {:exqlite, ">= 0.11.0"},
      {:floki, ">= 0.30.0", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end
end
