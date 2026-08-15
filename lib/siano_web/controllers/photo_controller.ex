defmodule SianoWeb.PhotoController do
  @moduledoc """
  Upload and serve bill photos. Uploads are already rescaled on the client, so
  the client sends each photo exactly once; here we auto-straighten it
  server-side (`Siano.Images`), store it, and attach it to the meal. Photos are
  served back from the trip's data directory.
  """
  use SianoWeb, :controller

  alias Siano.Trips
  alias Siano.Trips.Photos

  # POST /t/:id/photos  (multipart: meal_id, photo, optional photo_id)
  def create(
        conn,
        %{"id" => trip_id, "meal_id" => meal_id, "photo" => %Plug.Upload{} = upload} = params
      ) do
    if image?(upload) do
      {:ok, ^trip_id} = Trips.ensure_started(trip_id)
      # Straighten the bill server-side (pick the best of the four 90° rotations
      # by OCR score) so the client only ever uploads the image once. Degrades
      # to the original bytes if ImageMagick is unavailable.
      {angle, bytes} = Siano.Images.orient_upright(upload.path)
      photo_id = resolve_photo_id(params)
      Photos.save_bytes(trip_id, photo_id, bytes)
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

      # `angle` lets the uploading client rotate its own local copy of the photo
      # to match the stored orientation, so it never downloads the image back.
      json(conn, %{ok: true, id: photo_id, angle: angle})
    else
      conn |> put_status(:unsupported_media_type) |> json(%{ok: false, error: "not_an_image"})
    end
  end

  def create(conn, _params) do
    conn |> put_status(:bad_request) |> json(%{ok: false, error: "bad_request"})
  end

  # POST /t/:id/photos/:photo_id/ocr_region
  # (multipart: meal_id, region = JSON {x,y,w,h} in 0..1 of the full image, photo
  # = a zoomed-in crop of that region). Re-OCRs the crop and adds any price
  # fields found, translating their coordinates back to the full image.
  def ocr_region(
        conn,
        %{
          "id" => trip_id,
          "photo_id" => photo_id,
          "meal_id" => meal_id,
          "region" => region_json,
          "photo" => %Plug.Upload{} = upload
        } = params
      ) do
    with true <- image?(upload),
         {:ok, region} <- parse_region(region_json),
         {:ok, body} <- File.read(upload.path) do
      {:ok, ^trip_id} = Trips.ensure_started(trip_id)

      fields =
        body
        |> Siano.Ocr.recognize_bytes(region: true)
        |> Enum.map(&to_full_coords(&1, region))

      # `replace` = the index of an existing field being re-scanned to improve it;
      # otherwise this is a fresh add of a missed field.
      case parse_index(params["replace"]) do
        nil -> if fields != [], do: Trips.add_fields(trip_id, meal_id, photo_id, fields)
        idx -> Trips.rescan_field(trip_id, meal_id, photo_id, idx, fields)
      end

      json(conn, %{ok: true, added: length(fields)})
    else
      _ -> conn |> put_status(:bad_request) |> json(%{ok: false, error: "bad_request"})
    end
  end

  def ocr_region(conn, _params) do
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

  # The client may supply the photo id so it can display its own local copy of
  # the upload instead of downloading the stored image back. Sanitise it the
  # same way the storage path does (and cap the length); fall back to a
  # server-generated id if it's missing or empty after sanitising.
  defp resolve_photo_id(%{"photo_id" => id}) when is_binary(id) do
    case id |> String.replace(~r/[^A-Za-z0-9_\-]/, "") |> String.slice(0, 64) do
      "" -> Photos.gen_id()
      clean -> clean
    end
  end

  defp resolve_photo_id(_params), do: Photos.gen_id()

  # Decode + sanity-check the crop's region rectangle (fractions of the full
  # image). Returns {:ok, %{x,y,w,h}} or :error.
  defp parse_region(json) do
    with {:ok, %{"x" => x, "y" => y, "w" => w, "h" => h}} <- Jason.decode(json),
         [x, y, w, h] <- Enum.map([x, y, w, h], &to_float/1),
         true <- Enum.all?([x, y, w, h], &is_float/1),
         true <-
           w > 0.0 and h > 0.0 and x >= 0.0 and y >= 0.0 and x + w <= 1.0001 and y + h <= 1.0001 do
      {:ok, %{x: x, y: y, w: w, h: h}}
    else
      _ -> :error
    end
  end

  defp to_float(n) when is_float(n), do: n
  defp to_float(n) when is_integer(n), do: n * 1.0
  defp to_float(_), do: :error

  defp parse_index(nil), do: nil

  defp parse_index(s) when is_binary(s) do
    case Integer.parse(s) do
      {i, _} when i >= 0 -> i
      _ -> nil
    end
  end

  defp parse_index(_), do: nil

  # Map a field's crop-relative coordinates (0..1 of the crop) back onto the full
  # image using the crop's region rectangle.
  defp to_full_coords(f, region) do
    %{
      text: f.text,
      x: Float.round(region.x + f.x * region.w, 4),
      y: Float.round(region.y + f.y * region.h, 4),
      w: Float.round(f.w * region.w, 4),
      h: Float.round(f.h * region.h, 4)
    }
  end
end
