defmodule Mneme.DataCase do
  @moduledoc """
  Test case with Ecto Sandbox for database testing.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Mneme.Config
      alias Mneme.Fixtures

      import Mneme.Fixtures
    end
  end

  setup tags do
    Mneme.DataCase.setup_sandbox(tags)
    :ok
  end

  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Mneme.TestRepo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end
end
