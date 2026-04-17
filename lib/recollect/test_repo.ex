defmodule Recollect.TestRepo do
  use Ecto.Repo,
    otp_app: :recollect,
    adapter: Ecto.Adapters.Postgres
end
