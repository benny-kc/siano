defmodule Siano.TripsTest do
  use ExUnit.Case, async: true

  alias Siano.Trips

  setup do
    # each test gets its own isolated, freshly started trip process
    id = "test-" <> Integer.to_string(System.unique_integer([:positive]))
    {:ok, ^id} = Trips.ensure_started(id, "Test Trip")
    %{id: id}
  end

  test "a new trip is seeded with travellers", %{id: id} do
    snap = Trips.get_snapshot(id)
    assert length(snap.members) == 3
    assert snap.total_cents == 0
  end

  test "the lunch example: one payer, split across participants", %{id: id} do
    snap = Trips.get_snapshot(id)
    [ala, bartek, celina] = snap.members

    {:ok, snap} = Trips.add_meal(id, "Lunch")
    meal = hd(snap.meals)

    {:ok, _} = Trips.set_meal_amount(id, meal.id, "30.00")
    {:ok, _} = Trips.add_participant(id, meal.id, ala.id)
    {:ok, _} = Trips.add_participant(id, meal.id, bartek.id)
    {:ok, _} = Trips.add_participant(id, meal.id, celina.id)
    {:ok, snap} = Trips.set_meal_payer(id, meal.id, ala.id)

    meal = hd(snap.meals)
    assert meal.per_head_cents == 1000

    balances = Map.new(snap.members, &{&1.name, &1.balance_cents})
    assert balances["Ala"] == 2000
    assert balances["Bartek"] == -1000
    assert balances["Celina"] == -1000
    assert snap.total_cents == 3000

    assert length(snap.settlements) == 2
    assert Enum.all?(snap.settlements, &(&1.to == "Ala"))
  end

  test "the first person added to a meal becomes the payer by default", %{id: id} do
    snap = Trips.get_snapshot(id)
    [ala, bartek, _celina] = snap.members

    {:ok, snap} = Trips.add_meal(id, "Snacks")
    meal = hd(snap.meals)

    {:ok, snap} = Trips.add_participant(id, meal.id, ala.id)
    meal = hd(snap.meals)
    assert Enum.find(meal.participants, & &1.is_payer).id == ala.id

    # adding more keeps the first one as payer; tapping can still change it
    {:ok, snap} = Trips.add_participant(id, meal.id, bartek.id)
    meal = hd(snap.meals)
    assert Enum.find(meal.participants, & &1.is_payer).id == ala.id

    {:ok, snap} = Trips.set_meal_payer(id, meal.id, bartek.id)
    meal = hd(snap.meals)
    assert Enum.find(meal.participants, & &1.is_payer).id == bartek.id
  end

  test "removing the payer hands the role to a remaining participant", %{id: id} do
    snap = Trips.get_snapshot(id)
    [ala, bartek, _] = snap.members

    {:ok, snap} = Trips.add_meal(id, "Drinks")
    meal = hd(snap.meals)
    {:ok, _} = Trips.add_participant(id, meal.id, ala.id)
    {:ok, _} = Trips.add_participant(id, meal.id, bartek.id)

    # ala is the default payer; removing her must not leave the meal unpaid
    {:ok, snap} = Trips.remove_participant(id, meal.id, ala.id)
    meal = hd(snap.meals)
    assert Enum.find(meal.participants, & &1.is_payer).id == bartek.id
  end

  test "a traveller's exact share can be set, others adjust, total is unchanged", %{id: id} do
    snap = Trips.get_snapshot(id)
    [ala, bartek, celina] = snap.members

    {:ok, snap} = Trips.add_meal(id, "Lunch")
    meal = hd(snap.meals)
    {:ok, _} = Trips.set_meal_amount(id, meal.id, "30.00")
    {:ok, _} = Trips.add_participant(id, meal.id, ala.id)
    {:ok, _} = Trips.add_participant(id, meal.id, bartek.id)
    {:ok, _} = Trips.add_participant(id, meal.id, celina.id)

    {:ok, snap} = Trips.set_share(id, meal.id, ala.id, "18.00")
    meal = hd(snap.meals)
    shares = Map.new(meal.participants, &{&1.name, &1.share_cents})

    assert shares == %{"Ala" => 1800, "Bartek" => 600, "Celina" => 600}
    assert Enum.sum(Map.values(shares)) == 3000
    assert Enum.find(meal.participants, &(&1.name == "Ala")).locked
    assert meal.has_custom_shares

    # balances honour the custom share: Ala paid 3000, owes 1800 -> +1200
    assert Map.new(snap.members, &{&1.name, &1.balance_cents})["Ala"] == 1200
  end

  test "clearing a custom share returns the traveller to the even split", %{id: id} do
    snap = Trips.get_snapshot(id)
    [ala, bartek, _] = snap.members

    {:ok, snap} = Trips.add_meal(id, "Dinner")
    meal = hd(snap.meals)
    {:ok, _} = Trips.set_meal_amount(id, meal.id, "20.00")
    {:ok, _} = Trips.add_participant(id, meal.id, ala.id)
    {:ok, _} = Trips.add_participant(id, meal.id, bartek.id)
    {:ok, _} = Trips.set_share(id, meal.id, ala.id, "15.00")

    {:ok, snap} = Trips.set_share(id, meal.id, ala.id, "")
    meal = hd(snap.meals)
    assert Map.new(meal.participants, &{&1.name, &1.share_cents}) == %{"Ala" => 1000, "Bartek" => 1000}
    refute meal.has_custom_shares
  end

  test "removing a participant re-splits the bill", %{id: id} do
    snap = Trips.get_snapshot(id)
    [ala, bartek, celina] = snap.members

    {:ok, snap} = Trips.add_meal(id, "Dinner")
    meal = hd(snap.meals)
    {:ok, _} = Trips.set_meal_amount(id, meal.id, "30.00")
    {:ok, _} = Trips.add_participant(id, meal.id, ala.id)
    {:ok, _} = Trips.add_participant(id, meal.id, bartek.id)
    {:ok, _} = Trips.add_participant(id, meal.id, celina.id)
    {:ok, _} = Trips.set_meal_payer(id, meal.id, ala.id)

    {:ok, snap} = Trips.remove_participant(id, meal.id, celina.id)
    meal = hd(snap.meals)
    assert meal.per_head_cents == 1500
  end

  test "invalid amounts are rejected", %{id: id} do
    {:ok, snap} = Trips.add_meal(id, "Coffee")
    meal = hd(snap.meals)
    assert {:error, :invalid_amount} = Trips.set_meal_amount(id, meal.id, "not money")
  end

  test "closing a meal hides its card but keeps the bill and its cost", %{id: id} do
    snap = Trips.get_snapshot(id)
    [ala, bartek, _celina] = snap.members

    {:ok, snap} = Trips.add_meal(id, "Taxi")
    meal = hd(snap.meals)
    {:ok, _} = Trips.set_meal_amount(id, meal.id, "20.00")
    {:ok, _} = Trips.add_participant(id, meal.id, ala.id)
    {:ok, _} = Trips.add_participant(id, meal.id, bartek.id)
    {:ok, _} = Trips.set_meal_payer(id, meal.id, ala.id)

    {:ok, snap} = Trips.close_meal(id, meal.id)

    # gone from the board...
    assert snap.meals == []
    # ...but preserved in history and still counted
    assert length(snap.bills) == 1
    assert hd(snap.bills).open == false
    assert snap.total_cents == 2000
    assert Map.new(snap.members, &{&1.name, &1.balance_cents})["Ala"] == 1000
  end

  test "a trip's bills and costs survive a process restart (persistence)", %{id: id} do
    snap = Trips.get_snapshot(id)
    [ala, bartek, _] = snap.members

    {:ok, snap} = Trips.add_meal(id, "Hotel")
    meal = hd(snap.meals)
    {:ok, _} = Trips.set_meal_amount(id, meal.id, "100.00")
    {:ok, _} = Trips.add_participant(id, meal.id, ala.id)
    {:ok, _} = Trips.add_participant(id, meal.id, bartek.id)
    {:ok, _} = Trips.set_meal_payer(id, meal.id, ala.id)
    # also close it, to prove even history-only costs persist
    {:ok, _} = Trips.close_meal(id, meal.id)

    # simulate a server restart: kill the trip process, then start it again.
    [{pid, _}] = Registry.lookup(Siano.Trips.Registry, id)
    ref = Process.monitor(pid)
    DynamicSupervisor.terminate_child(Siano.Trips.TripSupervisor, pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1000

    # a fresh process rehydrates from disk
    {:ok, ^id} = Trips.ensure_started(id)
    snap = Trips.get_snapshot(id)

    assert snap.total_cents == 10_000
    assert length(snap.bills) == 1
    assert hd(snap.bills).open == false
    assert Map.new(snap.members, &{&1.name, &1.balance_cents})["Ala"] == 5000
  end

  test "re-opening a bill from history restores its card ready to edit", %{id: id} do
    snap = Trips.get_snapshot(id)
    [ala | _] = snap.members

    {:ok, snap} = Trips.add_meal(id, "Museum")
    meal = hd(snap.meals)
    {:ok, _} = Trips.set_meal_amount(id, meal.id, "8.00")
    {:ok, _} = Trips.add_participant(id, meal.id, ala.id)
    {:ok, _} = Trips.close_meal(id, meal.id)

    {:ok, snap} = Trips.open_meal(id, meal.id)
    reopened = hd(snap.meals)
    assert reopened.id == meal.id
    assert reopened.amount_cents == 800
  end
end
