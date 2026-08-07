defmodule SianoWeb.PageController do
  use SianoWeb, :controller

  # The landing page ("/") has no board of its own — it decides, *on the client*,
  # which trip to drop you into:
  #
  #   * if this device remembers trips you've been on (localStorage key
  #     `siano:trips`, kept newest-first — see `TripSwitcher` in
  #     `assets/js/hooks/trips.js`), jump straight to the most recent one;
  #   * otherwise mint a fresh random trip id (same 8-byte base64url format the
  #     server uses in `TripLive.random_id/0`) and start a brand-new board.
  #
  # The choice *must* be made in the browser because localStorage never reaches
  # the server. So instead of the old server-side redirect we serve a tiny,
  # self-contained page that redirects immediately — no app.js / LiveView boot
  # needed, so it's effectively instant. If JavaScript is unavailable we fall
  # back to the shared "demo" board (the previous default) via <noscript>.
  def home(conn, _params) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, landing_html())
  end

  defp landing_html do
    """
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="robots" content="noindex" />
        <title>Siano</title>
        <noscript><meta http-equiv="refresh" content="0; url=/t/demo" /></noscript>
      </head>
      <body style="margin:0;background:#0f172a">
        <script>
          (function () {
            // Mirror the server's trip-id format (8 random bytes, base64url, no
            // padding, lowercased) so client-minted trips look like server ones.
            function newTripId() {
              var b = new Uint8Array(8);
              (window.crypto || window.msCrypto).getRandomValues(b);
              var s = "";
              for (var i = 0; i < b.length; i++) s += String.fromCharCode(b[i]);
              return btoa(s).replace(/\\+/g, "-").replace(/\\//g, "_").replace(/=+$/, "").toLowerCase();
            }
            var dest = null;
            try {
              // Newest-first; the first entry with a valid id is the latest trip
              // this device was on (see TripSwitcher.remember).
              var list = JSON.parse(localStorage.getItem("siano:trips"));
              if (Array.isArray(list)) {
                for (var i = 0; i < list.length; i++) {
                  if (list[i] && list[i].id) { dest = "/t/" + list[i].id; break; }
                }
              }
            } catch (e) {}
            if (!dest) dest = "/t/" + newTripId();
            // replace() so the bare "/" doesn't linger in history behind the trip.
            window.location.replace(dest);
          })();
        </script>
      </body>
    </html>
    """
  end
end
