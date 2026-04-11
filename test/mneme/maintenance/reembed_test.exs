defmodule Mneme.Maintenance.ReembedTest do
  use Mneme.DataCase, async: false

  alias Mneme.Maintenance.Reembed
  alias Mneme.Schema.Entry

  describe "run/1 with custom embedding_fn" do
    test "calls the provided callback for each row and writes vectors + model_id" do
      owner = owner_id()
      scope = scope_id()

      {:ok, entry} =
        Config.repo().insert(
          Entry.changeset(%Entry{}, %{
            content: "hello world",
            owner_id: owner,
            scope_id: scope,
            entry_type: "note",
            source: "system"
          })
        )

      embedding_fn = fn _text ->
        {:ok, List.duplicate(0.5, 1536), "test-model-x"}
      end

      assert {:ok, _} =
               Reembed.run(
                 embedding_fn: embedding_fn,
                 tables: ["mneme_entries"],
                 scope: :nil_only,
                 batch_size: 10,
                 concurrency: 1
               )

      reloaded = Config.repo().get(Entry, entry.id)
      assert reloaded.embedding_model_id == "test-model-x"
      assert reloaded.embedding
    end

    test "supports {:stale_model, current_id} scope" do
      owner = owner_id()
      scope = scope_id()

      {:ok, fresh} =
        Config.repo().insert(
          Entry.changeset(%Entry{}, %{
            content: "fresh",
            owner_id: owner,
            scope_id: scope,
            entry_type: "note",
            source: "system",
            embedding: List.duplicate(0.1, 1536),
            embedding_model_id: "model-current"
          })
        )

      {:ok, stale} =
        Config.repo().insert(
          Entry.changeset(%Entry{}, %{
            content: "stale",
            owner_id: owner,
            scope_id: scope,
            entry_type: "note",
            source: "system",
            embedding: List.duplicate(0.2, 1536),
            embedding_model_id: "model-old"
          })
        )

      embedding_fn = fn _text ->
        {:ok, List.duplicate(0.9, 1536), "model-current"}
      end

      assert {:ok, _} =
               Reembed.run(
                 embedding_fn: embedding_fn,
                 tables: ["mneme_entries"],
                 scope: {:stale_model, "model-current"},
                 batch_size: 10,
                 concurrency: 1
               )

      reloaded_stale = Config.repo().get(Entry, stale.id)
      assert reloaded_stale.embedding_model_id == "model-current"

      reloaded_fresh = Config.repo().get(Entry, fresh.id)
      # Fresh row should not have been touched.
      assert reloaded_fresh.embedding_model_id == "model-current"
    end

    test "invokes progress_callback per batch" do
      owner = owner_id()
      scope = scope_id()

      for i <- 1..3 do
        {:ok, _} =
          Config.repo().insert(
            Entry.changeset(%Entry{}, %{
              content: "row #{i}",
              owner_id: owner,
              scope_id: scope,
              entry_type: "note",
              source: "system"
            })
          )
      end

      test_pid = self()

      embedding_fn = fn _text -> {:ok, List.duplicate(0.0, 1536), "m"} end

      progress_callback = fn progress ->
        send(test_pid, {:progress, progress})
        :ok
      end

      assert {:ok, _} =
               Reembed.run(
                 embedding_fn: embedding_fn,
                 progress_callback: progress_callback,
                 tables: ["mneme_entries"],
                 scope: :nil_only,
                 batch_size: 10,
                 concurrency: 1
               )

      assert_received {:progress, %{table: "mneme_entries", processed: _, total: _}}
    end
  end
end
