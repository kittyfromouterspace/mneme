import Config

config :logger, level: :warning

config :recollect, Recollect.TestRepo, pool: Ecto.Adapters.SQL.Sandbox
config :recollect, repo: Recollect.TestRepo
