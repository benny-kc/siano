defmodule Siano.Ocr do
  @moduledoc """
  Recognise price fields on a bill image using an Apache Tika server.

  Tika (with Tesseract) is asked for **hOCR** output, which — unlike plain OCR
  text — includes a bounding box for every recognised word. We keep the words
  that look like prices and return their boxes normalised to the image size
  (0..1), so the UI can overlay them at any displayed scale.

  Tesseract's recall on a whole receipt is limited, so we run **several passes**
  with different page-segmentation modes and merge the results — each mode finds
  a slightly different set of words. A user can also long-press a spot the OCR
  missed; the client sends a zoomed-in crop and we OCR just that region
  (`recognize_bytes/2` with `region: true`), which typically picks up the value.

  Configuration (all optional env vars):

    * `TIKA_URL`             — Tika base URL (default `http://localhost:9998`)
    * `SIANO_OCR_LANG`       — Tesseract language(s), e.g. `eng`, `pol+eng`
    * `SIANO_OCR_PSMS`       — comma list of page-seg modes for full images
    * `SIANO_OCR_REGION_PSMS`— comma list of page-seg modes for cropped regions

  All failures degrade gracefully to `[]`.
  """
  require Logger

  # a price-like token: digits with a 2-digit decimal part, e.g. 12.50 or 3,20
  @price ~r/\d+[.,]\d{2}/

  # Page-segmentation modes tried, in order, then merged. 4 = single column of
  # variable-size text (good for receipts), 6 = single uniform block, 11 = sparse
  # text (find as much as possible), 3 = fully automatic. For a small crop a
  # uniform-block / sparse read works best.
  @default_full_psms ["4", "6", "11"]
  @default_region_psms ["6", "11", "7"]

  @doc "OCR the image at `path` and return recognised price fields."
  @spec recognize(String.t(), keyword()) :: [map()]
  def recognize(path, opts \\ []) do
    case File.read(path) do
      {:ok, body} -> recognize_bytes(body, opts)
      err -> Logger.warning("Tika OCR unavailable: #{inspect(err)}"); []
    end
  end

  @doc """
  OCR raw image bytes across several page-segmentation passes and return the
  merged, de-duplicated price fields (normalised to the image size).

  Pass `region: true` for a small zoomed-in crop (uses crop-friendly PSMs).
  """
  @spec recognize_bytes(binary(), keyword()) :: [map()]
  def recognize_bytes(body, opts \\ []) do
    lang = Keyword.get(opts, :lang, ocr_lang())
    psms = Keyword.get(opts, :psms, (Keyword.get(opts, :region, false) && region_psms()) || full_psms())

    results =
      Enum.map(psms, fn psm ->
        case tika_hocr(body, lang, psm) do
          {:ok, html} -> {html, parse(html)}
          _ -> {nil, []}
        end
      end)

    fields = results |> Enum.flat_map(&elem(&1, 1)) |> dedup()

    log_diagnostics(results, fields, psms)
    fields
  rescue
    e ->
      Logger.warning("OCR failed: #{inspect(e)}")
      []
  catch
    kind, reason ->
      Logger.warning("OCR failed: #{inspect({kind, reason})}")
      []
  end

  defp log_diagnostics(results, fields, psms) do
    html = results |> Enum.map(&elem(&1, 0)) |> Enum.find(& &1)

    Logger.info("Tika OCR (#{length(psms)} passes): #{length(fields)} price fields")

    cond do
      fields != [] or is_nil(html) ->
        :ok

      not String.contains?(html, "TesseractOCRParser") ->
        Logger.warning(
          "Tika parsed the image but Tesseract OCR did not run (no TesseractOCRParser). " <>
            "Use the Tika '-full' image which bundles Tesseract, e.g. apache/tika:<ver>-full."
        )

      true ->
        Logger.info("Tika OCR response sample: #{sample(html)}")
    end
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

  @doc """
  Drop fields whose centres sit almost on top of one another (within ~1.5% of
  the image), keeping the first seen. Used to merge overlapping OCR passes and
  region re-scans without producing duplicate overlays.
  """
  @spec dedup([map()]) :: [map()]
  def dedup(fields) do
    fields
    |> Enum.reduce([], fn f, acc ->
      if Enum.any?(acc, &near?(&1, f)), do: acc, else: [f | acc]
    end)
    |> Enum.reverse()
  end

  defp near?(a, b) do
    abs(a.x + a.w / 2 - (b.x + b.w / 2)) < 0.015 and
      abs(a.y + a.h / 2 - (b.y + b.h / 2)) < 0.015
  end

  # ── internals ───────────────────────────────────────────────────────────────

  defp tika_hocr(body, lang, psm) do
    url = String.to_charlist(tika_url() <> "/tika")

    # Ask Tika for hOCR so we get per-word bounding boxes. The header name
    # matters: Tika maps `X-Tika-OCR<Property>` to the Tesseract config setter,
    # so it must be `X-Tika-OCROutputType`, `X-Tika-OCRLanguage`, etc.
    headers =
      [
        {~c"Accept", ~c"text/html"},
        {~c"X-Tika-OCROutputType", ~c"hocr"},
        {~c"X-Tika-OCRLanguage", String.to_charlist(lang)}
      ] ++
        if psm, do: [{~c"X-Tika-OCRPageSegMode", String.to_charlist(to_string(psm))}], else: []

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
  defp ocr_lang, do: System.get_env("SIANO_OCR_LANG", "eng")

  defp full_psms, do: psms_env("SIANO_OCR_PSMS", @default_full_psms)
  defp region_psms, do: psms_env("SIANO_OCR_REGION_PSMS", @default_region_psms)

  defp psms_env(var, default) do
    case System.get_env(var) do
      nil ->
        default

      s ->
        case s |> String.split(",", trim: true) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) do
          [] -> default
          list -> list
        end
    end
  end
end
