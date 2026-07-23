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

  # Traveller colours. Deliberately no yellow/amber — that is reserved for
  # non-selected bill-field borders, so a traveller never looks like a field.
  @palette ~w(#f97316 #22c55e #3b82f6 #ec4899 #a855f7 #14b8a6 #ef4444 #6366f1
              #10b981 #06b6d4 #0ea5e9 #f43f5e #d946ef #8b5cf6)
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

  @doc "Store OCR-recognised price fields for a photo (normalised boxes)."
  def set_photo_fields(id, meal_id, photo_id, fields),
    do: call(id, {:set_photo_fields, meal_id, photo_id, fields})

  @doc """
  Merge additional recognised fields into a photo (from a long-press region
  re-scan), skipping any that land on top of an existing field.
  """
  def add_fields(id, meal_id, photo_id, fields),
    do: call(id, {:add_fields, meal_id, photo_id, fields})

  @doc """
  Re-scan an existing field: replace the field at `index` with the best
  overlapping candidate from a fresh OCR of its region (keeping the traveller
  assignment), and add any other new fields found nearby.
  """
  def rescan_field(id, meal_id, photo_id, index, candidates),
    do: call(id, {:rescan_field, meal_id, photo_id, index, candidates})

  @doc """
  Toggle a recognised photo field's assignment to a traveller. The traveller's
  custom share for the meal becomes the sum of the fields assigned to them.
  """
  def assign_field(id, meal_id, photo_id, index, member_id),
    do: call(id, {:assign_field, meal_id, photo_id, index, member_id})

  @doc """
  Correct the recognised text of a photo field (OCR makes mistakes). The
  corrected value is what counts toward any assigned traveller's share.
  """
  def correct_field(id, meal_id, photo_id, index, text),
    do: call(id, {:correct_field, meal_id, photo_id, index, text})

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
        meal =
          meal
          |> Map.put_new(:open, true)
          |> Map.put_new(:locked_shares, %{})
          |> Map.put_new(:inserted_at, nil)
          |> Map.put_new(:photos, [])

        # clean up any overlapping/duplicate OCR fields saved before dedup
        deduped_photos =
          Enum.map(meal.photos, fn p ->
            Map.put(p, :fields, dedup_fields(Map.get(p, :fields, [])))
          end)

        {mid, Map.put(meal, :photos, deduped_photos)}
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
        Map.put(meal, :photos, photos(meal) ++ [%{id: photo_id, fields: []}])
      end)

    reply_and_broadcast(state)
  end

  def handle_call({:set_photo_fields, meal_id, photo_id, fields}, _from, state) do
    state =
      update_meal(state, meal_id, fn meal ->
        updated =
          Enum.map(photos(meal), fn p ->
            if p.id == photo_id, do: Map.put(p, :fields, fields), else: p
          end)

        Map.put(meal, :photos, updated)
      end)

    reply_and_broadcast(state)
  end

  def handle_call({:add_fields, meal_id, photo_id, new_fields}, _from, state) do
    state =
      update_meal(state, meal_id, fn meal ->
        updated =
          Enum.map(photos(meal), fn p ->
            if p.id == photo_id do
              Map.put(p, :fields, merge_fields(Map.get(p, :fields, []), new_fields))
            else
              p
            end
          end)

        Map.put(meal, :photos, updated)
      end)

    reply_and_broadcast(state)
  end

  def handle_call({:rescan_field, meal_id, photo_id, index, candidates}, _from, state) do
    state =
      update_meal(state, meal_id, fn meal ->
        ps = photos(meal)

        with pi when not is_nil(pi) <- Enum.find_index(ps, &(&1.id == photo_id)),
             p <- Enum.at(ps, pi),
             fields <- Map.get(p, :fields, []),
             target when not is_nil(target) <- Enum.at(fields, index) do
          best = choose_candidate(candidates, target)

          {fields, member} =
            if best do
              # keep the traveller assignment, take the improved text/box
              improved = Map.merge(target, %{text: best.text, x: best.x, y: best.y, w: best.w, h: best.h})
              {List.replace_at(fields, index, improved), Map.get(target, :member_id)}
            else
              {fields, nil}
            end

          # add any *other* prices the re-scan turned up nearby
          others = if best, do: candidates -- [best], else: candidates
          fields = merge_fields(fields, others)

          meal = Map.put(meal, :photos, List.replace_at(ps, pi, Map.put(p, :fields, fields)))

          # if the replaced field was assigned, its share follows the new value
          if member do
            sum = member_field_sum(meal, member)

            locked =
              if sum > 0,
                do: Map.put(locked_shares(meal), member, min(sum, meal.amount_cents)),
                else: Map.delete(locked_shares(meal), member)

            Map.put(meal, :locked_shares, locked)
          else
            meal
          end
        else
          _ -> meal
        end
      end)

    reply_and_broadcast(state)
  end

  def handle_call({:assign_field, meal_id, photo_id, index, member_id}, _from, state) do
    member_id =
      if is_binary(member_id) and Map.has_key?(state.members, member_id), do: member_id, else: nil

    state =
      update_meal(state, meal_id, fn meal ->
        case toggle_field(meal, photo_id, index, member_id) do
          :error ->
            meal

          {meal, affected} ->
            # For each traveller whose assignment changed, make them a
            # participant and set their custom share to the sum of their fields.
            Enum.reduce(affected, meal, fn m, acc ->
              acc = ensure_participant(acc, m)
              sum = member_field_sum(acc, m)

              locked =
                if sum > 0,
                  do: Map.put(locked_shares(acc), m, min(sum, acc.amount_cents)),
                  else: Map.delete(locked_shares(acc), m)

              Map.put(acc, :locked_shares, locked)
            end)
        end
      end)

    reply_and_broadcast(state)
  end

  def handle_call({:correct_field, meal_id, photo_id, index, text}, _from, state) do
    state =
      update_meal(state, meal_id, fn meal ->
        case set_field_text(meal, photo_id, index, text) do
          :error ->
            meal

          {meal, member} ->
            # If the field is assigned, the traveller's custom share follows the
            # corrected amount.
            if member do
              sum = member_field_sum(meal, member)

              locked =
                if sum > 0,
                  do: Map.put(locked_shares(meal), member, min(sum, meal.amount_cents)),
                  else: Map.delete(locked_shares(meal), member)

              Map.put(meal, :locked_shares, locked)
            else
              meal
            end
        end
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

    member = %{
      id: id,
      name: sanitize_name(name, "Traveller"),
      color: next_color(state),
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

  # Pick the first palette colour not already used by a current traveller, so no
  # two share one. Assigning by list position (not member count) means removing a
  # traveller frees their colour instead of shifting everyone and causing clashes.
  # If every colour is taken (more travellers than the palette), fall back to the
  # least-used one.
  defp next_color(state) do
    used = state.members |> Map.values() |> Enum.map(& &1.color)

    case Enum.find(@palette, &(&1 not in used)) do
      nil -> Enum.min_by(@palette, fn c -> Enum.count(used, &(&1 == c)) end)
      color -> color
    end
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
    budget_of = resolve_budgets(state)
    budgets = build_budgets(state, person_balances, budget_of)
    budgets_by_id = Map.new(budgets, &{&1.id, &1})
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
        bid = Map.fetch!(budget_of, member.id)
        budget = Map.fetch!(budgets_by_id, bid)

        # everyone else pooling into the same budget
        partners =
          Enum.zip(budget.member_ids, budget.member_names)
          |> Enum.reject(fn {id, _} -> id == member.id end)

        member
        |> Map.put(:budget_id, bid)
        |> Map.put(:balance_cents, Map.get(budget_balances, bid, 0))
        |> Map.put(:budget_name, Map.get(budget_names, bid))
        |> Map.put(:budget_solo, partners == [])
        |> Map.put(:budget_partner_id, (partners != [] && elem(hd(partners), 0)) || nil)
        |> Map.put(:budget_partner_names, Enum.map(partners, &elem(&1, 1)))
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

  # Group members into budgets (by resolved group, in member order) and total
  # each budget's balance.
  defp build_budgets(state, person_balances, budget_of) do
    members = Enum.map(state.member_order, &Map.fetch!(state.members, &1))
    budget_ids = members |> Enum.map(&Map.fetch!(budget_of, &1.id)) |> Enum.uniq()

    Enum.map(budget_ids, fn bid ->
      group = Enum.filter(members, &(Map.fetch!(budget_of, &1.id) == bid))
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

  # Resolve members into shared-budget groups. `budget_id` is a *directional*
  # pointer to whoever a member first pooled money with; the group is really the
  # connected component you get by following and unioning those pointers. Doing
  # it this way is robust to chains (A→B→C all pool together) and to the order
  # people were linked, and it never leaves the "root" of a shared budget looking
  # like they are on their own. Returns member_id => canonical budget id (the
  # earliest member of the group, by join order — stable across restarts).
  defp resolve_budgets(state) do
    ids = state.member_order

    find = fn find, parent, x ->
      case Map.fetch!(parent, x) do
        ^x -> x
        p -> find.(find, parent, p)
      end
    end

    parent =
      Enum.reduce(ids, Map.new(ids, &{&1, &1}), fn id, parent ->
        target = budget_id(Map.fetch!(state.members, id))

        if target != id and Map.has_key?(state.members, target) do
          ra = find.(find, parent, id)
          rb = find.(find, parent, target)
          if ra == rb, do: parent, else: Map.put(parent, ra, rb)
        else
          parent
        end
      end)

    ids
    |> Enum.group_by(fn id -> find.(find, parent, id) end)
    |> Enum.reduce(%{}, fn {_root, group}, acc ->
      canon = hd(group)
      Enum.reduce(group, acc, &Map.put(&2, &1, canon))
    end)
  end

  # A member's budget pointer defaults to their own id (a budget of one).
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
        fields =
          Enum.map(Map.get(p, :fields, []), fn f ->
            mid = Map.get(f, :member_id)

            %{
              text: f.text,
              x: f.x,
              y: f.y,
              w: f.w,
              h: f.h,
              member_id: mid,
              color: mid && get_in(state.members, [mid, :color])
            }
          end)

        %{id: p.id, url: "/photos/#{state.id}/#{p.id}.jpg", fields: fields}
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

  # Toggle the member assignment of a photo field. Returns {meal, affected_ids}
  # where affected_ids are the members whose totals need recomputing, or :error.
  defp toggle_field(meal, photo_id, index, member_id) do
    ps = photos(meal)

    with pi when not is_nil(pi) <- Enum.find_index(ps, &(&1.id == photo_id)),
         p <- Enum.at(ps, pi),
         fields <- Map.get(p, :fields, []),
         f when not is_nil(f) <- Enum.at(fields, index) do
      old = Map.get(f, :member_id)

      new =
        cond do
          is_nil(member_id) -> nil
          old == member_id -> nil
          true -> member_id
        end

      new_fields = List.replace_at(fields, index, Map.put(f, :member_id, new))
      new_ps = List.replace_at(ps, pi, Map.put(p, :fields, new_fields))
      affected = [old, new] |> Enum.uniq() |> Enum.reject(&is_nil/1)
      {Map.put(meal, :photos, new_ps), affected}
    else
      _ -> :error
    end
  end

  # Overwrite a field's recognised text. If the correction parses as an amount
  # we store it in canonical "12.50" form so the strict price extractor still
  # picks it up; otherwise the raw text is kept. Returns {meal, member_id_of_field}.
  defp set_field_text(meal, photo_id, index, text) do
    canonical =
      case Money.parse(to_string(text) |> String.trim()) do
        {:ok, cents} -> Money.format(cents)
        :error -> to_string(text) |> String.trim()
      end

    ps = photos(meal)

    with pi when not is_nil(pi) <- Enum.find_index(ps, &(&1.id == photo_id)),
         p <- Enum.at(ps, pi),
         fields <- Map.get(p, :fields, []),
         f when not is_nil(f) <- Enum.at(fields, index) do
      new_fields = List.replace_at(fields, index, Map.put(f, :text, canonical))
      new_ps = List.replace_at(ps, pi, Map.put(p, :fields, new_fields))
      {Map.put(meal, :photos, new_ps), Map.get(f, :member_id)}
    else
      _ -> :error
    end
  end

  # Sum (in cents) of all fields across the meal's photos assigned to `member`.
  defp member_field_sum(meal, member) do
    meal
    |> photos()
    |> Enum.flat_map(&Map.get(&1, :fields, []))
    |> Enum.filter(&(Map.get(&1, :member_id) == member))
    |> Enum.reduce(0, fn f, acc ->
      case Money.extract(Map.get(f, :text, "")) do
        {:ok, cents} -> acc + cents
        _ -> acc
      end
    end)
  end

  # Make sure `member` is a participant of the meal (defaulting the payer).
  defp ensure_participant(meal, member) do
    participants = add_unique(meal.participant_ids, member)
    %{meal | participant_ids: participants, payer_id: meal.payer_id || List.first(participants)}
  end

  # Append newly recognised fields, skipping any that land on top of a field that
  # is already there (so a region re-scan never duplicates a box).
  defp merge_fields(existing, incoming) do
    Enum.reduce(incoming, existing, fn f, acc ->
      f = %{text: f.text, x: f.x, y: f.y, w: f.w, h: f.h}
      if Enum.any?(acc, &field_near?(&1, f)), do: acc, else: acc ++ [f]
    end)
  end

  # Remove overlapping/duplicate fields from a list, keeping the first — but if a
  # later duplicate is assigned to a traveller and the kept one is not, keep the
  # assigned one so no assignment is lost. Cleans up trips saved before dedup.
  defp dedup_fields(fields) do
    Enum.reduce(fields, [], fn f, acc ->
      case Enum.find_index(acc, &field_near?(&1, f)) do
        nil ->
          acc ++ [f]

        i ->
          kept = Enum.at(acc, i)

          if is_nil(Map.get(kept, :member_id)) and not is_nil(Map.get(f, :member_id)),
            do: List.replace_at(acc, i, f),
            else: acc
      end
    end)
  end

  # From fresh region-OCR candidates, pick the one that best matches the field
  # being re-scanned: it must overlap the old box (so we're improving the same
  # price, not grabbing a neighbour), and of those the closest wins.
  defp choose_candidate(candidates, target) do
    candidates
    |> Enum.filter(&field_near?(&1, target))
    |> case do
      [] -> nil
      overlapping -> Enum.min_by(overlapping, &center_dist(&1, target))
    end
  end

  defp center_dist(a, b) do
    dx = a.x + a.w / 2 - (b.x + b.w / 2)
    dy = a.y + a.h / 2 - (b.y + b.h / 2)
    dx * dx + dy * dy
  end

  # Two boxes are "the same field" if they overlap substantially or their centres
  # nearly coincide — either way only one border should be drawn.
  defp field_near?(a, b) do
    ix = max(0.0, min(a.x + a.w, b.x + b.w) - max(a.x, b.x))
    iy = max(0.0, min(a.y + a.h, b.y + b.h) - max(a.y, b.y))
    inter = ix * iy
    amin = min(a.w * a.h, b.w * b.h)

    centres_close =
      abs(a.x + a.w / 2 - (b.x + b.w / 2)) < 0.02 and
        abs(a.y + a.h / 2 - (b.y + b.h / 2)) < 0.02

    centres_close or (amin > 0.0 and inter / amin > 0.4)
  end

  # Safe accessors for meals persisted before these fields existed.
  defp locked_shares(meal), do: Map.get(meal, :locked_shares, %{})
  defp photos(meal), do: Map.get(meal, :photos, [])
end
