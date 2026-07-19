defmodule SianoWeb.Router do
  use SianoWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {SianoWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", SianoWeb do
    pipe_through :browser

    # Landing redirects into a shareable demo trip.
    get "/", PageController, :home
    # Everyone who opens the same trip id joins the same live board.
    live "/t/:id", TripLive, :show
  end
end
