defmodule SianoWeb.PageController do
  use SianoWeb, :controller

  # The landing page simply drops you into a shareable "demo" trip so there is
  # always something live to play with. Share the URL and others join the same
  # board.
  def home(conn, _params) do
    redirect(conn, to: ~p"/t/demo")
  end
end
