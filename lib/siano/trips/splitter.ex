defmodule Siano.Trips.Splitter do
  @moduledoc """
  Pure, dependency-free money math for splitting shared travel costs.

  All amounts are handled as **integer cents** to avoid floating point
  rounding errors. The public functions here never touch process state,
  which makes them trivial to unit test in isolation.
  """

  @typedoc "An amount of money expressed in integer cents."
  @type cents :: non_neg_integer()

  @doc """
  Split `amount_cents` evenly across the given `participant_ids`.

  The base share is `div(amount, n)`. Any leftover cents (the remainder of
  the division) are handed out one-at-a-time to the first participants so
  that the individual shares always sum **exactly** back to the original
  amount — nobody magically loses or gains a cent.

  Returns a map of `participant_id => cents_owed`.

      iex> Siano.Trips.Splitter.even_split(1000, [:a, :b, :c])
      %{a: 334, b: 333, c: 333}
  """
  @spec even_split(cents(), [term()]) :: %{optional(term()) => cents()}
  def even_split(_amount_cents, []), do: %{}

  def even_split(amount_cents, participant_ids)
      when is_integer(amount_cents) and amount_cents >= 0 do
    n = length(participant_ids)
    base = div(amount_cents, n)
    remainder = rem(amount_cents, n)

    participant_ids
    |> Enum.with_index()
    |> Map.new(fn {id, index} ->
      share = if index < remainder, do: base + 1, else: base
      {id, share}
    end)
  end

  @doc """
  Split `amount_cents` across `participant_ids`, honouring any **locked** shares.

  `locked` is a map of `member_id => cents` for participants whose share has
  been set to an exact amount. Those amounts are taken out of the bill first
  (clamped so they can never, in aggregate, exceed the total), and everyone
  *without* a locked share splits whatever is left, equally. If every
  participant is locked, any leftover is placed on the first participant.

  The result therefore **always sums to exactly `amount_cents`** — the bill
  total is invariant; only how it is divided changes.

      iex> Siano.Trips.Splitter.custom_split(3000, [:a, :b, :c], %{a: 1800})
      %{a: 1800, b: 600, c: 600}
  """
  @spec custom_split(cents(), [term()], %{optional(term()) => integer()}) ::
          %{optional(term()) => cents()}
  def custom_split(amount_cents, participant_ids, locked \\ %{})

  def custom_split(_amount_cents, [], _locked), do: %{}

  def custom_split(amount_cents, participant_ids, locked)
      when is_integer(amount_cents) and amount_cents >= 0 do
    locked_ids = Enum.filter(participant_ids, &Map.has_key?(locked, &1))
    unlocked_ids = Enum.reject(participant_ids, &Map.has_key?(locked, &1))

    # Take each locked share from the budget in order, clamping so the locked
    # shares can never exceed the bill total.
    {locked_shares, spent} =
      Enum.reduce(locked_ids, {%{}, 0}, fn id, {acc, spent} ->
        want = max(0, Map.get(locked, id, 0))
        take = want |> min(amount_cents - spent) |> max(0)
        {Map.put(acc, id, take), spent + take}
      end)

    remaining = max(0, amount_cents - spent)

    cond do
      unlocked_ids != [] ->
        Map.merge(locked_shares, even_split(remaining, unlocked_ids))

      true ->
        # everyone is locked: park any leftover on the first participant so the
        # shares still add up to the total exactly
        [first | _] = participant_ids
        Map.update(locked_shares, first, remaining, &(&1 + remaining))
    end
  end

  @doc """
  Given a list of expenses, compute the net balance for every member.

  Each expense is a map with `:payer_id`, `:amount_cents` and either a
  precomputed `:shares` map (`member_id => cents`) or `:participant_ids` (which
  are then split evenly). A member's balance is:

      (total they paid on behalf of the group) - (total of their own shares)

  A **positive** balance means the group owes that member money (they are a
  creditor). A **negative** balance means the member still owes money.

  `member_ids` seeds the result so that members with no activity show up
  with a balance of `0`.
  """
  @spec balances([map()], [term()]) :: %{optional(term()) => integer()}
  def balances(expenses, member_ids \\ []) do
    seed = Map.new(member_ids, &{&1, 0})

    Enum.reduce(expenses, seed, fn expense, acc ->
      shares = Map.get(expense, :shares) || even_split(expense.amount_cents, expense.participant_ids)

      acc
      # the payer fronted the whole amount -> credit them
      |> Map.update(expense.payer_id, expense.amount_cents, &(&1 + expense.amount_cents))
      # every participant owes their share -> debit them
      |> then(fn balances ->
        Enum.reduce(shares, balances, fn {member_id, share}, inner ->
          Map.update(inner, member_id, -share, &(&1 - share))
        end)
      end)
    end)
  end

  @doc """
  Turn a map of balances into a minimal-ish list of "who pays whom" transfers
  that settles everyone up.

  Uses a simple greedy strategy: repeatedly match the biggest debtor with the
  biggest creditor. This does not guarantee the theoretical minimum number of
  transactions (that problem is NP-hard) but produces clean, intuitive
  settlements for real-world group sizes.

  Returns a list of `%{from: debtor_id, to: creditor_id, amount_cents: cents}`.
  """
  @spec settlements(%{optional(term()) => integer()}) ::
          [%{from: term(), to: term(), amount_cents: cents()}]
  def settlements(balances) do
    debtors =
      balances
      |> Enum.filter(fn {_id, amount} -> amount < 0 end)
      |> Enum.map(fn {id, amount} -> {id, -amount} end)
      |> Enum.sort_by(&elem(&1, 1), :desc)

    creditors =
      balances
      |> Enum.filter(fn {_id, amount} -> amount > 0 end)
      |> Enum.sort_by(&elem(&1, 1), :desc)

    settle(debtors, creditors, [])
  end

  defp settle([], _creditors, acc), do: Enum.reverse(acc)
  defp settle(_debtors, [], acc), do: Enum.reverse(acc)

  defp settle([{debtor, owed} | debtors], [{creditor, due} | creditors], acc) do
    transfer = min(owed, due)
    entry = %{from: debtor, to: creditor, amount_cents: transfer}

    new_debtors =
      case owed - transfer do
        0 -> debtors
        rest -> insert_sorted(debtors, {debtor, rest})
      end

    new_creditors =
      case due - transfer do
        0 -> creditors
        rest -> insert_sorted(creditors, {creditor, rest})
      end

    settle(new_debtors, new_creditors, [entry | acc])
  end

  # keep the working lists sorted by remaining amount (descending)
  defp insert_sorted(list, entry) do
    [entry | list]
    |> Enum.sort_by(&elem(&1, 1), :desc)
  end
end
