defmodule Siano.Trips.TripServer do
  @moduledoc """
  A `GenServer` that owns the live state of a single trip.

  Every trip (a group of travellers sharing costs) runs as its own process,
  started on demand under a `DynamicSupervisor` and located through a
  `Registry`. Keeping the state in a process instead of a database means the
  interactive "game board" stays snappy and every connected player sees the
  same thing in real time: after any mutation the server broadcasts a fresh
  snapshot over `Phoenix.PubSub`, and each `LiveView` re-renders.

  The actual money math lives in `Siano.Trips.Splitter` and is kept pure so
  it can be reasoned about (and tested) on its own.
  """
  use GenServer

  alias Siano.Trips.{Splitter, Money, Store, Photos}

  @registry Siano.Trips.Registry
  @pubsub Siano.PubSub

  @palette ~w(#f97316 #22c55e #3b82f6 #ec4899 #a855f7 #14b8a6 #eab308 #ef4444 #6366f1 #10b981)
  @meal_emojis ~w(🍕 🍔 🍣 🌮 🍜 🥘 🍩 🍻)

  # ── Client API ────────────────────────────────────────────────────────────

  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    name = Keyword.get(opts, :name, "Our Trip")
    GenServer.start_link(__MODULE__, {id, name}, name: via(id))
  end

  @doc "Registry-based `:via` tuple used to address a trip process by id."
  def via(id), do: {:via, Registry, {@registry, id}}

  @doc "PubSub topic a client subscribes to for live updates of a trip."
  def topic(id), do: "trip:" <> id

  def snapshot(id), do: call(id, :snapshot)

  @doc "Rename the trip (blank falls back to a default)."
  def rename_trip(id, name), do: call(id, {:rename_trip, name})

  def add_member(id, name), do: call(id, {:add_member, name})
  def remove_member(id, member_id), do: call(id, {:remove_member, member_id})

  @doc """
  Put `member_id` into a shared budget. Passing `target_id == member_id` gives
  them their own budget again; otherwise they join `target_id`'s budget.
  """
  def set_member_budget(id, member_id, target_id),
    do: call(id, {:set_member_budget, member_id, target_id})

  def add_meal(id, name), do: call(id, {:add_meal, name})

  @doc """
  Create a new meal at board position `{x, y}` with `member_id` already added as
  its first participant (and therefore the default payer). This is the "drop a
  traveller on empty space to start a meal" shortcut.
  """
  def add_meal_with_participant(id, member_id, x, y),
    do: call(id, {:add_meal_with_participant, member_id, x, y})

  @doc "Hide a meal's card from the board. The bill is kept in history."
  def close_meal(id, meal_id), do: call(id, {:close_meal, meal_id})

  @doc "Bring a bill back onto the board (from history) ready to edit."
  def open_meal(id, meal_id), do: call(id, {:open_meal, meal_id})

  @doc "Permanently delete a bill (and its cost) from the trip."
  def delete_meal(id, meal_id), do: call(id, {:delete_meal, meal_id})
  def set_meal_amount(id, meal_id, amount), do: call(id, {:set_meal_amount, meal_id, amount})

  @doc """
  Fix (or clear) one participant's exact share of a meal. A blank/invalid
  `amount` clears the custom share, returning that person to the even split.
  """
  def set_share(id, meal_id, member_id, amount),
    do: call(id, {:set_share, meal_id, member_id, amount})
  def set_meal_payer(id, meal_id, member_id), do: call(id, {:set_meal_payer, meal_id, member_id})

  def add_photo(id, meal_id, photo_id), do: call(id, {:add_photo, meal_id, photo_id})
  def remove_photo(id, meal_id, photo_id), do: call(id, {:remove_photo, meal_id, photo_id})
  def rename_meal(id, meal_id, name), do: call(id, {:rename_meal, meal_id, name})
  def move_meal(id, meal_id, x, y), do: call(id, {:move_meal, meal_id, x, y})

  @doc "The core drag & drop action: assign a member to a meal as a participant."
  def add_participant(id, meal_id, member_id),
    do: call(id, {:add_participant, meal_id, member_id})

  def remove_participant(id, meal_id, member_id),
    do: call(id, {:remove_participant, meal_id, member_id})

  defp call(id, msg), do: GenServer.call(via(id), msg)

  # ── Server ────────────────────────────────────────────────────────────────

  @impl true
  def init({id, name}) do
    # Rehydrate from disk if this trip has been used before, so bills/costs
    # survive server restarts. Only seed a brand-new trip.
    state =
      case Store.get(id) do
        {:ok, saved} -> normalize(saved)
        :error -> seed_new(id, name)
      end

    Store.put(state.id, state)
    {:ok, state}
  end

  # Backfill keys that older persisted trips predate, so meals rehydrated from
  # disk always have the current shape (avoids KeyError on map updates).
  defp normalize(state) do
    meals =
      Map.new(state.meals, fn {mid, meal} ->
        {mid,
         meal
         |> Map.put_new(:open, true)
         |> Map.put_new(:locked_shares, %{})
         |> Map.put_new(:inserted_at, nil)
         |> Map.put_new(:photos, [])}
      end)

    members =
      Map.new(state.members, fn {mid, member} ->
        {mid, Map.put_new(member, :budget_id, mid)}
      end)

    state
    |> Map.put(:meals, meals)
    |> Map.put(:members, members)
    |> Map.put_new(:meal_order, Map.keys(meals))
    |> Map.put_new(:seq, map_size(meals) + map_size(members))
  end

  # Seed a fresh trip with a couple of travellers so the board is never empty.
  defp seed_new(id, name) do
    %{
      id: id,
      name: name,
      members: %{},
      member_order: [],
      meals: %{},
      meal_order: [],
      seq: 0
    }
    |> do_add_member("Ala")
    |> do_add_member("Bartek")
    |> do_add_member("Celina")
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, build_snapshot(state), state}
  end

  def handle_call({:rename_trip, name}, _from, state) do
    reply_and_broadcast(%{state | name: sanitize_name(name, "Our Trip")})
  end

  def handle_call({:add_member, name}, _from, state) do
    reply_and_broadcast(do_add_member(state, name))
  end

  def handle_call({:remove_member, member_id}, _from, state) do
    members = Map.delete(state.members, member_id)
    member_order = List.delete(state.member_order, member_id)

    # drop the departing member from every meal as well
    meals =
      Map.new(state.meals, fn {mid, meal} ->
        {mid,
         %{
           meal
           | participant_ids: List.delete(meal.participant_ids, member_id),
             payer_id: if(meal.payer_id == member_id, do: nil, else: meal.payer_id),
             locked_shares: Map.delete(locked_shares(meal), member_id)
         }}
      end)

    reply_and_broadcast(%{state | members: members, member_order: member_order, meals: meals})
  end

  def handle_call({:set_member_budget, member_id, target_id}, _from, state) do
    state =
      if Map.has_key?(state.members, member_id) do
        new_budget =
          cond do
            target_id == member_id -> member_id
            Map.has_key?(state.members, target_id) -> budget_id(state.members[target_id])
            true -> member_id
          end

        member = Map.put(state.members[member_id], :budget_id, new_budget)
        %{state | members: Map.put(state.members, member_id, member)}
      else
        state
      end

    reply_and_broadcast(state)
  end

  def handle_call({:add_meal, name}, _from, state) do
    reply_and_broadcast(do_add_meal(state, name))
  end

  def handle_call({:add_meal_with_participant, member_id, x, y}, _from, state) do
    state = do_add_meal(state, "")
    meal_id = List.last(state.meal_order)

    state =
      update_meal(state, meal_id, fn meal ->
        if Map.has_key?(state.members, member_id) do
          participants = add_unique(meal.participant_ids, member_id)
          %{meal | participant_ids: participants, payer_id: List.first(participants), x: x, y: y}
        else
          %{meal | x: x, y: y}
        end
      end)

    reply_and_broadcast(state)
  end

  def handle_call({:close_meal, meal_id}, _from, state) do
    meal = Map.get(state.meals, meal_id)

    state =
      if meal && meal.participant_ids == [] && meal.amount_cents == 0 && photos(meal) == [] do
        # An empty draft (nobody added, no amount) is discarded rather than kept
        # in history when closed.
        %{
          state
          | meals: Map.delete(state.meals, meal_id),
            meal_order: List.delete(state.meal_order, meal_id)
        }
      else
        update_meal(state, meal_id, &Map.put(&1, :open, false))
      end

    reply_and_broadcast(state)
  end

  def handle_call({:delete_meal, meal_id}, _from, state) do
    # clean up any photo files for the deleted bill
    case Map.get(state.meals, meal_id) do
      nil -> :ok
      meal -> spawn(fn -> Enum.each(photos(meal), &Photos.delete(state.id, &1.id)) end)
    end

    state = %{
      state
      | meals: Map.delete(state.meals, meal_id),
        meal_order: List.delete(state.meal_order, meal_id)
    }

    reply_and_broadcast(state)
  end

  def handle_call({:open_meal, meal_id}, _from, state) do
    # Re-open from history. If it was hidden, drop it back at a clearly visible
    # spot so it is "presented ready to edit"; if it is already on the board,
    # leave its position untouched.
    state =
      update_meal(state, meal_id, fn meal ->
        if Map.get(meal, :open, true), do: meal, else: Map.merge(meal, %{open: true, x: 24, y: 24})
      end)

    reply_and_broadcast(state)
  end

  def handle_call({:set_meal_amount, meal_id, amount}, _from, state) do
    case Money.parse(amount) do
      {:ok, cents} ->
        reply_and_broadcast(update_meal(state, meal_id, &%{&1 | amount_cents: cents}))

      :error ->
        {:reply, {:error, :invalid_amount}, state}
    end
  end

  def handle_call({:add_photo, meal_id, photo_id}, _from, state) do
    state =
      update_meal(state, meal_id, fn meal ->
        Map.put(meal, :photos, photos(meal) ++ [%{id: photo_id}])
      end)

    reply_and_broadcast(state)
  end

  def handle_call({:remove_photo, meal_id, photo_id}, _from, state) do
    state =
      update_meal(state, meal_id, fn meal ->
        Map.put(meal, :photos, Enum.reject(photos(meal), &(&1.id == photo_id)))
      end)

    spawn(fn -> Photos.delete(state.id, photo_id) end)
    reply_and_broadcast(state)
  end

  def handle_call({:set_meal_payer, meal_id, member_id}, _from, state) do
    # a payer is implicitly a participant too
    state =
      update_meal(state, meal_id, fn meal ->
        %{
          meal
          | payer_id: member_id,
            participant_ids: add_unique(meal.participant_ids, member_id)
        }
      end)

    reply_and_broadcast(state)
  end

  def handle_call({:set_share, meal_id, member_id, amount}, _from, state) do
    state =
      update_meal(state, meal_id, fn meal ->
        cond do
          # only participants can have a custom share
          member_id not in meal.participant_ids ->
            meal

          # blank/invalid -> clear the lock (back to the even split)
          match?(:error, Money.parse(amount)) ->
            Map.put(meal, :locked_shares, Map.delete(locked_shares(meal), member_id))

          true ->
            {:ok, cents} = Money.parse(amount)
            capped = min(cents, meal.amount_cents)
            Map.put(meal, :locked_shares, Map.put(locked_shares(meal), member_id, capped))
        end
      end)

    reply_and_broadcast(state)
  end

  def handle_call({:rename_meal, meal_id, name}, _from, state) do
    reply_and_broadcast(update_meal(state, meal_id, &%{&1 | name: sanitize_name(name, "Meal")}))
  end

  def handle_call({:move_meal, meal_id, x, y}, _from, state) do
    reply_and_broadcast(update_meal(state, meal_id, &%{&1 | x: x, y: y}))
  end

  def handle_call({:add_participant, meal_id, member_id}, _from, state) do
    if Map.has_key?(state.members, member_id) do
      state =
        update_meal(state, meal_id, fn meal ->
          participants = add_unique(meal.participant_ids, member_id)

          # Default the payer to the first person added, so a meal is never
          # left without someone who paid. Tapping another avatar still moves
          # the payer (see :set_meal_payer).
          %{meal | participant_ids: participants, payer_id: meal.payer_id || List.first(participants)}
        end)

      reply_and_broadcast(state)
    else
      {:reply, {:error, :unknown_member}, state}
    end
  end

  def handle_call({:remove_participant, meal_id, member_id}, _from, state) do
    state =
      update_meal(state, meal_id, fn meal ->
        participants = List.delete(meal.participant_ids, member_id)

        # If the person who paid is removed, hand the payer role to whoever is
        # still on the meal (nil only when nobody is left) — again, never leave
        # a populated meal unpaid.
        payer_id =
          if meal.payer_id == member_id, do: List.first(participants), else: meal.payer_id

        %{
          meal
          | participant_ids: participants,
            payer_id: payer_id,
            locked_shares: Map.delete(locked_shares(meal), member_id)
        }
      end)

    reply_and_broadcast(state)
  end

  # ── State transitions (pure over the struct) ────────────────────────────────

  defp do_add_member(state, name) do
    {id, state} = next_id(state, "m")
    index = length(state.member_order)

    member = %{
      id: id,
      name: sanitize_name(name, "Traveller"),
      color: Enum.at(@palette, rem(index, length(@palette))),
      initials: initials(name),
      # a member is their own budget by default (budget of one)
      budget_id: id
    }

    %{
      state
      | members: Map.put(state.members, id, member),
        member_order: state.member_order ++ [id]
    }
  end

  defp do_add_meal(state, name) do
    {id, state} = next_id(state, "meal")
    index = length(state.meal_order)

    meal = %{
      id: id,
      name: sanitize_name(name, "New meal"),
      emoji: Enum.at(@meal_emojis, rem(index, length(@meal_emojis))),
      amount_cents: 0,
      payer_id: nil,
      participant_ids: [],
      # per-participant fixed shares (member_id => cents); everyone else splits
      # the remainder evenly. Empty == a plain even split.
      locked_shares: %{},
      # creation time (unix seconds, UTC) — formatted to local time in the UI
      inserted_at: DateTime.utc_now() |> DateTime.to_unix(),
      # attached bill photos: list of %{id: photo_id}
      photos: [],
      open: true,
      # Cascade new cards near the top-left in a small diagonal that cycles, so
      # they always start inside the viewport. The client clamps into the board
      # on mount as a final guarantee (see the MealCard hook).
      x: 24 + rem(index, 8) * 26,
      y: 24 + rem(index, 8) * 26
    }

    %{
      state
      | meals: Map.put(state.meals, id, meal),
        meal_order: state.meal_order ++ [id]
    }
  end

  defp update_meal(state, meal_id, fun) do
    case Map.fetch(state.meals, meal_id) do
      {:ok, meal} -> %{state | meals: Map.put(state.meals, meal_id, fun.(meal))}
      :error -> state
    end
  end

  defp next_id(state, prefix) do
    seq = state.seq + 1
    {"#{prefix}-#{seq}", %{state | seq: seq}}
  end

  defp add_unique(list, item), do: if(item in list, do: list, else: list ++ [item])

  defp sanitize_name(name, fallback) do
    case String.trim(to_string(name)) do
      "" -> fallback
      trimmed -> String.slice(trimmed, 0, 40)
    end
  end

  defp initials(name) do
    name
    |> to_string()
    |> String.trim()
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(2)
    |> Enum.map(&String.first/1)
    |> Enum.join()
    |> String.upcase()
    |> case do
      "" -> "?"
      value -> value
    end
  end

  # ── Snapshot & broadcasting ────────────────────────────────────────────────

  defp reply_and_broadcast(state) do
    # Persist first so the change is on disk before anyone reacts to it.
    Store.put(state.id, state)
    snapshot = build_snapshot(state)
    Phoenix.PubSub.broadcast(@pubsub, topic(state.id), {:trip_updated, snapshot})
    {:reply, {:ok, snapshot}, state}
  end

  @doc false
  # Builds the plain-map view of the trip that LiveViews render. All derived
  # values (per-meal shares, member balances, suggested settlements) are
  # computed here so the UI never has to know the math.
  def build_snapshot(state) do
    members = Enum.map(state.member_order, &Map.fetch!(state.members, &1))

    # The board shows only the meals whose cards are currently open. Closed
    # meals are still tracked — they stay in `bills` (history) and keep
    # contributing to totals, balances and settlements below.
    open_meal_ids = Enum.filter(state.meal_order, &Map.get(Map.fetch!(state.meals, &1), :open, true))
    meals = Enum.map(open_meal_ids, &decorate_meal(&1, state))
    bills = Enum.map(state.meal_order, &summarize_bill(&1, state))

    expenses = expenses_from_meals(state)

    # Meals split per PERSON (a 4-way meal divides by 4), so per-person balances
    # are computed first...
    person_balances = Splitter.balances(expenses, state.member_order)

    # ...then rolled up into BUDGETS. A budget is one or more people who pool
    # their money (e.g. a couple). Balances are owed/settled between budgets: a
    # budget's balance is the sum of its members' balances.
    budgets = build_budgets(state, person_balances)
    budget_balances = Map.new(budgets, &{&1.id, &1.balance_cents})
    budget_names = Map.new(budgets, &{&1.id, &1.name})

    settlements =
      budget_balances
      |> Splitter.settlements()
      |> Enum.map(fn %{from: f, to: t, amount_cents: a} ->
        %{from: Map.get(budget_names, f), to: Map.get(budget_names, t), amount_cents: a}
      end)

    total_cents = expenses |> Enum.map(& &1.amount_cents) |> Enum.sum()

    # Each member carries their BUDGET's balance and name, so the UI shows the
    # pooled figure everywhere.
    members_with_balance =
      Enum.map(members, fn member ->
        bid = budget_id(member)

        member
        |> Map.put(:budget_id, bid)
        |> Map.put(:balance_cents, Map.get(budget_balances, bid, 0))
        |> Map.put(:budget_name, Map.get(budget_names, bid))
      end)

    %{
      id: state.id,
      name: state.name,
      members: members_with_balance,
      budgets: budgets,
      meals: meals,
      bills: bills,
      settlements: settlements,
      total_cents: total_cents,
      member_count: length(members),
      budget_count: length(budgets),
      bill_count: length(bills)
    }
  end

  # Group members into budgets (by shared budget_id, in member order) and total
  # each budget's balance.
  defp build_budgets(state, person_balances) do
    members = Enum.map(state.member_order, &Map.fetch!(state.members, &1))
    budget_ids = members |> Enum.map(&budget_id/1) |> Enum.uniq()

    Enum.map(budget_ids, fn bid ->
      group = Enum.filter(members, &(budget_id(&1) == bid))
      names = Enum.map(group, & &1.name)

      %{
        id: bid,
        name: Enum.join(names, " & "),
        member_ids: Enum.map(group, & &1.id),
        member_names: names,
        size: length(group),
        balance_cents: group |> Enum.map(&Map.get(person_balances, &1.id, 0)) |> Enum.sum()
      }
    end)
  end

  # A member's budget defaults to their own id (a budget of one).
  defp budget_id(member), do: Map.get(member, :budget_id) || member.id

  # A compact view of a meal for the bills-history list — every meal, open or
  # closed, complete or still being filled in.
  defp summarize_bill(meal_id, state) do
    meal = Map.fetch!(state.meals, meal_id)

    %{
      id: meal.id,
      name: meal.name,
      emoji: meal.emoji,
      amount_cents: meal.amount_cents,
      participant_count: length(meal.participant_ids),
      payer_name: meal.payer_id && get_in(state.members, [meal.payer_id, :name]),
      open: Map.get(meal, :open, true),
      photo_count: length(photos(meal)),
      complete:
        meal.amount_cents > 0 and not is_nil(meal.payer_id) and meal.participant_ids != []
    }
  end

  defp decorate_meal(meal_id, state) do
    meal = Map.fetch!(state.meals, meal_id)
    locks = locked_shares(meal)
    shares = Splitter.custom_split(meal.amount_cents, meal.participant_ids, locks)

    participants =
      Enum.map(meal.participant_ids, fn mid ->
        member = Map.fetch!(state.members, mid)

        %{
          id: member.id,
          name: member.name,
          color: member.color,
          initials: member.initials,
          is_payer: meal.payer_id == mid,
          share_cents: Map.get(shares, mid, 0),
          # a "locked" participant has a manually fixed share
          locked: Map.has_key?(locks, mid)
        }
      end)

    per_head =
      case meal.participant_ids do
        [] -> 0
        ids -> div(meal.amount_cents, length(ids))
      end

    photo_views =
      Enum.map(photos(meal), fn p ->
        %{id: p.id, url: "/photos/#{state.id}/#{p.id}.jpg"}
      end)

    Map.merge(meal, %{
      participants: participants,
      per_head_cents: per_head,
      has_custom_shares: locks != %{},
      photos: photo_views,
      payer_name: meal.payer_id && get_in(state.members, [meal.payer_id, :name])
    })
  end

  # Only meals that actually represent spending contribute to the ledger:
  # they need a positive amount, someone who paid, and at least one participant.
  defp expenses_from_meals(state) do
    state.meal_order
    |> Enum.map(&Map.fetch!(state.meals, &1))
    |> Enum.filter(fn meal ->
      meal.amount_cents > 0 and not is_nil(meal.payer_id) and meal.participant_ids != []
    end)
    |> Enum.map(fn meal ->
      %{
        payer_id: meal.payer_id,
        amount_cents: meal.amount_cents,
        participant_ids: meal.participant_ids,
        # honour any custom shares when computing balances
        shares:
          Splitter.custom_split(meal.amount_cents, meal.participant_ids, locked_shares(meal))
      }
    end)
  end

  # Safe accessors for meals persisted before these fields existed.
  defp locked_shares(meal), do: Map.get(meal, :locked_shares, %{})
  defp photos(meal), do: Map.get(meal, :photos, [])
end
