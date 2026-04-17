# Only define Postgrex types when both postgrex and pgvector are available
# (i.e., PostgreSQL backend is in use)
if Code.ensure_loaded?(Postgrex.Types) and Code.ensure_loaded?(Pgvector) do
  Postgrex.Types.define(
    Recollect.PostgrexTypes,
    Pgvector.extensions() ++ Ecto.Adapters.Postgres.extensions(),
    []
  )
end
