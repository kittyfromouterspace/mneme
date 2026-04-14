import Config

config :logger, level: :warning

config :mneme, repo: Mneme.TestRepo

config :mneme, Mneme.TestRepo, pool: Ecto.Adapters.SQL.Sandbox
