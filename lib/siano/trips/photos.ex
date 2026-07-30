defmodule Siano.Trips.Photos do
  @moduledoc """
  Filesystem storage for bill photos, kept under the same data directory as the
  trip store (so they survive restarts). Images are rescaled on the client
  before upload, so this module only reads/writes files — no image processing.
  """

  @doc "Generate a random, URL-safe photo id."
  def gen_id, do: :crypto.strong_rand_bytes(9) |> Base.url_encode64(padding: false)

  @doc "Copy an uploaded temp file into the trip's photo directory."
  def save(trip_id, photo_id, src_path) do
    dest = path(trip_id, photo_id)
    File.mkdir_p!(Path.dirname(dest))
    File.cp!(src_path, dest)
    :ok
  end

  @doc "Write already-in-memory image bytes into the trip's photo directory."
  def save_bytes(trip_id, photo_id, bytes) do
    dest = path(trip_id, photo_id)
    File.mkdir_p!(Path.dirname(dest))
    File.write!(dest, bytes)
    :ok
  end

  @doc "Delete a stored photo (best effort)."
  def delete(trip_id, photo_id) do
    _ = File.rm(path(trip_id, photo_id))
    :ok
  end

  @doc "Absolute path of a stored photo (.jpg)."
  def path(trip_id, photo_id) do
    Path.join([base_dir(), "photos", safe(trip_id), safe(photo_id) <> ".jpg"])
  end

  defp base_dir do
    System.get_env("SIANO_DATA_DIR") || Application.get_env(:siano, :data_dir, "siano_data")
  end

  # Strip anything that isn't a plain id character to prevent path traversal.
  defp safe(value), do: String.replace(to_string(value), ~r/[^A-Za-z0-9_\-]/, "")
end
