defmodule Siano.Trips.Money do
  @moduledoc """
  Tiny helpers for converting between user-facing money strings and the
  integer-cents representation used everywhere internally.
  """

  @doc """
  Parse a user supplied amount string (e.g. `"42.50"`, `"7"`, `"3,20"`) into
  integer cents. Returns `{:ok, cents}` or `:error`.
  """
  @spec parse(String.t() | number()) :: {:ok, non_neg_integer()} | :error
  def parse(value) when is_integer(value) and value >= 0, do: {:ok, value * 100}

  def parse(value) when is_float(value) and value >= 0.0,
    do: {:ok, round(value * 100)}

  def parse(value) when is_binary(value) do
    normalized =
      value
      |> String.trim()
      |> String.replace(",", ".")

    case Float.parse(normalized) do
      {amount, ""} when amount >= 0.0 -> {:ok, round(amount * 100)}
      _ -> :error
    end
  end

  def parse(_), do: :error

  @doc """
  Format integer cents as a plain decimal string, e.g. `4250 -> "42.50"`.
  """
  @spec format(integer()) :: String.t()
  def format(cents) when is_integer(cents) do
    sign = if cents < 0, do: "-", else: ""
    abs_cents = abs(cents)
    whole = div(abs_cents, 100)
    frac = rem(abs_cents, 100)
    "#{sign}#{whole}.#{String.pad_leading(Integer.to_string(frac), 2, "0")}"
  end
end
