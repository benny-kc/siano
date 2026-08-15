defmodule SianoWeb.TripLive do
  @moduledoc """
  The live "game board" for a single trip.

  Travellers are drawn as tokens you can drag onto meal cards. Dropping a
  traveller onto a meal adds them as a participant; the cost is then split
  automatically and everyone's running balance updates in real time. Because
  the whole board is backed by one `Siano.Trips.TripServer` and broadcast over
  PubSub, every browser looking at the same trip id stays in sync.
  """
  use SianoWeb, :live_view

  alias Siano.Trips
  alias SianoWeb.TripLive.Components

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       new_member: "",
       editing_share: nil,
       bills_filter: nil,
       # bills sort order — persists across drawer open/close (unlike the
       # filter); default puts newest bills at the bottom (creation order).
       bills_sort: "created_asc",
       # Deploy context for the Settings drawer's admin area, resolved once here
       # (both are static for the life of the server): MIX_ENV gates the
       # dev-only "Pull & restart" button, and on prod we instead surface the
       # deployed build's checksum (see read_build_md5/0).
       mix_env: System.get_env("MIX_ENV"),
       build_md5: read_build_md5()
     )}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    # Subscribe once, on the first (connected) mount of this trip.
    if connected?(socket) and socket.assigns[:trip_id] != id do
      Phoenix.PubSub.subscribe(Siano.PubSub, Trips.topic(id))
    end

    snapshot = Trips.get_snapshot(id)

    socket =
      socket
      |> assign(:trip_id, id)
      |> assign(:trip, snapshot)
      |> assign(:page_title, snapshot.name)

    {:noreply, socket}
  end

  # ── Events ─────────────────────────────────────────────────────────────────

  @impl true
  def handle_event("new_trip", _params, socket) do
    {:noreply, push_navigate(socket, to: ~p"/t/#{random_id()}")}
  end

  # Drawer open/close is now purely client-side (a data-attribute on :root; see
  # assets/js/lib/viewstate.js), so opening a drawer no longer round-trips. The
  # one bit of shared state that still lives here is the Bills list's
  # per-traveller filter: opening the Bills drawer fires this fire-and-forget so
  # a fresh open always shows every bill (the list is server-rendered). It never
  # blocks the slide — the drawer has already opened on the client.
  def handle_event("reset_bills_filter", _params, socket) do
    {:noreply, assign(socket, :bills_filter, nil)}
  end

  # Filter the Bills list to one traveller (their participated/paid bills).
  # Tapping the already-active traveller clears the filter. Transient view state
  # that is reset whenever the drawer opens (see reset_bills_filter above).
  def handle_event("filter_bills", %{"member_id" => id}, socket) do
    filter = if socket.assigns.bills_filter == id, do: nil, else: id
    {:noreply, assign(socket, :bills_filter, filter)}
  end

  # Choose how the Bills list is ordered. Kept as a whitelisted string (no atom
  # conversion of user input); preserved across drawer open/close. The sort
  # popover that triggers this is opened/closed purely client-side, so it just
  # sets the order and re-renders the list.
  def handle_event("set_bills_sort", %{"sort" => sort}, socket)
      when sort in ~w(name_asc name_desc created_asc created_desc cash_asc cash_desc) do
    {:noreply, assign(socket, :bills_sort, sort)}
  end

  # Ignore any unrecognised sort value rather than crash the event.
  def handle_event("set_bills_sort", _params, socket) do
    {:noreply, socket}
  end

  # Add a traveller from the Settings drawer. The drawer stays open across the
  # re-render on its own now — its open state is a client-side :root attribute
  # (see assets/js/lib/viewstate.js), which morphdom never touches.
  def handle_event("add_member", %{"name" => name}, socket) do
    {:ok, _} = Trips.add_member(socket.assigns.trip_id, name)
    {:noreply, assign(socket, :new_member, "")}
  end

  def handle_event("rename_trip", %{"value" => name}, socket) do
    {:ok, _} = Trips.rename_trip(socket.assigns.trip_id, name)
    {:noreply, socket}
  end

  def handle_event("remove_member", %{"id" => id}, socket) do
    {:ok, _} = Trips.remove_member(socket.assigns.trip_id, id)
    {:noreply, socket}
  end

  # Put a traveller into a shared budget (or back on their own).
  def handle_event("set_budget", %{"member_id" => member_id, "target" => target}, socket) do
    {:ok, _} = Trips.set_member_budget(socket.assigns.trip_id, member_id, target)
    {:noreply, socket}
  end

  def handle_event("add_meal", params, socket) do
    {:ok, _} = Trips.add_meal(socket.assigns.trip_id, params["name"] || "")
    {:noreply, socket}
  end

  # The top-bar camera: reply with a meal to attach the photo to. The client
  # passes the meal it last used (if any); on an empty board we create a fresh
  # meal and target that, so a photo can always be added in one tap.
  def handle_event("photo_target", %{"meal_id" => mid}, socket)
      when is_binary(mid) and mid != "" do
    {:reply, %{meal_id: mid}, socket}
  end

  def handle_event("photo_target", _params, socket) do
    {:ok, snapshot} = Trips.add_meal(socket.assigns.trip_id, "")
    meal_id = snapshot.meals |> List.last() |> then(&(&1 && &1.id))
    {:reply, %{meal_id: meal_id}, socket}
  end

  # The meal card's ✕ only hides the card — the bill stays in history and keeps
  # counting toward everyone's balance.
  def handle_event("close_meal", %{"id" => id}, socket) do
    {:ok, _} = Trips.close_meal(socket.assigns.trip_id, id)
    {:noreply, socket}
  end

  # Re-open a bill from the history list back onto the board, ready to edit.
  # The Bills drawer is closed on the client the instant the bill is tapped
  # (its button carries `data-siano-close`), so the card is visible — no server
  # assign needed. If the bill was *already* on the board (open), we don't move
  # it — instead we pan the board so the card is brought into view, centred
  # (handled client-side by the PanZoom hook).
  def handle_event("open_meal", %{"id" => id}, socket) do
    already_open? = Enum.any?(socket.assigns.trip.bills, &(&1.id == id and &1.open))
    {:ok, _} = Trips.open_meal(socket.assigns.trip_id, id)

    socket = if already_open?, do: push_event(socket, "pan_to_meal", %{id: id}), else: socket
    {:noreply, socket}
  end

  # Permanently delete a bill from the history (confirmed in the UI).
  def handle_event("delete_meal", %{"id" => id}, socket) do
    {:ok, _} = Trips.delete_meal(socket.assigns.trip_id, id)
    {:noreply, socket}
  end

  def handle_event("remove_photo", %{"meal_id" => meal_id, "photo_id" => photo_id}, socket) do
    {:ok, _} = Trips.remove_photo(socket.assigns.trip_id, meal_id, photo_id)
    {:noreply, socket}
  end

  # A recognised price field was tapped while a traveller is selected: assign
  # (or unassign) it to that traveller. Their custom share becomes the sum of
  # their assigned fields.
  def handle_event(
        "assign_field",
        %{"meal_id" => mid, "photo_id" => pid, "index" => index} = p,
        socket
      ) do
    {:ok, _} = Trips.assign_field(socket.assigns.trip_id, mid, pid, index, p["member_id"])
    {:noreply, socket}
  end

  # A recognised price was mistyped by OCR: the user tapped the label and fixed
  # it. Store the correction; it drives any assigned traveller's share.
  def handle_event(
        "correct_field",
        %{"meal_id" => mid, "photo_id" => pid, "index" => index} = p,
        socket
      ) do
    {:ok, _} = Trips.correct_field(socket.assigns.trip_id, mid, pid, index, p["value"] || "")
    {:noreply, socket}
  end

  def handle_event("set_amount", %{"meal_id" => meal_id, "value" => value}, socket) do
    _ = Trips.set_meal_amount(socket.assigns.trip_id, meal_id, value)
    {:noreply, socket}
  end

  # A price field on the bill photo was tapped while the Total input was focused:
  # use that field's value as the meal total.
  def handle_event(
        "set_amount_from_field",
        %{"meal_id" => mid, "photo_id" => pid, "index" => index},
        socket
      ) do
    _ = Trips.set_amount_from_field(socket.assigns.trip_id, mid, pid, index)
    {:noreply, socket}
  end

  def handle_event("rename_meal", %{"meal_id" => meal_id, "value" => value}, socket) do
    {:ok, _} = Trips.rename_meal(socket.assigns.trip_id, meal_id, value)
    {:noreply, socket}
  end

  def handle_event("set_payer", %{"meal_id" => meal_id, "member_id" => member_id}, socket) do
    {:ok, _} = Trips.set_meal_payer(socket.assigns.trip_id, meal_id, member_id)
    {:noreply, socket}
  end

  # Long-press on a participant opens an inline editor for their exact share.
  def handle_event("edit_share", %{"meal_id" => meal_id, "member_id" => member_id}, socket) do
    {:noreply, assign(socket, :editing_share, {meal_id, member_id})}
  end

  def handle_event("cancel_share", _params, socket) do
    {:noreply, assign(socket, :editing_share, nil)}
  end

  # Save a custom share (blank value clears it, back to the even split).
  def handle_event(
        "save_share",
        %{"meal_id" => meal_id, "member_id" => member_id} = params,
        socket
      ) do
    _ = Trips.set_share(socket.assigns.trip_id, meal_id, member_id, params["value"] || "")
    {:noreply, assign(socket, :editing_share, nil)}
  end

  # The core drag & drop drop event, pushed from the JS "Dropzone" hook.
  def handle_event("drop_on_meal", %{"meal_id" => meal_id, "member_id" => member_id}, socket) do
    _ = Trips.add_participant(socket.assigns.trip_id, meal_id, member_id)
    {:noreply, socket}
  end

  # Dropping a traveller on empty board space creates a new meal with them in it.
  def handle_event("drop_on_board", %{"member_id" => member_id, "x" => x, "y" => y}, socket) do
    _ = Trips.add_meal_with_participant(socket.assigns.trip_id, member_id, round(x), round(y))
    {:noreply, socket}
  end

  def handle_event(
        "remove_participant",
        %{"meal_id" => meal_id, "member_id" => member_id},
        socket
      ) do
    {:ok, _} = Trips.remove_participant(socket.assigns.trip_id, meal_id, member_id)
    {:noreply, socket}
  end

  # Persist a meal card's board position after it is dragged, pushed from the
  # JS "MovableCard" hook.
  def handle_event("move_meal", %{"meal_id" => meal_id, "x" => x, "y" => y}, socket) do
    _ = Trips.move_meal(socket.assigns.trip_id, meal_id, round(x), round(y))
    {:noreply, socket}
  end

  # Remote "pull & reload": stop the BEAM so an external supervisor (systemd,
  # a shell loop, etc.) can `git pull` and start the server again. We quit from
  # a detached process after a short delay so this reply (and the flash) still
  # flush to the browser first — the client then shows its reconnect banner
  # until the fresh server is up.
  def handle_event("restart_server", _params, socket) do
    spawn(fn ->
      Process.sleep(400)
      :c.q()
    end)

    {:noreply,
     put_flash(socket, :info, "Restarting the server… it will reconnect once it's back up.")}
  end

  # ── PubSub ─────────────────────────────────────────────────────────────────

  @impl true
  def handle_info({:trip_updated, snapshot}, socket) do
    {:noreply, assign(socket, trip: snapshot, page_title: snapshot.name)}
  end

  # ── View helpers ────────────────────────────────────────────────────────────
  # The template's view helpers (money, balance labels, field-label positioning)
  # now live next to the markup that uses them, in `SianoWeb.TripLive.Components`.

  # The deployed build's MD5, read from /siano.tgz.md5 (written by the prod
  # deploy pipeline; absent in dev and on any host that doesn't ship it). The
  # file is the standard `md5sum` shape — "<hash>  <filename>" — and we surface
  # only the hash. Returns nil when the file is missing or unreadable, so the
  # Settings drawer simply shows nothing.
  defp read_build_md5 do
    case File.read("/siano.tgz.md5") do
      {:ok, contents} ->
        case contents |> String.trim() |> String.split(~r/\s+/, parts: 2) do
          [hash | _] when hash != "" -> hash
          _ -> nil
        end

      {:error, _} ->
        nil
    end
  end

  defp random_id do
    # 8 random bytes (was 4) → a ~11-char lowercase base64url id. Trip ids are the
    # only thing guarding a board (no auth), and the URL is the share token, so a
    # longer, harder-to-guess id makes enumerating other people's trips impractical.
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false) |> String.downcase()
  end
end
