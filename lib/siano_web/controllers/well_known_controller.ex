defmodule SianoWeb.WellKnownController do
  @moduledoc """
  Serves Android **Digital Asset Links** so Siano's PWA can be wrapped as a
  Trusted Web Activity (TWA) — a Play Store app that is really Chrome running
  this site full-screen, with no browser chrome. See `NATIVE.md`.

  Google's TWA verifier fetches `GET /.well-known/assetlinks.json` from this
  host and checks that it lists the Android app's package name and the SHA-256
  fingerprint(s) of the certificate the app is signed with. Only when they match
  does the app get to run the site without a browser address bar.

  Both values are deployment-specific (they depend on your keystore / Google Play
  App Signing), so they're read from the environment rather than baked in:

    * `SIANO_TWA_PACKAGE`      — the Android application id, e.g. `pl.atende.siano`
    * `SIANO_TWA_FINGERPRINTS` — one or more SHA-256 cert fingerprints
      (`AA:BB:…`), separated by commas and/or whitespace. In practice you list
      *both* your upload key and the Google Play app-signing key.

  Until both are set the endpoint returns 404 — the file is simply absent, which
  is exactly how a plain (un-wrapped) web deploy should look. Nothing here
  affects the normal web app.
  """
  use SianoWeb, :controller

  # GET /.well-known/assetlinks.json
  def assetlinks(conn, _params) do
    with package when is_binary(package) <- env("SIANO_TWA_PACKAGE"),
         [_ | _] = fingerprints <- fingerprints() do
      conn
      |> put_resp_content_type("application/json")
      |> put_resp_header("cache-control", "public, max-age=3600")
      |> send_resp(200, Jason.encode_to_iodata!(statements(package, fingerprints)))
    else
      _ -> send_resp(conn, 404, "")
    end
  end

  # The Digital Asset Links statement list (a single android_app target). Shape
  # per https://developers.google.com/digital-asset-links/v1/getting-started.
  defp statements(package, fingerprints) do
    [
      %{
        "relation" => ["delegate_permission/common.handle_all_urls"],
        "target" => %{
          "namespace" => "android_app",
          "package_name" => package,
          "sha256_cert_fingerprints" => fingerprints
        }
      }
    ]
  end

  # Split on commas/whitespace so either `A,B` or `A B` (or a multi-line value)
  # works; blanks are dropped. Returns [] when unset — which fails the `[_ | _]`
  # match above and yields a 404.
  defp fingerprints do
    (System.get_env("SIANO_TWA_FINGERPRINTS") || "")
    |> String.split(~r/[\s,]+/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  # An env var, trimmed, or nil when unset/blank.
  defp env(name) do
    case System.get_env(name) do
      nil -> nil
      value -> if String.trim(value) == "", do: nil, else: String.trim(value)
    end
  end
end
