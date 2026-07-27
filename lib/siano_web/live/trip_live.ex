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
  alias Siano.Trips.Money

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, new_member: "", editing_share: nil, drawer: nil, help: false)}
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

  # Drawer open/close is server-tracked so that re-renders (e.g. deleting a
  # bill) keep the drawer open instead of snapping it shut.
  def handle_event("open_drawer", %{"which" => which}, socket) when which in ["bills", "menu"] do
    {:noreply, assign(socket, :drawer, which)}
  end

  def handle_event("close_drawer", _params, socket) do
    {:noreply, assign(socket, :drawer, nil)}
  end

  # In-app help/how-to overlay. Server-tracked so a live update never closes it.
  def handle_event("open_help", _params, socket) do
    {:noreply, assign(socket, :help, true)}
  end

  def handle_event("close_help", _params, socket) do
    {:noreply, assign(socket, :help, false)}
  end

  # Pick "who am I" for the personal ledger. Use a plain assign (not push_patch)
  # so navigating does not reset the open Settings drawer.
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
  # Closes the Bills drawer so the card is visible.
  def handle_event("open_meal", %{"id" => id}, socket) do
    {:ok, _} = Trips.open_meal(socket.assigns.trip_id, id)
    {:noreply, assign(socket, :drawer, nil)}
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
  def handle_event("assign_field", %{"meal_id" => mid, "photo_id" => pid, "index" => index} = p, socket) do
    {:ok, _} = Trips.assign_field(socket.assigns.trip_id, mid, pid, index, p["member_id"])
    {:noreply, socket}
  end

  # A recognised price was mistyped by OCR: the user tapped the label and fixed
  # it. Store the correction; it drives any assigned traveller's share.
  def handle_event("correct_field", %{"meal_id" => mid, "photo_id" => pid, "index" => index} = p, socket) do
    {:ok, _} = Trips.correct_field(socket.assigns.trip_id, mid, pid, index, p["value"] || "")
    {:noreply, socket}
  end

  def handle_event("set_amount", %{"meal_id" => meal_id, "value" => value}, socket) do
    _ = Trips.set_meal_amount(socket.assigns.trip_id, meal_id, value)
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
  def handle_event("save_share", %{"meal_id" => meal_id, "member_id" => member_id} = params, socket) do
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

  def handle_event("remove_participant", %{"meal_id" => meal_id, "member_id" => member_id}, socket) do
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

  # ── View helpers (available to the co-located template) ─────────────────────

  defp money(cents), do: Money.format(cents)

  # Position a recognised-price label beside its field (never over it). We put it
  # on whichever side of the field has more room — to the LEFT of fields in the
  # right half of the image, to the RIGHT of the rest — and vertically centre it
  # on the field. `translateY(-50%)` is kept here so the FieldLabel JS hook can
  # compose the user's drag offset on top of it. Colour matches the assigned
  # traveller (amber when unassigned).
  defp field_label_style(f) do
    top = "top: #{fpct(f.y + f.h / 2)}; transform: translateY(-50%);"

    side =
      if f.x + f.w / 2 > 0.5 do
        "right: calc(#{fpct(1.0 - f.x)} + 4px);"
      else
        "left: calc(#{fpct(f.x + f.w)} + 4px);"
      end

    color = "color: #{f.color || "#fde68a"};"
    "#{side} #{top} #{color}"
  end

  defp fpct(v), do: "#{Float.round(v * 100, 2)}%"

  # A signed, human friendly balance label (third person — for a traveller).
  defp balance_label(cents) when cents > 0, do: "is owed #{money(cents)}"
  defp balance_label(cents) when cents < 0, do: "owes #{money(-cents)}"
  defp balance_label(_), do: "settled up"

  # Second-person variant for the personal "Your ledger" panel.
  defp you_balance_label(cents) when cents > 0, do: "You are owed #{money(cents)}"
  defp you_balance_label(cents) when cents < 0, do: "You owe #{money(-cents)}"
  defp you_balance_label(_), do: "You're settled up"

  defp balance_tone(cents) when cents > 0, do: "text-emerald-400"
  defp balance_tone(cents) when cents < 0, do: "text-rose-400"
  defp balance_tone(_), do: "text-slate-400"

  defp random_id do
    :crypto.strong_rand_bytes(4) |> Base.url_encode64(padding: false) |> String.downcase()
  end
end
