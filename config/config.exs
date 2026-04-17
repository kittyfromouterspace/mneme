import Config

config :logger, level: :warning

config :recollect, Recollect.TestRepo,
  database: "recollect_test",
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  pool_size: 10,
  pool: Ecto.Adapters.SQL.Sandbox,
  migration_repo: Recollect.TestRepo,
  priv: "priv/repo",
  types: Recollect.PostgrexTypes

config :recollect, ecto_repos: [Recollect.TestRepo]

config :recollect,
  repo: Recollect.TestRepo,
  embedding: [provider: Recollect.Embedding.Mock, mock: true],
  table_prefix: "recollect_test_"
