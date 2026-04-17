defmodule Recollect.DataCase do
  @moduledoc """
  Test case with Ecto Sandbox for database testing.
  """

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      import Recollect.Fixtures

      alias Recollect.Config
      alias Recollect.Fixtures
    end
  end

  setup tags do
    Recollect.DataCase.setup_sandbox(tags)
    :ok
  end

  def setup_sandbox(tags) do
    pid = Sandbox.start_owner!(Recollect.TestRepo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
  end
end
