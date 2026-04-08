import Config

config :logger, level: :warning

config :mneme, Mneme.TestRepo,
  database: "mneme_test",
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  pool_size: 10,
  pool: Ecto.Adapters.SQL.Sandbox,
  migration_repo: Mneme.TestRepo,
  priv: "priv/repo",
  types: Mneme.PostgrexTypes

config :mneme, ecto_repos: [Mneme.TestRepo]

config :mneme,
  repo: Mneme.TestRepo,
  embedding: [provider: Mneme.Embedding.Mock, mock: true],
  table_prefix: "mneme_test_"
