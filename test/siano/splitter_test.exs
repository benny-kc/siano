defmodule Siano.Trips.SplitterTest do
  use ExUnit.Case, async: true

  alias Siano.Trips.Splitter

  describe "even_split/2" do
    test "splits evenly when it divides cleanly" do
      assert Splitter.even_split(900, [:a, :b, :c]) == %{a: 300, b: 300, c: 300}
    end

    test "hands leftover cents to the first participants and always sums exactly" do
      result = Splitter.even_split(1000, [:a, :b, :c])
      assert result == %{a: 334, b: 333, c: 333}
      assert Enum.sum(Map.values(result)) == 1000
    end

    test "a single participant owes the whole amount" do
      assert Splitter.even_split(4250, [:x]) == %{x: 4250}
    end

    test "no participants means nothing to split" do
      assert Splitter.even_split(500, []) == %{}
    end
  end

  describe "balances/2" do
    test "the payer is credited and every participant is debited their share" do
      expenses = [
        %{payer_id: :alice, amount_cents: 3000, participant_ids: [:alice, :bob, :carol]}
      ]

      balances = Splitter.balances(expenses, [:alice, :bob, :carol])

      assert balances == %{alice: 2000, bob: -1000, carol: -1000}
      assert Enum.sum(Map.values(balances)) == 0
    end

    test "multiple expenses net out to zero" do
      expenses = [
        %{payer_id: :alice, amount_cents: 3000, participant_ids: [:alice, :bob, :carol]},
        %{payer_id: :bob, amount_cents: 1500, participant_ids: [:alice, :bob]}
      ]

      balances = Splitter.balances(expenses, [:alice, :bob, :carol])
      assert Enum.sum(Map.values(balances)) == 0
    end

    test "members with no activity show a zero balance" do
      balances = Splitter.balances([], [:alice, :bob])
      assert balances == %{alice: 0, bob: 0}
    end
  end

  describe "settlements/1" do
    test "produces transfers that clear everyone's balance" do
      balances = %{alice: 2000, bob: -1000, carol: -1000}
      settlements = Splitter.settlements(balances)

      cleared =
        Enum.reduce(settlements, balances, fn %{from: f, to: t, amount_cents: a}, acc ->
          acc |> Map.update!(f, &(&1 + a)) |> Map.update!(t, &(&1 - a))
        end)

      assert Enum.all?(Map.values(cleared), &(&1 == 0))
    end

    test "nobody owes anything -> no settlements" do
      assert Splitter.settlements(%{a: 0, b: 0}) == []
    end
  end
end
