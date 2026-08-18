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
  def csv(conn, %{"id" => trip_id}) do
    now = DateTime.utc_now()
    snapshot = Trips.get_snapshot(trip_id)
    body = Report.to_csv(snapshot, generated_at: now)

    conn
    |> put_resp_content_type("text/csv")
    |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename(snapshot, now)}"))
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(200, body)
  end

  # A friendly, filesystem-safe filename from the trip name plus a UTC
  # timestamp, e.g. "our-trip-siano-report-20260818-1432.csv". The timestamp
  # keeps repeated downloads on mobile from overwriting one another. Falls back
  # to the trip id if the name has no usable characters.
  defp filename(snapshot, now) do
    slug =
      snapshot.name
      |> to_string()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/u, "-")
      |> String.trim("-")
      |> String.slice(0, 60)

    base = if slug == "", do: snapshot.id, else: slug
    stamp = Calendar.strftime(now, "%Y%m%d-%H%M")
    "#{base}-siano-report-#{stamp}.csv"
  end
end
