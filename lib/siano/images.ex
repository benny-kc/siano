defmodule Siano.Images do
  @moduledoc """
  Server-side image orientation for bill photos.

  Bills are photographed at any angle, so before storing one we straighten it —
  the upright orientation reads far more text (and its price overlays line up
  with what the user sees). We pick the best of the four 90° rotations by
  OCR-scoring each with `Siano.Ocr.score_bytes/1`.

  The rotation itself is done with **ImageMagick** (`magick`, or `convert` on
  ImageMagick 6), shelled out via `System.cmd/3` — no extra Hex dependency, in
  keeping with the app's minimal-deps philosophy. This used to happen on the
  client, which meant uploading the photo up to four times (once per rotation)
  just to find the right angle; doing it here means the client uploads **once**.

  Everything degrades gracefully: if ImageMagick is not installed on the host,
  or any step fails, the original bytes are returned unchanged (angle `0`) and a
  warning is logged, so uploads keep working — just without auto-straightening.

  The binary can be pinned with `SIANO_IMAGEMAGICK`; otherwise `magick` is
  preferred, then `convert`.
  """
  require Logger

  alias Siano.Ocr

  # Longest side (px) of the small copy the rotations are scored on. Scoring on a
  # downscaled copy keeps the four OCR passes cheap; the winning angle is then
  # applied to the full-resolution image for storage.
  @score_dim 900

  # If the as-is orientation already reads this well (see `Ocr.score_bytes/1`:
  # prices * 1000 + words), accept it without trying the other three rotations —
  # mirrors the old client-side early-exit so behaviour is unchanged.
  @good_enough 2000

  @doc """
  Return `{angle, upright_bytes}` for the image at `src_path`, where `angle` is
  the clockwise rotation (`0`, `90`, `180` or `270`) that scored best and
  `upright_bytes` is the image rotated by it. Falls back to `{0, original}` if
  ImageMagick is unavailable or anything goes wrong.
  """
  @spec orient_upright(String.t()) :: {non_neg_integer(), binary()}
  def orient_upright(src_path) do
    with {:ok, original} <- File.read(src_path),
         bin when is_binary(bin) <- im_bin(),
         {:ok, small} <- transform(bin, original, ["-resize", "#{@score_dim}x#{@score_dim}>"]) do
      case best_angle(bin, small) do
        0 ->
          {0, original}

        angle ->
          case transform(bin, original, ["-rotate", Integer.to_string(angle)]) do
            {:ok, upright} -> {angle, upright}
            :error -> {0, original}
          end
      end
    else
      nil ->
        Logger.info("Siano.Images: ImageMagick not found — storing bill photo as-is (no auto-straighten)")
        {0, read_or_empty(src_path)}

      other ->
        Logger.warning("Siano.Images: orientation failed (#{inspect(other)}) — storing as-is")
        {0, read_or_empty(src_path)}
    end
  rescue
    e ->
      Logger.warning("Siano.Images: orientation crashed (#{inspect(e)}) — storing as-is")
      {0, read_or_empty(src_path)}
  end

  # Score the as-is orientation first; only if it reads poorly do we try the
  # other three and keep the highest. Ties favour no rotation (0 is listed first).
  defp best_angle(bin, small) do
    base = Ocr.score_bytes(small)

    if base >= @good_enough do
      0
    else
      [{0, base} | Enum.map([90, 180, 270], fn a -> {a, score_rotated(bin, small, a)} end)]
      |> Enum.max_by(&elem(&1, 1))
      |> elem(0)
    end
  end

  defp score_rotated(bin, small, angle) do
    case transform(bin, small, ["-rotate", Integer.to_string(angle)]) do
      {:ok, rotated} -> Ocr.score_bytes(rotated)
      :error -> 0
    end
  end

  # Run one ImageMagick transform on `bytes`, returning the resulting JPEG bytes.
  # Uses temp files (ImageMagick reads/writes paths) which are always cleaned up.
  defp transform(bin, bytes, ops) do
    tmp_in = tmp_path("in")
    tmp_out = tmp_path("out")

    try do
      File.write!(tmp_in, bytes)

      case System.cmd(bin, [tmp_in] ++ ops ++ [tmp_out], stderr_to_stdout: true) do
        {_, 0} -> {:ok, File.read!(tmp_out)}
        {out, code} ->
          Logger.warning("Siano.Images: #{bin} exited #{code}: #{String.slice(out, 0, 300)}")
          :error
      end
    rescue
      e ->
        Logger.warning("Siano.Images: #{bin} failed: #{inspect(e)}")
        :error
    after
      _ = File.rm(tmp_in)
      _ = File.rm(tmp_out)
    end
  end

  defp tmp_path(tag) do
    name = "siano-img-#{tag}-#{System.unique_integer([:positive])}.jpg"
    Path.join(System.tmp_dir!(), name)
  end

  # Resolve the ImageMagick executable once per call: an explicit override, then
  # the v7 `magick`, then the v6 `convert`. Returns the resolvable name or nil.
  defp im_bin do
    case System.get_env("SIANO_IMAGEMAGICK") do
      bin when is_binary(bin) and bin != "" -> bin
      _ -> System.find_executable("magick") && "magick" || System.find_executable("convert") && "convert" || nil
    end
  end

  defp read_or_empty(path) do
    case File.read(path) do
      {:ok, bytes} -> bytes
      _ -> ""
    end
  end
end
