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
  been set to an exact amount.

  There are two regimes, depending on whether anyone is still on an *automatic*
  share:

  * **Some participants are unlocked.** Every locked amount is honoured *exactly
    as declared* — never clamped or nudged — and everyone *without* a locked
    share splits whatever is left (never less than zero), equally. When the
    locked shares fit within the bill the result **sums to exactly
    `amount_cents`**: the unlocked participants absorb the difference. If the
    locked shares already meet or exceed the total the unlocked participants get
    `0` and the overshoot surfaces as the meal's diff — the locked shares are
    still left untouched. (Clamping the locked shares to fit was the bug where
    adding a fresh, unlocked traveller silently shrank an existing fixed share.)

  * **Every participant is locked.** Each declared share is honoured *exactly as
    entered* — nothing is clamped and nothing is redistributed. This is
    deliberate: once everyone has fixed their own share there is no automatic
    participant left to absorb a mismatch, so silently nudging someone's share
    (the old behaviour, which parked the leftover on the first participant)
    would rewrite a number a user typed. Instead the shares are returned
    untouched and any gap against the bill total is surfaced elsewhere as the
    meal's *diff* (see `Siano.Trips.Snapshot`). In this regime the result may
    **not** sum to `amount_cents`.

      iex> Siano.Trips.Splitter.custom_split(3000, [:a, :b, :c], %{a: 1800})
      %{a: 1800, b: 600, c: 600}

      iex> Siano.Trips.Splitter.custom_split(3000, [:a, :b], %{a: 1800, b: 1000})
      %{a: 1800, b: 1000}

      # locked shares already exceed the total: they stay untouched (not clamped)
      # when a fresh, unlocked participant is added — the newcomer just gets 0.
      iex> Siano.Trips.Splitter.custom_split(10000, [:a, :b, :c], %{a: 7000, b: 7000})
      %{a: 7000, b: 7000, c: 0}
  """
  @spec custom_split(cents(), [term()], %{optional(term()) => integer()}) ::
          %{optional(term()) => cents()}
  def custom_split(amount_cents, participant_ids, locked \\ %{})

  def custom_split(_amount_cents, [], _locked), do: %{}

  def custom_split(amount_cents, participant_ids, locked)
      when is_integer(amount_cents) and amount_cents >= 0 do
    locked_ids = Enum.filter(participant_ids, &Map.has_key?(locked, &1))
    unlocked_ids = Enum.reject(participant_ids, &Map.has_key?(locked, &1))

    cond do
      unlocked_ids != [] ->
        # Honour every locked share EXACTLY as declared — do not clamp or nudge a
        # number a user typed. The unlocked participants then split whatever is
        # left; if the locked shares already cover (or exceed) the bill there is
        # nothing left and they split 0. Clamping the last locked share to make
        # room was the bug where adding a new, unlocked traveller silently shrank
        # an existing fixed share; any genuine overshoot is now shown as the diff.
        locked_shares = Map.new(locked_ids, fn id -> {id, max(0, Map.get(locked, id, 0))} end)
        spent = locked_shares |> Map.values() |> Enum.sum()
        remaining = max(0, amount_cents - spent)
        Map.merge(locked_shares, even_split(remaining, unlocked_ids))

      true ->
        # Everyone has a fixed share: honour each exactly as declared. The shares
        # are intentionally NOT forced to sum to the total — the difference is
        # reported as the meal's diff for the users to reconcile themselves.
        Map.new(participant_ids, fn id -> {id, max(0, Map.get(locked, id, 0))} end)
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
