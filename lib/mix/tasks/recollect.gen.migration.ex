defmodule Mix.Tasks.Recollect.Gen.Migration do
  @moduledoc """
  Generates Recollect database migrations in the host application.

      mix recollect.gen.migration

  ## Options

  - `--dimensions` — Embedding vector dimensions (default: 1536)
  - `--repo` — Ecto repo module (default: from config)
  """
  use Mix.Task

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [dimensions: :integer, repo: :string])
    dimensions = Keyword.get(opts, :dimensions, 1536)

    timestamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d%H%M%S")
    filename = "#{timestamp}_create_recollect_tables.exs"

    migrations_path = Path.join(["priv", "repo", "migrations"])
    File.mkdir_p!(migrations_path)

    target = Path.join(migrations_path, filename)

    up_sql = Recollect.MigrationGenerator.generate_up(dimensions: dimensions)
    down_sql = Recollect.MigrationGenerator.generate_down()

    content = """
    defmodule Recollect.Repo.Migrations.CreateRecollectTables do
      use Ecto.Migration

      def up do
    #{indent(up_sql, 8)}
      end

      def down do
    #{indent(down_sql, 8)}
      end
    end
    """

    File.write!(target, content)

    IO.puts(IO.ANSI.green() <> "* creating " <> IO.ANSI.reset() <> target)
    IO.puts("")
    IO.puts("Run `mix ecto.migrate` to apply the migration.")
  end

  defp indent(text, spaces) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", &String.pad_leading(&1, String.length(&1) + spaces))
  end
end
