defmodule Mneme.MixProject do
  use Mix.Project

  @version "0.4.4"

  def project do
    [
      app: :mneme,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      elixirc_paths: elixirc_paths(Mix.env()),
      description:
        "Pluggable memory engine with vector search, knowledge graphs, and LLM extraction. Supports PostgreSQL (pgvector), SQLite (sqlite-vec), and libSQL.",
      package: package(),
      dialyzer: [ignore_warnings: ".dialyzer_ignore.exs"]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Mneme.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Core dependencies
      {:ecto_sql, "~> 3.12"},
      {:jason, "~> 1.4"},
      {:req, "~> 0.5"},
      {:telemetry, "~> 1.0"},

      # Database adapters (optional - user chooses one)
      # PostgreSQL support
      {:postgrex, "~> 0.19", optional: true},
      # pgvector for PostgreSQL vector support
      {:pgvector, "~> 0.3", optional: true},
      # libSQL support (legacy)
      {:ecto_libsql, "~> 0.9", optional: true},
      # SQLite3 + sqlite-vec support (recommended for new installations)
      {:ecto_sqlite3, "~> 0.18", optional: true},
      {:sqlite_vec, "~> 0.1", optional: true},

      # Local embedding support (optional - enables Mneme.Embedding.Local)
      {:bumblebee, "~> 0.6.0", optional: true},

      # Dev/Test tooling
      {:ex_check, "~> 0.16", only: [:dev], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev], runtime: false},
      {:styler, ">= 0.11.0", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:doctor, "~> 0.22", only: [:dev], runtime: false}
    ]
  end

  defp aliases do
    [
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]
    ]
  end

  defp package do
    [
      licenses: ["BSD-3-Clause"],
      links: %{"GitHub" => "https://github.com/kittyfromouterspace/mneme"}
    ]
  end
end
