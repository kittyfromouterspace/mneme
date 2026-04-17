defmodule Recollect.DatabaseAdapter.SQLiteBase do
  @moduledoc false

  defmacro __using__(_opts) do
    quote do
      @behaviour Recollect.DatabaseAdapter

      @impl true
      def vector_ecto_type, do: :string

      @impl true
      def format_embedding(embedding) when is_list(embedding) do
        "[#{Enum.map_join(embedding, ",", &format_float/1)}]"
      end

      defp format_float(f) when is_float(f) do
        :erlang.float_to_binary(f, [:compact, decimals: 6])
      end

      defp format_float(i) when is_integer(i), do: Integer.to_string(i)

      @impl true
      def create_vector_extension_sql, do: nil

      @impl true
      def uuid_type, do: :string

      @impl true
      def format_uuid(uuid) when is_binary(uuid), do: uuid

      @impl true
      def supports_recursive_ctes?, do: true

      @impl true
      def supports_vector_index?, do: true

      @impl true
      def placeholder(_position), do: "?"

      @impl true
      def requires_pgvector?, do: false

      @impl true
      def parse_embedding(nil), do: nil

      def parse_embedding(embedding) when is_binary(embedding) do
        case Jason.decode(embedding) do
          {:ok, list} when is_list(list) -> list
          _ -> nil
        end
      end

      def parse_embedding(embedding) when is_list(embedding), do: embedding

      defoverridable vector_ecto_type: 0,
                     format_embedding: 1,
                     create_vector_extension_sql: 0,
                     uuid_type: 0,
                     format_uuid: 1,
                     supports_recursive_ctes?: 0,
                     supports_vector_index?: 0,
                     placeholder: 1,
                     requires_pgvector?: 0,
                     parse_embedding: 1
    end
  end
end
