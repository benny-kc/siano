defmodule SianoWeb.TripLive.Components do
  @moduledoc """
  The `SianoWeb.TripLive` screen, split into one function component per section
  so each part of the UI can be read and edited on its own.

  Each `.html.heex` file under `trip_live/sections/` is embedded (via
  `embed_templates/1`) as a function component named after the file — `top_bar`,
  `board`, `dock`, `bills_drawer`, `settings`, `help`, `confirm`. The main
  `trip_live.html.heex` just composes them, passing the assigns each one needs
  (see the `<Components.* .../>` calls there).

  The small view helpers the sections use (`money`, `field_label_style`,
  `balance_label`, …) live here too, next to the markup that calls them.
  """
  use SianoWeb, :html

  alias Siano.Trips.Money

  embed_templates "sections/*"

  # ── View helpers (used by the section templates above) ──────────────────────

  defp money(cents), do: Money.format(cents)

  # Bills shown in the drawer: all of them, or — when a traveller filter is on —
  # only the ones that traveller participated in or paid for.
  defp filtered_bills(bills, nil), do: bills
  defp filtered_bills(bills, member_id), do: Enum.filter(bills, &(member_id in &1.member_ids))

  # Order the Bills list per the user's choice. `bills` arrives in creation order
  # (oldest first), so "created_asc" is the identity and "created_desc" just
  # reverses — the unknown/default clause keeps that creation order.
  defp sort_bills(bills, "name_asc"), do: Enum.sort_by(bills, &String.downcase(&1.name))
  defp sort_bills(bills, "name_desc"), do: Enum.sort_by(bills, &String.downcase(&1.name), :desc)
  defp sort_bills(bills, "created_desc"), do: Enum.reverse(bills)
  defp sort_bills(bills, "cash_asc"), do: Enum.sort_by(bills, & &1.amount_cents)
  defp sort_bills(bills, "cash_desc"), do: Enum.sort_by(bills, & &1.amount_cents, :desc)
  defp sort_bills(bills, _created_asc), do: bills

  # The six sort options, as {label, key} — order matches the menu.
  defp sort_options do
    [
      {"Name (A–Z)", "name_asc"},
      {"Name (Z–A)", "name_desc"},
      {"Date added (oldest first)", "created_asc"},
      {"Date added (newest first)", "created_desc"},
      {"Amount (low to high)", "cash_asc"},
      {"Amount (high to low)", "cash_desc"}
    ]
  end

  # Name of the member the Bills drawer is filtered to (nil-safe: returns nil if
  # there's no filter, or it points at a member that no longer exists).
  defp filter_name(_members, nil), do: nil

  defp filter_name(members, id) do
    case Enum.find(members, &(&1.id == id)) do
      nil -> nil
      m -> m.name
    end
  end

  # Position a recognised-price label beside its field (never over it). We put it
  # on whichever side of the field has more room — to the LEFT of fields in the
  # right half of the image, to the RIGHT of the rest — and vertically centre it
  # on the field. `translateY(-50%)` is kept here so the FieldLabel JS hook can
  # compose the user's drag offset on top of it. Colour matches the assigned
  # traveller (amber when unassigned).
  defp field_label_style(f) do
    top = "top: #{fpct(f.y + f.h / 2)}; transform: translateY(-50%);"

    side =
      if f.x + f.w / 2 > 0.5 do
        "right: calc(#{fpct(1.0 - f.x)} + 4px);"
      else
        "left: calc(#{fpct(f.x + f.w)} + 4px);"
      end

    color = "color: #{f.color || "#fde68a"};"
    "#{side} #{top} #{color}"
  end

  defp fpct(v), do: "#{Float.round(v * 100, 2)}%"

  # A signed, human friendly balance label (third person — for a traveller).
  defp balance_label(cents) when cents > 0, do: "is owed #{money(cents)}"
  defp balance_label(cents) when cents < 0, do: "owes #{money(-cents)}"
  defp balance_label(_), do: "settled up"

  # Second-person variant for the personal "Your ledger" panel.
  defp you_balance_label(cents) when cents > 0, do: "You are owed #{money(cents)}"
  defp you_balance_label(cents) when cents < 0, do: "You owe #{money(-cents)}"
  defp you_balance_label(_), do: "You're settled up"

  defp balance_tone(cents) when cents > 0, do: "text-emerald-400"
  defp balance_tone(cents) when cents < 0, do: "text-rose-400"
  defp balance_tone(_), do: "text-slate-400"
end
