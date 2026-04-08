import Config

config :logger, level: :warning

config :mneme, Mneme.TestRepo, pool: Ecto.Adapters.SQL.Sandbox
