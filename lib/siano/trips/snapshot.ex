defmodule Siano.Trips.Snapshot do
  @moduledoc """
  Builds the plain-map snapshot that every `LiveView` renders, from a
  `Siano.Trips.TripServer` state map. Pure (no process, no state) so the derived
  money math — per-meal shares, per-budget balances, suggested settlements — can
  be read and tested on its own. `TripServer` calls `build_snapshot/1` after
  every mutation, and `budget_id/1` when re-pointing a member's shared budget.
  """
  alias Siano.Trips.Report
  alias Siano.Trips.Splitter

  @doc false
  # Builds the plain-map view of the trip that LiveViews render. All derived
  # values (per-meal shares, member balances, suggested settlements) are
  # computed here so the UI never has to know the math.
  def build_snapshot(state) do
    members = Enum.map(state.member_order, &Map.fetch!(state.members, &1))

    # The board shows only the meals whose cards are currently open. Closed
    # meals are still tracked — they stay in `bills` (history) and keep
    # contributing to totals, balances and settlements below.
    open_meal_ids =
      Enum.filter(state.meal_order, &Map.get(Map.fetch!(state.meals, &1), :open, true))

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
      bill_count: length(bills),
      # A flat, spreadsheet-shaped projection (bills × travellers share matrix +
      # per-traveller totals) for the report overlay and CSV download. Folded in
      # here so the overlay renders straight from the snapshot with no extra
      # round-trip — see Siano.Trips.Report.
      report: Report.build(state)
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
  def budget_id(member), do: Map.get(member, :budget_id) || member.id

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
      # every still-existing member involved in this bill (participants + payer),
      # so the Bills drawer can filter the list by traveller
      member_ids:
        [meal.payer_id | meal.participant_ids]
        |> Enum.reject(&is_nil/1)
        |> Enum.filter(&Map.has_key?(state.members, &1))
        |> Enum.uniq(),
      payer_name: meal.payer_id && get_in(state.members, [meal.payer_id, :name]),
      open: Map.get(meal, :open, true),
      photo_count: length(photos(meal)),
      complete: meal.amount_cents > 0 and not is_nil(meal.payer_id) and meal.participant_ids != []
    }
  end

  defp decorate_meal(meal_id, state) do
    meal = Map.fetch!(state.meals, meal_id)
    # defend against any stale reference to a removed member so one bad id can
    # never bring down the whole trip's render
    participant_ids = Enum.filter(meal.participant_ids, &Map.has_key?(state.members, &1))
    locks = Map.filter(locked_shares(meal), fn {k, _} -> Map.has_key?(state.members, k) end)
    shares = Splitter.custom_split(meal.amount_cents, participant_ids, locks)

    participants =
      Enum.map(participant_ids, fn mid ->
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
      case participant_ids do
        [] -> 0
        ids -> div(meal.amount_cents, length(ids))
      end

    # Every participant has a fixed (locked) share — nobody is left on an
    # automatic share to absorb a mismatch. Only then is the diff meaningful:
    # while someone is still automatic, `custom_split` makes the shares balance
    # exactly (diff == 0), so the field would be a distracting zero.
    all_shares_fixed =
      participant_ids != [] and Enum.all?(participant_ids, &Map.has_key?(locks, &1))

    # How far the declared shares are from covering the bill. Positive => the
    # payer is still out of pocket (more needs declaring); negative => the
    # participants have collectively claimed more than the bill. Zero is the goal.
    share_sum = shares |> Map.values() |> Enum.sum()
    diff_cents = meal.amount_cents - share_sum

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
      all_shares_fixed: all_shares_fixed,
      diff_cents: diff_cents,
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
