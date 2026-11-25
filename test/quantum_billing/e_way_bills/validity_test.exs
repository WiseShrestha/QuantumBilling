defmodule QuantumBilling.EWayBills.ValidityTest do
  use ExUnit.Case, async: true

  alias QuantumBilling.EWayBills.Validity

  describe "days/2" do
    # Rule 138(10): one day per 200 km "or part thereof".
    test "one day per 200 km, or part of one" do
      assert Validity.days(1) == 1
      assert Validity.days(200) == 1
      assert Validity.days(201) == 2
      assert Validity.days(400) == 2
      assert Validity.days(401) == 3
      assert Validity.days(1_800) == 9
    end

    test "over-dimensional cargo gets a day per 20 km" do
      assert Validity.days(20, :over_dimensional) == 1
      assert Validity.days(21, :over_dimensional) == 2
      assert Validity.days(200, :over_dimensional) == 10
    end

    # A half-filled consignment is still a bill, and a bill is good for a day.
    test "a missing distance is still a day" do
      assert Validity.days(nil) == 1
      assert Validity.days(0) == 1
    end
  end

  # Times in and out are UTC; days are counted in IST (UTC+05:30). 23:59:59
  # IST is 18:29:59 UTC.
  describe "valid_until/3" do
    test "expires at midnight IST, not at the hour it was generated" do
      # 24 Sep, 11:00 IST and 23:55 IST: both valid until the end of 25 Sep IST.
      assert Validity.valid_until(~N[2026-09-24 05:30:00], 150) == ~N[2026-09-25 18:29:59]
      assert Validity.valid_until(~N[2026-09-24 18:25:00], 150) == ~N[2026-09-25 18:29:59]
    end

    # 02:00 IST on 25 Sep is still 24 Sep in UTC. Counting from the UTC date
    # ended the bill at 23:59:59 UTC on 25 Sep (05:29:59 IST on 26 Sep), about
    # 18.5 hours early.
    test "a bill made at 02:00 IST counts from that Indian date" do
      generated = Validity.from_ist(~N[2026-09-25 02:00:00])
      assert generated == ~N[2026-09-24 20:30:00]

      valid_until = Validity.valid_until(generated, 150)

      assert Validity.to_ist(valid_until) == ~N[2026-09-26 23:59:59]
      assert valid_until == ~N[2026-09-26 18:29:59]
      assert Validity.ist_date(generated) == ~D[2026-09-25]
    end

    # 20:00 IST is 14:30 UTC on the same date. Ending at 23:59:59 UTC ran
    # 5.5 hours past midnight IST.
    test "a bill made at 20:00 IST ends at midnight IST, not midnight UTC" do
      generated = Validity.from_ist(~N[2026-09-24 20:00:00])

      valid_until = Validity.valid_until(generated, 150)

      assert Validity.to_ist(valid_until) == ~N[2026-09-25 23:59:59]
      assert valid_until == ~N[2026-09-25 18:29:59]
      assert Validity.ist_date(generated) == ~D[2026-09-24]
    end

    test "each further 200 km buys another whole day" do
      assert Validity.valid_until(~N[2026-09-24 09:00:00], 450) == ~N[2026-09-27 18:29:59]
    end

    test "takes a DateTime too" do
      assert Validity.valid_until(~U[2026-09-24 14:30:00Z], 150) == ~N[2026-09-25 18:29:59]
    end
  end

  describe "extendable?/2" do
    # Rule 138(10): from eight hours before to eight hours after expiry.
    test "is open eight hours either side of expiry, edges included" do
      valid_until = ~N[2026-09-25 18:29:59]

      assert Validity.extendable?(valid_until, NaiveDateTime.add(valid_until, -8, :hour))
      assert Validity.extendable?(valid_until, valid_until)
      assert Validity.extendable?(valid_until, NaiveDateTime.add(valid_until, 8, :hour))

      refute Validity.extendable?(valid_until, NaiveDateTime.add(valid_until, -8 * 3600 - 1))
      refute Validity.extendable?(valid_until, NaiveDateTime.add(valid_until, 8 * 3600 + 1))
    end
  end
end
