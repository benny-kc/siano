defmodule Siano.Trips.Store do
  @moduledoc """
  Disk-backed persistence for trips so bills and costs are **never lost** — not
  across page reloads, and crucially not across server restarts (the remote
  "pull & restart" deploy stops the whole BEAM).

  Backed by `:dets`, Erlang's built-in disk term store. No external database or
  dependency is required: each trip's full `TripServer` state is written to a
  single file, keyed by trip id, and re-loaded when the trip's process starts.

  Writes are flushed to disk immediately (`:dets.sync/1`) so an abrupt
  `:c.q()`/`init:stop` still leaves a consistent, up-to-date file behind.
  """
  use GenServer

  require Logger

  @table :siano_trips

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Load a trip's persisted state, or `:error` if none is stored."
  @spec get(String.t()) :: {:ok, map()} | :error
  def get(id) do
    case safe(fn -> :dets.lookup(@table, id) end, []) do
      [{^id, state}] -> {:ok, state}
      _ -> :error
    end
  end

  @doc "Persist a trip's state and flush it to disk."
  @spec put(String.t(), map()) :: :ok
  def put(id, state) do
    safe(fn ->
      :dets.insert(@table, {id, state})
      :dets.sync(@table)
    end)

    :ok
  end

  @doc "Delete a trip's persisted state and flush the change to disk."
  @spec delete(String.t()) :: :ok
  def delete(id) do
    safe(fn ->
      :dets.delete(@table, id)
      :dets.sync(@table)
    end)

    :ok
  end

  @doc "All trip ids currently on disk."
  @spec all_ids() :: [String.t()]
  def all_ids do
    safe(fn -> :dets.select(@table, [{{:"$1", :_}, [], [:"$1"]}]) end, [])
  end

  # ── Server ────────────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    path = data_file()
    File.mkdir_p!(Path.dirname(path))

    case :dets.open_file(@table, file: String.to_charlist(path), type: :set, auto_save: 10_000) do
      {:ok, @table} ->
        Logger.info("Siano.Trips.Store persisting to #{path}")
        {:ok, %{path: path}}

      {:error, reason} ->
        {:stop, {:dets_open_failed, reason}}
    end
  end

  @impl true
  def terminate(_reason, _state) do
    # Best-effort clean flush + close on shutdown (incl. graceful :c.q()).
    _ = safe(fn -> :dets.sync(@table) end)
    _ = safe(fn -> :dets.close(@table) end)
    :ok
  end

  # The DETS table is owned by this long-lived process; other processes may read
  # and write it by name while it is open. Guard every call so a transient
  # storage error never takes a trip process down — we prefer a degraded
  # (in-memory) trip over a crash.
  defp safe(fun, fallback \\ :ok) do
    fun.()
  rescue
    e ->
      Logger.warning("Siano.Trips.Store error: #{inspect(e)}")
      fallback
  catch
    :exit, reason ->
      Logger.warning("Siano.Trips.Store exit: #{inspect(reason)}")
      fallback
  end

  defp data_file do
    dir =
      System.get_env("SIANO_DATA_DIR") ||
        Application.get_env(:siano, :data_dir, "siano_data")

    Path.join(dir, "trips.dets")
  end
end
