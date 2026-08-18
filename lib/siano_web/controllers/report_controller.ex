defmodule SianoWeb.ReportController do
  @moduledoc """
  Downloadable CSV report of a trip — the same bills × travellers breakdown the
  in-app report overlay shows, but as a file the user can save as a backup or
  open in a spreadsheet to double-check the math.

  It reads the trip's current rendered snapshot (which already carries the report
  projection) and streams it back with an `attachment` disposition so the browser
  saves it instead of navigating. No trip state is mutated.
  """
  use SianoWeb, :controller

  alias Siano.Trips
  alias Siano.Trips.Report

  # GET /t/:id/report.csv
  #
  # The download is a plain browser navigation, so the server can't see the
  # phone's time zone on its own. The report link (see hooks/misc.js →
  # ReportLink) appends the browser's current `Date.getTimezoneOffset()` as
  # `?tz_offset=` (and an optional IANA `?tz=` name) at click time, so the times
  # inside the CSV land in the viewer's *current* local wall-clock — important on
  # a trip abroad, where that isn't the home zone. Absent/invalid params fall
  # back to UTC. (The downloaded *filename* is timestamped client-side via the
  # `download` attribute; the name below is just the stable fallback.)
  def csv(conn, %{"id" => trip_id} = params) do
    now = DateTime.utc_now()
    offset = tz_offset_minutes(params)
    label = tz_label(params, offset)

    snapshot = Trips.get_snapshot(trip_id)
    body = Report.to_csv(snapshot, generated_at: now, tz_offset_minutes: offset, tz_label: label)

    conn
    |> put_resp_content_type("text/csv")
    |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename(snapshot)}"))
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(200, body)
  end

  # Parse the browser's `Date.getTimezoneOffset()` (minutes, UTC − local). Only
  # whole-minute offsets within ±14h (the real-world range) are honoured; a bad
  # or absent value means UTC (0).
  defp tz_offset_minutes(params) do
    with raw when is_binary(raw) <- params["tz_offset"],
         {m, ""} <- Integer.parse(raw),
         true <- m >= -840 and m <= 840 do
      m
    else
      _ -> 0
    end
  end

  # How the zone is named in the CSV headers, e.g. "Europe/Warsaw (UTC+02:00)".
  # The offset half is always computed server-side; the optional IANA name is
  # sanitised (a scanner could pass anything) and only prefixes it.
  defp tz_label(params, offset) do
    utc = utc_offset_label(offset)

    case params["tz"] do
      name when is_binary(name) ->
        case sanitize_tz(name) do
          "" -> utc
          clean -> "#{clean} (#{utc})"
        end

      _ ->
        utc
    end
  end

  defp utc_offset_label(0), do: "UTC"

  defp utc_offset_label(offset) do
    # local = UTC − offset, so a positive UTC±HH:MM sign is the negation of the
    # getTimezoneOffset() sign (UTC+2 arrives as -120).
    total = -offset
    sign = if total >= 0, do: "+", else: "-"
    abs = Kernel.abs(total)
    hh = div(abs, 60) |> Integer.to_string() |> String.pad_leading(2, "0")
    mm = rem(abs, 60) |> Integer.to_string() |> String.pad_leading(2, "0")
    "UTC#{sign}#{hh}:#{mm}"
  end

  defp sanitize_tz(name) do
    name
    |> String.replace(~r{[^A-Za-z0-9_+\-/]}, "")
    |> String.slice(0, 40)
  end

  # A friendly, filesystem-safe filename from the trip name, e.g.
  # "our-trip-siano-report.csv". This is the stable fallback served in the
  # `Content-Disposition` header; the client (hooks/misc.js → ReportLink)
  # normally overrides it via the `download` attribute with a fresh local
  # timestamp on each click, so repeated saves don't collide. Falls back to the
  # trip id if the name has no usable characters.
  defp filename(snapshot) do
    slug =
      snapshot.name
      |> to_string()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/u, "-")
      |> String.trim("-")
      |> String.slice(0, 60)

    base = if slug == "", do: snapshot.id, else: slug
    "#{base}-siano-report.csv"
  end
end
