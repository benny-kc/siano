defmodule Siano.Trips.Fields do
  @moduledoc """
  Pure helpers for the OCR price-fields drawn on a meal's bill photos: toggling
  a field's traveller assignment, correcting its recognised text, summing a
  traveller's assigned fields, merging/de-duping recognised boxes, and scrubbing
  references to removed members. Kept out of `Siano.Trips.TripServer` so the
  fiddly box-geometry math stays isolated and testable.
  """
  alias Siano.Trips.Money

  # Toggle the member assignment of a photo field. Returns {meal, affected_ids}
  # where affected_ids are the members whose totals need recomputing, or :error.
  def toggle_field(meal, photo_id, index, member_id) do
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
  def set_field_text(meal, photo_id, index, text) do
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
  def member_field_sum(meal, member) do
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

  # Append newly recognised fields, skipping any that land on top of a field that
  # is already there (so a region re-scan never duplicates a box).
  def merge_fields(existing, incoming) do
    Enum.reduce(incoming, existing, fn f, acc ->
      f = %{text: f.text, x: f.x, y: f.y, w: f.w, h: f.h}
      if Enum.any?(acc, &field_near?(&1, f)), do: acc, else: acc ++ [f]
    end)
  end

  # Remove overlapping/duplicate fields from a list, keeping the first — but if a
  # later duplicate is assigned to a traveller and the kept one is not, keep the
  # assigned one so no assignment is lost. Cleans up trips saved before dedup.
  def dedup_fields(fields) do
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
  def choose_candidate(candidates, target) do
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

  # Remove every reference to a member that is no longer in the trip from a meal:
  # participants, payer, locked shares and photo-field assignments. Keeps a
  # removed traveller from crashing the snapshot (Map.fetch! on a missing id) or
  # skewing the split. `valid` is a MapSet of current member ids.
  def prune_meal_members(meal, valid) do
    payer = if meal.payer_id && MapSet.member?(valid, meal.payer_id), do: meal.payer_id, else: nil

    photos =
      Enum.map(photos(meal), fn p ->
        fields =
          Enum.map(Map.get(p, :fields, []), fn f ->
            if Map.get(f, :member_id) && not MapSet.member?(valid, f.member_id),
              do: Map.put(f, :member_id, nil),
              else: f
          end)

        Map.put(p, :fields, fields)
      end)

    meal
    |> Map.put(:participant_ids, Enum.filter(meal.participant_ids, &MapSet.member?(valid, &1)))
    |> Map.put(:payer_id, payer)
    |> Map.put(:locked_shares, Map.filter(locked_shares(meal), fn {k, _} -> MapSet.member?(valid, k) end))
    |> Map.put(:photos, photos)
  end

  # Safe accessors for meals persisted before these fields existed.
  defp locked_shares(meal), do: Map.get(meal, :locked_shares, %{})
  defp photos(meal), do: Map.get(meal, :photos, [])
end
