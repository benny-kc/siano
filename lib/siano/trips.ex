defmodule Siano.Trips do
  @moduledoc """
  Public API (context) for working with trips.

  A "trip" is a live, in-memory shared session. This module hides the fact
  that each one is backed by a `Siano.Trips.TripServer` process started on
  demand under a `DynamicSupervisor`, so callers (mainly the LiveView) just
  ask for a trip by id and get one — starting it if it is not running yet.
  """

  alias Siano.Trips.TripServer

  @supervisor Siano.Trips.TripSupervisor
  @registry Siano.Trips.Registry

  @doc "Return the PubSub topic to subscribe to for live updates of a trip."
  defdelegate topic(id), to: TripServer

  @doc """
  Make sure a trip process for `id` is running and return `{:ok, id}`.

  Idempotent: if the trip is already running this is a no-op.
  """
  def ensure_started(id, name \\ "Our Trip") do
    case Registry.lookup(@registry, id) do
      [{_pid, _}] ->
        {:ok, id}

      [] ->
        spec = {TripServer, id: id, name: name}

        case DynamicSupervisor.start_child(@supervisor, spec) do
          {:ok, _pid} -> {:ok, id}
          {:error, {:already_started, _pid}} -> {:ok, id}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defdelegate rename_trip(id, name), to: TripServer

  @doc "Fetch the current rendered snapshot of a trip, starting it if needed."
  def get_snapshot(id) do
    {:ok, ^id} = ensure_started(id)
    TripServer.snapshot(id)
  end

  # Thin pass-throughs to the trip process. Keeping them here means the web
  # layer never talks to the GenServer directly.
  defdelegate add_member(id, name), to: TripServer
  defdelegate remove_member(id, member_id), to: TripServer
  defdelegate set_member_budget(id, member_id, target_id), to: TripServer
  defdelegate add_meal(id, name), to: TripServer
  defdelegate add_meal_with_participant(id, member_id, x, y), to: TripServer
  defdelegate close_meal(id, meal_id), to: TripServer
  defdelegate open_meal(id, meal_id), to: TripServer
  defdelegate delete_meal(id, meal_id), to: TripServer
  defdelegate set_meal_amount(id, meal_id, amount), to: TripServer
  defdelegate set_share(id, meal_id, member_id, amount), to: TripServer
  defdelegate set_meal_payer(id, meal_id, member_id), to: TripServer
  defdelegate add_photo(id, meal_id, photo_id), to: TripServer
  defdelegate remove_photo(id, meal_id, photo_id), to: TripServer
  defdelegate set_photo_fields(id, meal_id, photo_id, fields), to: TripServer
  defdelegate rename_meal(id, meal_id, name), to: TripServer
  defdelegate move_meal(id, meal_id, x, y), to: TripServer
  defdelegate add_participant(id, meal_id, member_id), to: TripServer
  defdelegate remove_participant(id, meal_id, member_id), to: TripServer
end
