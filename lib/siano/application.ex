defmodule Siano.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      SianoWeb.Telemetry,
      # PubSub carries live trip updates from a TripServer to every LiveView.
      {Phoenix.PubSub, name: Siano.PubSub},
      # Registry lets us find a trip process by its string id.
      {Registry, keys: :unique, name: Siano.Trips.Registry},
      # Disk-backed persistence so trips/bills survive restarts. Must start
      # before any trip process so trips can rehydrate their state on init.
      Siano.Trips.Store,
      # Trip processes are started on demand under this supervisor.
      {DynamicSupervisor, name: Siano.Trips.TripSupervisor, strategy: :one_for_one},
      # Start to serve requests, typically the last entry
      SianoWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Siano.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    SianoWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
