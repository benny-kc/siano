defmodule Siano.Ocr do
  @moduledoc """
  Recognise price fields on a bill image using an Apache Tika server.

  Tika (with Tesseract) is asked for **hOCR** output, which — unlike plain OCR
  text — includes a bounding box for every recognised word. We keep the words
  that look like prices and return their boxes normalised to the image size
  (0..1), so the UI can overlay them at any displayed scale.

  The Tika endpoint defaults to `http://localhost:9998` (override with the
  `TIKA_URL` env var). All failures degrade gracefully to `[]`.
  """
  require Logger

  # a price-like token: digits with a 2-digit decimal part, e.g. 12.50 or 3,20
  @price ~r/\d+[.,]\d{2}/

  @doc "OCR the image at `path` and return recognised price fields."
  @spec recognize(String.t()) :: [map()]
  def recognize(path) do
    with {:ok, body} <- File.read(path),
         {:ok, html} <- tika_hocr(body) do
      fields = parse(html)

      Logger.info(
        "Tika OCR: #{byte_size(html)} bytes, contains bbox=#{String.contains?(html, "bbox")}, " <>
          "ocrx_word=#{String.contains?(html, "ocrx_word")}, price fields=#{length(fields)}"
      )

      cond do
        fields != [] ->
          :ok

        not String.contains?(html, "TesseractOCRParser") ->
          Logger.warning(
            "Tika parsed the image but Tesseract OCR did not run (no TesseractOCRParser). " <>
              "Use the Tika '-full' image which bundles Tesseract, e.g. apache/tika:<ver>-full."
          )

        true ->
          # OCR ran but no price boxes were found — log a snippet of the format.
          Logger.info("Tika OCR response sample: #{sample(html)}")
      end

      fields
    else
      err ->
        Logger.warning("Tika OCR unavailable: #{inspect(err)}")
        []
    end
  rescue
    e ->
      Logger.warning("OCR failed: #{inspect(e)}")
      []
  catch
    kind, reason ->
      Logger.warning("OCR failed: #{inspect({kind, reason})}")
      []
  end

  defp sample(html) do
    html |> String.replace(~r/\s+/, " ") |> String.slice(0, 600)
  end

  @doc """
  Parse a Tika/Tesseract hOCR HTML string into normalised price fields:
  `[%{text, x, y, w, h}]` where coordinates are fractions of the image size.
  """
  @spec parse(binary()) :: [map()]
  def parse(html) do
    {page_w, page_h} = page_dims(html)

    if page_w == 0 or page_h == 0 do
      []
    else
      ~r/class=['"]ocrx_word['"][^>]*?bbox\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)[^>]*>(.*?)<\/span>/s
      |> Regex.scan(html)
      |> Enum.map(fn [_, x0, y0, x1, y1, inner] ->
        %{
          text: inner |> strip_tags() |> unescape() |> String.trim(),
          x0: to_i(x0),
          y0: to_i(y0),
          x1: to_i(x1),
          y1: to_i(y1)
        }
      end)
      |> Enum.filter(&(&1.x1 > &1.x0 and &1.y1 > &1.y0 and Regex.match?(@price, &1.text)))
      |> Enum.map(fn f ->
        %{
          text: f.text,
          x: Float.round(f.x0 / page_w, 4),
          y: Float.round(f.y0 / page_h, 4),
          w: Float.round((f.x1 - f.x0) / page_w, 4),
          h: Float.round((f.y1 - f.y0) / page_h, 4)
        }
      end)
    end
  end

  # ── internals ───────────────────────────────────────────────────────────────

  defp tika_hocr(body) do
    url = String.to_charlist(tika_url() <> "/tika")

    # Ask Tika for hOCR output so we get per-word bounding boxes (not just text).
    # The header name matters: Tika maps `X-Tika-OCR<Property>` to the Tesseract
    # config setter, so it must be `X-Tika-OCROutputType`.
    headers = [
      {~c"Accept", ~c"text/html"},
      {~c"X-Tika-OCROutputType", ~c"hocr"}
    ]

    request = {url, headers, ~c"application/octet-stream", body}
    http_opts = [{:timeout, 25_000}, {:connect_timeout, 5_000}]

    case :httpc.request(:put, request, http_opts, body_format: :binary) do
      {:ok, {{_, 200, _}, _resp_headers, resp_body}} ->
        {:ok, resp_body}

      {:ok, {{_, status, _}, _resp_headers, resp_body}} ->
        Logger.warning("Tika OCR HTTP #{status}: #{sample(resp_body)}")
        :error

      other ->
        Logger.warning("Tika OCR request failed: #{inspect(other)}")
        :error
    end
  end

  defp page_dims(html) do
    case Regex.run(~r/class=['"]ocr_page['"][^>]*?bbox\s+\d+\s+\d+\s+(\d+)\s+(\d+)/, html) do
      [_, w, h] -> {to_i(w), to_i(h)}
      _ -> {0, 0}
    end
  end

  defp strip_tags(s), do: Regex.replace(~r/<[^>]*>/, s, "")

  defp unescape(s) do
    s
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&#39;", "'")
    |> String.replace("&quot;", "\"")
  end

  defp to_i(s), do: String.to_integer(s)

  defp tika_url, do: System.get_env("TIKA_URL", "http://localhost:9998")
end
