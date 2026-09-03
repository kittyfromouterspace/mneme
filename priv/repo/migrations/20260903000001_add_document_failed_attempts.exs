defmodule Recollect.Repo.Migrations.AddDocumentFailedAttempts do
  @moduledoc """
  Dead-letter quarantine (B-1363): tracks consecutive pipeline failures per
  document. When `failed_attempts` reaches the configured threshold the
  document is quarantined and must be explicitly retried via
  `Recollect.Pipeline.retry_quarantined/2`.
  """
  use Ecto.Migration

  def up do
    alter table(:recollect_documents) do
      add(:failed_attempts, :integer, null: false, default: 0)
    end
  end

  def down do
    alter table(:recollect_documents) do
      remove(:failed_attempts)
    end
  end
end
