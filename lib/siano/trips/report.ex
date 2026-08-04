defmodule Siano.Trips.Report do
  @moduledoc """
  Builds a flat, spreadsheet-shaped **report** of the whole trip — every bill,
  each traveller's share of it, who paid, and the running totals/balances — so a
  human can eyeball that the math adds up (and keep a CSV backup of the trip).

  Two pure entry points:

  * `build/1` turns a `Siano.Trips.TripServer` state map into a plain report map
    (the bills × travellers share matrix + per-traveller paid/consumed totals).
    It is folded into every snapshot (see `Siano.Trips.Snapshot`) so the report
    overlay renders straight from the snapshot with no extra server round-trip.
  * `to_csv/2` turns a rendered snapshot (which already carries `:report`,
    `:budgets` and `:settlements`) into an RFC-4180 CSV string for download.

  Both are Phoenix-free and side-effect-free (the "generated at" clock is passed
  in), so the money projection can be unit-tested on its own like the rest of the
  domain (`Splitter`, `Money`, `Snapshot`).

  ## What "counts"

  A bill only moves money when it is **complete** — a positive total, someone who
  paid, and at least one participant — exactly the rule `Snapshot`/`Splitter`
  use for balances. Incomplete **drafts** are still listed (so nothing is hidden)
  but are excluded from the TOTAL / PAID / NET summaries, so the columns reconcile
  against the balances the app actually shows. Each traveller's `net_cents`
  (paid − consumed) equals their per-person balance, which rolls up into their
  budget's balance — the figure the settlement suggestions are built from.
  """
  alias Siano.Trips.{Splitter, Money}

  @doc """
  Project a trip's state into the report map:

      %{
        members:           [%{id, name, color, initials}],   # in display order
        bills:             [bill],                            # every meal, in creation order
        member_totals:     %{member_id => %{paid_cents, share_cents, net_cents}},
        grand_total_cents: integer,                           # complete bills only
        complete_count:    integer,
        draft_count:       integer
      }

  where each `bill` is

      %{id, name, emoji, inserted_at, payer_id, payer_name, amount_cents,
        open, complete, shares: %{member_id => cents}, assigned_cents, diff_cents}

  `shares` only holds the (still-existing) participants of that bill; a traveller
  absent from the map simply did not take part. `diff_cents` is the bill total
  minus the shares assigned (0 for an even split; non-zero only when fixed shares
  don't reconcile — the same gap the meal card shows as a red badge).
  """
  def build(state) do
    members =
      Enum.map(state.member_order, fn id ->
        m = Map.fetch!(state.members, id)
        %{id: m.id, name: m.name, color: Map.get(m, :color), initials: Map.get(m, :initials)}
      end)

    member_ids = Enum.map(members, & &1.id)

    bills = Enum.map(state.meal_order, &bill_row(&1, state))
    complete_bills = Enum.filter(bills, & &1.complete)

    member_totals =
      Map.new(member_ids, fn mid ->
        paid =
          complete_bills
          |> Enum.filter(&(&1.payer_id == mid))
          |> Enum.map(& &1.amount_cents)
          |> Enum.sum()

        share =
          complete_bills
          |> Enum.map(&Map.get(&1.shares, mid, 0))
          |> Enum.sum()

        {mid, %{paid_cents: paid, share_cents: share, net_cents: paid - share}}
      end)

    %{
      members: members,
      bills: bills,
      member_totals: member_totals,
      # `grand_total` is the cash total (sum of bill amounts) — the headline total
      # everywhere else in the app. `consumed_total` is the sum of everyone's
      # shares; the two are equal only when every bill's shares reconcile to its
      # total. Their gap is the net total below (0 when fully reconciled), which is
      # what the report is for: surfacing money the fixed shares don't account for.
      grand_total_cents: complete_bills |> Enum.map(& &1.amount_cents) |> Enum.sum(),
      consumed_total_cents: member_totals |> Map.values() |> Enum.map(& &1.share_cents) |> Enum.sum(),
      complete_count: length(complete_bills),
      draft_count: length(bills) - length(complete_bills)
    }
  end

  # One meal projected into a report row. Mirrors Snapshot.decorate_meal's
  # defences: only reference still-existing members (a removed traveller must
  # never dangle here either), and split via the same custom_split so shares
  # match the board exactly.
  defp bill_row(meal_id, state) do
    meal = Map.fetch!(state.meals, meal_id)
    participant_ids = Enum.filter(meal.participant_ids, &Map.has_key?(state.members, &1))
    locks = Map.filter(locked_shares(meal), fn {k, _} -> Map.has_key?(state.members, k) end)
    shares = Splitter.custom_split(meal.amount_cents, participant_ids, locks)
    assigned = shares |> Map.values() |> Enum.sum()

    %{
      id: meal.id,
      name: meal.name,
      emoji: meal.emoji,
      inserted_at: Map.get(meal, :inserted_at),
      payer_id: meal.payer_id,
      payer_name: meal.payer_id && get_in(state.members, [meal.payer_id, :name]),
      amount_cents: meal.amount_cents,
      open: Map.get(meal, :open, true),
      complete: meal.amount_cents > 0 and not is_nil(meal.payer_id) and participant_ids != [],
      shares: shares,
      assigned_cents: assigned,
      diff_cents: meal.amount_cents - assigned
    }
  end

  defp locked_shares(meal), do: Map.get(meal, :locked_shares, %{})

  @doc """
  Render a whole trip snapshot as a CSV string (RFC-4180, CRLF line endings).

  The snapshot must be the one from `Siano.Trips.Snapshot.build_snapshot/1`, so it
  carries `:report`, `:budgets` and `:settlements`. Pass `:generated_at` (a
  `DateTime`) to stamp the header; omit it to leave that line off (keeps the
  function pure/deterministic for tests).

  Sections, in order: trip meta · the bills × travellers share matrix with
  TOTAL/PAID/NET summary rows · per-budget balances · suggested settlements.
  """
  def to_csv(snapshot, opts \\ []) do
    report = snapshot.report
    members = report.members
    names = Enum.map(members, & &1.name)

    (meta_rows(snapshot, opts) ++
       [[]] ++
       bills_rows(report, members, names) ++
       [[]] ++
       balances_rows(snapshot, report) ++
       [[]] ++
       settlement_rows(snapshot))
    |> encode()
  end

  defp meta_rows(snapshot, opts) do
    report = snapshot.report

    stamp =
      case Keyword.get(opts, :generated_at) do
        %DateTime{} = dt -> [["Generated (UTC)", format_datetime(dt)]]
        _ -> []
      end

    [
      ["Siano trip report"],
      ["Trip", snapshot.name],
      ["Trip id", snapshot.id]
    ] ++
      stamp ++
      [
        ["Total", Money.format(report.grand_total_cents)],
        ["Bills", report.complete_count],
        ["Drafts (not counted)", report.draft_count],
        ["Travellers", length(members)]
      ]
  end

  defp bills_rows(report, members, names) do
    header = ["Bill", "Date (UTC)", "Payer", "Status", "Total"] ++ names ++ ["Assigned", "Unassigned"]

    body =
      Enum.map(report.bills, fn bill ->
        cells =
          Enum.map(members, fn m ->
            case Map.fetch(bill.shares, m.id) do
              {:ok, c} -> Money.format(c)
              :error -> ""
            end
          end)

        ["#{bill.emoji} #{bill.name}", format_date(bill.inserted_at), bill.payer_name || "",
         status(bill), Money.format(bill.amount_cents)] ++
          cells ++ [Money.format(bill.assigned_cents), Money.format(bill.diff_cents)]
      end)

    totals = fn key ->
      Enum.map(members, fn m -> Money.format(get_in(report.member_totals, [m.id, key]) || 0) end)
    end

    net_total = report.grand_total_cents - report.consumed_total_cents

    summary = [
      ["Consumed (share)", "", "", "", Money.format(report.consumed_total_cents)] ++
        totals.(:share_cents) ++ ["", ""],
      ["Paid", "", "", "", Money.format(report.grand_total_cents)] ++
        totals.(:paid_cents) ++ ["", ""],
      ["Net (paid − consumed)", "", "", "", Money.format(net_total)] ++
        totals.(:net_cents) ++ ["", ""]
    ]

    [["Bills — each traveller's share"], header] ++ body ++ summary
  end

  defp balances_rows(snapshot, report) do
    header = ["Budget", "Members", "Paid", "Consumed", "Balance", "Direction"]

    body =
      Enum.map(snapshot.budgets, fn budget ->
        paid = sum_totals(report, budget.member_ids, :paid_cents)
        consumed = sum_totals(report, budget.member_ids, :share_cents)

        [budget.name, Enum.join(budget.member_names, ", "), Money.format(paid),
         Money.format(consumed), Money.format(budget.balance_cents), direction(budget.balance_cents)]
      end)

    [["Balances — per budget"], header] ++ body
  end

  defp settlement_rows(snapshot) do
    header = ["From", "To", "Amount"]

    body =
      case snapshot.settlements do
        [] -> [["Everyone is settled up"]]
        list -> Enum.map(list, &[&1.from, &1.to, Money.format(&1.amount_cents)])
      end

    [["Suggested settlements"], header] ++ body
  end

  defp sum_totals(report, member_ids, key) do
    member_ids
    |> Enum.map(&get_in(report.member_totals, [&1, key]))
    |> Enum.map(&(&1 || 0))
    |> Enum.sum()
  end

  defp status(%{complete: true}), do: "complete"
  defp status(_), do: "draft"

  defp direction(cents) when cents > 0, do: "is owed"
  defp direction(cents) when cents < 0, do: "owes"
  defp direction(_), do: "settled"

  @doc """
  Format a meal's `inserted_at` (unix seconds, UTC) as `YYYY-MM-DD HH:MM`, or
  `""` when it is missing (older persisted meals predate the field).
  """
  def format_date(nil), do: ""

  def format_date(unix) when is_integer(unix) do
    case DateTime.from_unix(unix) do
      {:ok, dt} -> format_datetime(dt)
      _ -> ""
    end
  end

  defp format_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")

  # ── RFC-4180 CSV encoding ───────────────────────────────────────────────────
  # A field is quoted only when it must be (contains a comma, quote or newline);
  # embedded quotes are doubled. CRLF line endings, as the spec prescribes, so
  # the file opens cleanly in Excel/Numbers/Sheets.
  defp encode(rows), do: Enum.map_join(rows, "\r\n", &encode_row/1) <> "\r\n"

  defp encode_row(cells), do: Enum.map_join(cells, ",", &encode_cell/1)

  defp encode_cell(nil), do: ""

  defp encode_cell(value) do
    string = to_string(value)

    if String.contains?(string, [",", "\"", "\n", "\r"]) do
      "\"" <> String.replace(string, "\"", "\"\"") <> "\""
    else
      string
    end
  end
end
