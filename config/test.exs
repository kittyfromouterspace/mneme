import Config

config :mneme, Mneme.TestRepo, pool: Ecto.Adapters.SQL.Sandbox

config :logger, level: :warning
