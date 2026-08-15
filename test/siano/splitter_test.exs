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

  describe "custom_split/3" do
    test "with no locks it is a plain even split" do
      assert Splitter.custom_split(3000, [:a, :b, :c]) == %{a: 1000, b: 1000, c: 1000}
    end

    test "a locked share is fixed and the rest split the remainder; total is invariant" do
      result = Splitter.custom_split(3000, [:a, :b, :c], %{a: 1800})
      assert result == %{a: 1800, b: 600, c: 600}
      assert Enum.sum(Map.values(result)) == 3000
    end

    test "locks are never clamped: they may exceed the total; unlocked get what's left" do
      # 2500 + 900 already exceed the 3000 bill, so the unlocked participant gets
      # 0 while the locked shares are honoured EXACTLY — not trimmed to fit. The
      # overshoot surfaces as the meal's diff (clamping here was the old bug).
      result = Splitter.custom_split(3000, [:a, :b, :c], %{a: 2500, b: 900})
      assert result == %{a: 2500, b: 900, c: 0}
      assert Enum.sum(Map.values(result)) == 3400
    end

    test "when everyone is locked, the declared shares stand as-is (not forced to the total)" do
      # No unlocked participant to absorb the remainder, so the shares are left
      # exactly as declared even though they sum to less than the bill; the 1000
      # gap is reported as the meal's diff, not silently redistributed.
      result = Splitter.custom_split(3000, [:a, :b], %{a: 1000, b: 1000})
      assert result == %{a: 1000, b: 1000}
      assert Enum.sum(Map.values(result)) == 2000
    end
  end

  describe "balances/2" do
    test "the payer is owed every other participant's share; their own is not tracked" do
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

    test "fixed shares that overshoot the bill total are tracked in full and still sum to zero" do
      # Bill total is 3000 but bob and carol each fix their share at 2000, so the
      # declared shares (4000) exceed the total. Each of those is a real debt to
      # the payer; the old formula credited alice only up to the 3000 total and
      # dropped the 1000 overshoot, leaving the ledger unbalanced.
      shares = %{alice: 0, bob: 2000, carol: 2000}

      expenses = [
        %{
          payer_id: :alice,
          amount_cents: 3000,
          participant_ids: [:alice, :bob, :carol],
          shares: shares
        }
      ]

      balances = Splitter.balances(expenses, [:alice, :bob, :carol])

      assert balances == %{alice: 4000, bob: -2000, carol: -2000}
      assert Enum.sum(Map.values(balances)) == 0
    end

    test "the payer's own share never becomes a debt or a credit" do
      # Alice pays and is the sole participant: nobody owes her anything.
      expenses = [
        %{payer_id: :alice, amount_cents: 2500, participant_ids: [:alice], shares: %{alice: 2500}}
      ]

      assert Splitter.balances(expenses, [:alice, :bob]) == %{alice: 0, bob: 0}
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
