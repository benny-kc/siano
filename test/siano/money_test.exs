defmodule Siano.Trips.MoneyTest do
  use ExUnit.Case, async: true

  alias Siano.Trips.Money

  describe "parse/1" do
    test "parses decimal strings into cents" do
      assert Money.parse("42.50") == {:ok, 4250}
      assert Money.parse("7") == {:ok, 700}
    end

    test "accepts a comma as the decimal separator" do
      assert Money.parse("3,20") == {:ok, 320}
    end

    test "parses integers and floats directly" do
      assert Money.parse(7) == {:ok, 700}
      assert Money.parse(7.5) == {:ok, 750}
    end

    test "rejects junk and negatives" do
      assert Money.parse("abc") == :error
      assert Money.parse("-5") == :error
    end
  end

  describe "format/1" do
    test "formats cents as a decimal string" do
      assert Money.format(4250) == "42.50"
      assert Money.format(700) == "7.00"
      assert Money.format(5) == "0.05"
    end

    test "keeps the sign for negative amounts" do
      assert Money.format(-1000) == "-10.00"
    end
  end
end
