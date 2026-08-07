defmodule Siano.Trips.Store do
  @moduledoc """
  Disk-backed persistence for trips so bills and costs are **never lost** — not
  across page reloads, and crucially not across server restarts (the remote
  "pull & restart" deploy stops the whole BEAM).

  Backed by `:dets`, Erlang's built-in disk term store. No external database or
  dependency is required.

  ## One file per trip

  Each trip's full `TripServer` state lives in its **own** `:dets` file under
  `<data_dir>/trips/`, rather than every trip sharing a single `trips.dets`.
  Splitting the store this way means one trip's writes can never corrupt or
  bloat another's file, a trip can be backed up / copied / deleted as a single
  file, and a damaged file only ever loses the one trip it holds.

  The on-disk file name is `Base.url_encode64/2` of the trip id (padding
  stripped) — a reversible, collision-free, filesystem-safe encoding. That
  matters because trip ids come straight from the URL (`/t/:id`) and may contain
  anything: a plain sanitise-to-safe-chars scheme could map two distinct trips
  (`"a/b"` and `"ab"`) onto the same file and silently clobber one.

  All disk access is serialized through this one GenServer, so a single reusable
  `:dets` table name (`@table`) is safe to open against each trip's file in turn
  without ever colliding across the concurrently-running trip processes. Files
  are opened, written, flushed (`:dets.sync/1`) and closed within each call, so
  an abrupt `:c.q()`/`init:stop` leaves consistent, up-to-date files behind and
  no file handles linger for idle trips.

  On boot, a legacy monolithic `trips.dets` (from before the split) is migrated
  transparently into per-trip files and renamed aside, so existing deployments
  keep all their trips.
  """
  use GenServer

  require Logger

  # Transient, reusable table name. Because every op is serialized through this
  # GenServer, only one trip file is ever open under this name at a time.
  @table :siano_trip
  @legacy_table :siano_trips_legacy

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Load a trip's persisted state, or `:error` if none is stored."
  @spec get(String.t()) :: {:ok, map()} | :error
  def get(id), do: GenServer.call(__MODULE__, {:get, id})

  @doc "Persist a trip's state and flush it to disk."
  @spec put(String.t(), map()) :: :ok
  def put(id, state), do: GenServer.call(__MODULE__, {:put, id, state})

  @doc "Delete a trip's persisted state and flush the change to disk."
  @spec delete(String.t()) :: :ok
  def delete(id), do: GenServer.call(__MODULE__, {:delete, id})

  @doc "All trip ids currently on disk."
  @spec all_ids() :: [String.t()]
  def all_ids, do: GenServer.call(__MODULE__, :all_ids)

  # ── Server ────────────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    dir = trips_dir()
    File.mkdir_p!(dir)
    migrate_legacy(dir)
    Logger.info("Siano.Trips.Store persisting one file per trip under #{dir}")
    {:ok, %{dir: dir}}
  end

  @impl true
  def handle_call({:get, id}, _from, state) do
    reply =
      case trip_path(state.dir, id) do
        # Never *create* a file on a read — a URL scanner hitting `/t/<random>`
        # triggers a `get`, and we must not leave an empty file behind for it
        # (mirrors TripServer only persisting a trip once it's actually used).
        path when is_binary(path) ->
          if File.exists?(path), do: read_trip(path, id), else: :error

        nil ->
          :error
      end

    {:reply, reply, state}
  end

  def handle_call({:put, id, trip}, _from, state) do
    case trip_path(state.dir, id) do
      path when is_binary(path) -> write_trip(path, id, trip)
      nil -> :ok
    end

    {:reply, :ok, state}
  end

  def handle_call({:delete, id}, _from, state) do
    case trip_path(state.dir, id) do
      path when is_binary(path) -> _ = File.rm(path)
      nil -> :ok
    end

    {:reply, :ok, state}
  end

  def handle_call(:all_ids, _from, state) do
    ids =
      state.dir
      |> Path.join("*.dets")
      |> Path.wildcard()
      |> Enum.flat_map(fn file ->
        case Base.url_decode64(Path.basename(file, ".dets"), padding: false) do
          {:ok, id} -> [id]
          :error -> []
        end
      end)

    {:reply, ids, state}
  end

  # ── Per-trip file IO ────────────────────────────────────────────────────────

  defp read_trip(path, id) do
    with_table(path, :error, fn ->
      case :dets.lookup(@table, id) do
        [{^id, trip}] -> {:ok, trip}
        _ -> :error
      end
    end)
  end

  defp write_trip(path, id, trip) do
    File.mkdir_p!(Path.dirname(path))

    with_table(path, :ok, fn ->
      :dets.insert(@table, {id, trip})
      :dets.sync(@table)
      :ok
    end)
  end

  # Open the trip file under the shared table name, run `fun`, then always close
  # it. Opened read-write (even for reads) so `:dets` can auto-repair a file left
  # dirty by a crash mid-write instead of a read-only open failing outright.
  # Guarded so a transient storage error never takes a trip process down — we
  # prefer a degraded (in-memory) trip over a crash.
  defp with_table(path, fallback, fun) do
    opts = [file: String.to_charlist(path), type: :set, auto_save: :infinity]

    case :dets.open_file(@table, opts) do
      {:ok, @table} ->
        try do
          fun.()
        after
          :dets.close(@table)
        end

      {:error, reason} ->
        Logger.warning("Siano.Trips.Store open failed for #{path}: #{inspect(reason)}")
        fallback
    end
  rescue
    e ->
      Logger.warning("Siano.Trips.Store error: #{inspect(e)}")
      fallback
  catch
    :exit, reason ->
      Logger.warning("Siano.Trips.Store exit: #{inspect(reason)}")
      fallback
  end

  # ── Legacy migration ────────────────────────────────────────────────────────

  # One-time migration of the old single-file store: fan every trip out into its
  # own file, then rename the legacy file aside so this never runs again. Best
  # effort — a failure here must not stop the app from booting.
  defp migrate_legacy(dir) do
    legacy = legacy_file()

    if File.exists?(legacy) do
      Logger.info("Siano.Trips.Store migrating legacy #{legacy} to per-trip files")

      case :dets.open_file(@legacy_table, file: String.to_charlist(legacy), type: :set) do
        {:ok, @legacy_table} ->
          :dets.traverse(@legacy_table, fn {id, trip} ->
            case trip_path(dir, id) do
              path when is_binary(path) -> write_trip(path, id, trip)
              nil -> :ok
            end

            :continue
          end)

          :dets.close(@legacy_table)
          File.rename(legacy, legacy <> ".migrated")

        {:error, reason} ->
          Logger.warning("Siano.Trips.Store legacy migration skipped: #{inspect(reason)}")
      end
    end
  rescue
    e -> Logger.warning("Siano.Trips.Store legacy migration error: #{inspect(e)}")
  catch
    :exit, reason -> Logger.warning("Siano.Trips.Store legacy migration exit: #{inspect(reason)}")
  end

  # ── Paths ────────────────────────────────────────────────────────────────────

  defp base_dir do
    System.get_env("SIANO_DATA_DIR") ||
      Application.get_env(:siano, :data_dir, "siano_data")
  end

  defp trips_dir, do: Path.join(base_dir(), "trips")
  defp legacy_file, do: Path.join(base_dir(), "trips.dets")

  # A trip's own file: `<trips_dir>/<url-safe-encoded-id>.dets`. Encoding the id
  # (rather than sanitising it) keeps the mapping reversible and collision-free.
  defp trip_path(_dir, id) when not is_binary(id), do: nil
  defp trip_path(_dir, ""), do: nil

  defp trip_path(dir, id) do
    Path.join(dir, Base.url_encode64(id, padding: false) <> ".dets")
  end
end
