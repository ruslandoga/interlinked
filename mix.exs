defmodule Interlinked.MixProject do
  use Mix.Project

  def project do
    [
      app: :interlinked,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:xqlite,
       github: "ruslandoga/xqlite", system_env: [{"XQLITE_CFLAGS", "-DSQLITE_ENABLE_DBPAGE_VTAB"}]}
    ]
  end
end
