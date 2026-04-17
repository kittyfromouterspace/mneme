ExUnit.start()

# Start the test repo
{:ok, _} = Recollect.TestRepo.start_link()

# Run migrations for test database
Ecto.Migrator.run(Recollect.TestRepo, "priv/repo/migrations", :up, all: true)
