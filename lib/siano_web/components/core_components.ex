defmodule SianoWeb.CoreComponents do
  @moduledoc """
  A small set of UI components used across the app.

  This is a deliberately trimmed-down version of the components a fresh
  Phoenix project ships with — just the flash system that the layouts rely
  on. The trip board builds its own richer, game-like markup directly in the
  LiveView, so we keep this file lean and free of extra dependencies
  (no Gettext, no icon library).
  """
  use Phoenix.Component

  alias Phoenix.LiveView.JS

  @doc """
  Renders a single flash notice.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash kind={:info} phx-mounted={show("#flash")}>Welcome!</.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class={[
        "fixed top-4 right-4 z-50 w-80 max-w-[90vw] rounded-xl p-4 shadow-lg ring-1",
        "backdrop-blur transition",
        @kind == :info && "bg-emerald-500/15 text-emerald-100 ring-emerald-400/40",
        @kind == :error && "bg-rose-500/15 text-rose-100 ring-rose-400/40"
      ]}
      {@rest}
    >
      <p :if={@title} class="text-sm font-semibold"><%= @title %></p>
      <p class="text-sm leading-5"><%= msg %></p>
      <button
        type="button"
        class="absolute top-2 right-2 text-slate-300 hover:text-white"
        aria-label="close"
      >
        ×
      </button>
    </div>
    """
  end

  @doc """
  Shows the standard `:info` and `:error` flashes, plus LiveView disconnect
  and error notices.
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} title="Success!" flash={@flash} />
      <.flash kind={:error} title="Error!" flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title="We can't find the internet"
        phx-disconnected={show(".phx-client-error #client-error")}
        phx-connected={hide("#client-error")}
        hidden
      >
        Attempting to reconnect…
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title="Something went wrong!"
        phx-disconnected={show(".phx-server-error #server-error")}
        phx-connected={hide("#server-error")}
        hidden
      >
        Hang in there while we get back on track…
      </.flash>
    </div>
    """
  end

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all transform ease-out duration-200", "opacity-0 translate-y-2",
         "opacity-100 translate-y-0"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all transform ease-in duration-200", "opacity-100 translate-y-0",
         "opacity-0 translate-y-2"}
    )
  end
end
