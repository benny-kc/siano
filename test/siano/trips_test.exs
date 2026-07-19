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
end
