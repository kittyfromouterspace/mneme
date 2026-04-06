defmodule Mneme.TestRepo do
  use Ecto.Repo,
    otp_app: :mneme,
    adapter: Ecto.Adapters.Postgres
end
