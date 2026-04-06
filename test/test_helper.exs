ExUnit.start()

# Start the test repo
{:ok, _} = Mneme.TestRepo.start_link()

# Run migrations for test database
Ecto.Migrator.run(Mneme.TestRepo, "priv/repo/migrations", :up, all: true)
