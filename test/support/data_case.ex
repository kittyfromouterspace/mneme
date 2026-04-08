defmodule Mneme.DataCase do
  @moduledoc """
  Test case with Ecto Sandbox for database testing.
  """

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      import Mneme.Fixtures

      alias Mneme.Config
      alias Mneme.Fixtures
    end
  end

  setup tags do
    Mneme.DataCase.setup_sandbox(tags)
    :ok
  end

  def setup_sandbox(tags) do
    pid = Sandbox.start_owner!(Mneme.TestRepo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
  end
end
