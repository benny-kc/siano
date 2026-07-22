defmodule SianoWeb.PhotoController do
  @moduledoc """
  Upload and serve bill photos. Uploads are already rescaled on the client, so
  here we just validate, store the file, and attach it to the meal. Photos are
  served back from the trip's data directory.
  """
  use SianoWeb, :controller

  alias Siano.Trips
  alias Siano.Trips.Photos

  # POST /t/:id/photos  (multipart: meal_id, photo)
  def create(conn, %{"id" => trip_id, "meal_id" => meal_id, "photo" => %Plug.Upload{} = upload}) do
    if image?(upload) do
      {:ok, ^trip_id} = Trips.ensure_started(trip_id)
      photo_id = Photos.gen_id()
      Photos.save(trip_id, photo_id, upload.path)
      {:ok, _} = Trips.add_photo(trip_id, meal_id, photo_id)

      # OCR the bill (via Tika) in the background; the recognised price boxes are
      # attached when ready and the board updates live.
      stored = Photos.path(trip_id, photo_id)

      Task.start(fn ->
        case Siano.Ocr.recognize(stored) do
          [] -> :ok
          fields -> Trips.set_photo_fields(trip_id, meal_id, photo_id, fields)
        end
      end)

      json(conn, %{ok: true, id: photo_id})
    else
      conn |> put_status(:unsupported_media_type) |> json(%{ok: false, error: "not_an_image"})
    end
  end

  def create(conn, _params) do
    conn |> put_status(:bad_request) |> json(%{ok: false, error: "bad_request"})
  end

  # GET /photos/:trip_id/:id  (id is "<photo_id>.jpg")
  def show(conn, %{"trip_id" => trip_id, "id" => file}) do
    path = Photos.path(trip_id, Path.rootname(file))

    if File.exists?(path) do
      conn
      |> put_resp_content_type("image/jpeg")
      |> put_resp_header("cache-control", "private, max-age=31536000")
      |> send_file(200, path)
    else
      conn |> send_resp(404, "not found")
    end
  end

  defp image?(%Plug.Upload{content_type: "image/" <> _}), do: true
  defp image?(_), do: false
end
