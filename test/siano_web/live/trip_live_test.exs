defmodule SianoWeb.TripLiveTest do
  use SianoWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "the board renders the seeded travellers", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/t/render-test")
    assert html =~ "Siano"
    assert html =~ "Ala"
    assert html =~ "Travellers"
  end

  test "adding a meal shows a new card", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/t/meal-test")
    refute render(view) =~ "drop travellers here"

    html = view |> element("header button", "Meal") |> render_click()
    assert html =~ "drop travellers here"
  end

  test "closing a meal keeps it in the bills history and re-opening restores it", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/t/history-test")

    render_click(view, "add_meal", %{})
    meal_id = extract_meal_id(view)
    member_id = extract_member_id(view)

    # complete the bill so it has a tracked cost
    render_hook(view, "set_amount", %{"meal_id" => meal_id, "value" => "12.00"})
    render_hook(view, "drop_on_meal", %{"meal_id" => meal_id, "member_id" => member_id})
    render_hook(view, "set_payer", %{"meal_id" => meal_id, "member_id" => member_id})

    # closing hides the card but preserves the cost (still shown in the total)
    html = render_click(view, "close_meal", %{"id" => meal_id})
    refute html =~ ~s(id="meal-#{meal_id}")
    assert html =~ "12.00"

    # re-opening from history brings the card back onto the board
    html = render_click(view, "open_meal", %{"id" => meal_id})
    assert html =~ ~s(id="meal-#{meal_id}")
  end

  test "dropping a traveller onto a meal splits the cost", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/t/drop-test")

    # grab the seeded member + a freshly added meal id from the socket state
    render_click(view, "add_meal", %{})
    meal_id = extract_meal_id(view)
    member_id = extract_member_id(view)

    render(view) |> then(&assert &1 =~ "Total tracked")

    view |> render_hook("set_amount", %{"meal_id" => meal_id, "value" => "30.00"})
    view |> render_hook("drop_on_meal", %{"meal_id" => meal_id, "member_id" => member_id})
    html = view |> render_hook("set_payer", %{"meal_id" => meal_id, "member_id" => member_id})

    # the sole participant paid, so the whole amount is tracked
    assert html =~ "30.00"
  end

  defp extract_meal_id(view) do
    [_, id] = Regex.run(~r/id="meal-(meal-\d+)"/, render(view))
    id
  end

  defp extract_member_id(view) do
    [_, id] = Regex.run(~r/id="traveller-(m-\d+)"/, render(view))
    id
  end
end
