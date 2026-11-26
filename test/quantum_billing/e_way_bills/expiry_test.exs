defmodule QuantumBilling.EWayBills.ExpiryTest do
  @moduledoc """
  Issue #80: a new bill after expiry, the Rule 138(10) validity extension and
  transport documents for Rail, Air and Ship. Demo mode throughout; the live
  portal is in `NICClientTest`.
  """
  use QuantumBilling.DataCase, async: true

  alias QuantumBilling.Audit
  alias QuantumBilling.EWayBills
  alias QuantumBilling.EWayBills.EWayBill
  alias QuantumBilling.EWayBills.EWayBillExtension
  alias QuantumBilling.Invoices
  alias QuantumBilling.Invoices.Invoice

  defp invoice_fixture do
    Repo.insert!(%Invoice{
      invoice_number: "INV-#{System.unique_integer([:positive])}",
      invoice_date: ~D[2026-03-01],
      place_of_supply: "Maharashtra",
      company_state: "Maharashtra",
      client_state: "Karnataka",
      client_name: "Acme India Pvt Ltd",
      client_gstin: "27AAAAA0000A1Z5",
      taxable_value: 100_000,
      grand_total: 118_000
    })
  end

  defp bill_fixture(invoice \\ nil, params \\ %{}) do
    {:ok, bill} =
      EWayBills.generate_e_way_bill(
        invoice || invoice_fixture(),
        Map.merge(%{"distance_km" => "180", "vehicle_number" => "MH04CD5678"}, params)
      )

    bill
  end

  # Validity comes from the clock, so it is moved relative to now.
  defp valid_until(bill, seconds_from_now) do
    valid_until =
      NaiveDateTime.utc_now()
      |> NaiveDateTime.add(seconds_from_now, :second)
      |> NaiveDateTime.truncate(:second)

    bill |> Ecto.Changeset.change(valid_until: valid_until) |> Repo.update!()
  end

  defp expire(bill), do: valid_until(bill, -24 * 3600)

  defp extension_params(overrides \\ %{}) do
    Map.merge(
      %{
        "reason" => "Natural Calamity",
        "remarks" => "Road closed by floods",
        "from_place" => "Nashik",
        "from_state" => "Maharashtra (27)",
        "from_pincode" => "422001",
        "remaining_distance_km" => "150",
        "consignment_status" => "In Movement",
        "mode_of_transport" => "Road",
        "vehicle_number" => "mh 15 ef 4321"
      },
      overrides
    )
  end

  describe "a new bill after expiry" do
    test "replaces the expired bill, which is stored as Expired in the same step" do
      invoice = invoice_fixture()
      old = invoice |> bill_fixture() |> expire()

      assert {:ok, new} =
               EWayBills.generate_e_way_bill(invoice, %{
                 "distance_km" => "100",
                 "vehicle_number" => "MH12XY9876"
               })

      assert Repo.reload!(old).status == "Expired"
      assert EWayBills.status(Repo.reload!(old)) == "Expired"
      assert new.status == "Active"
      assert EWayBills.live_bill_for_invoice(invoice.id).id == new.id
    end

    test "still refuses while the bill is valid" do
      invoice = invoice_fixture()
      _live = bill_fixture(invoice)

      assert {:error, :already_issued} = EWayBills.generate_e_way_bill(invoice, %{})
    end

    test "a bill that has only just expired no longer counts as live" do
      invoice = invoice_fixture()
      bill = invoice |> bill_fixture() |> valid_until(-5)

      assert EWayBills.live_bill_for_invoice(invoice.id) == nil
      # Still stored as Active until a new bill replaces it, so it can be extended.
      assert Repo.reload!(bill).status == "Active"
      assert EWayBills.status(bill) == "Expired"
    end

    test "the invoice is offered for a new bill again" do
      invoice = invoice_fixture()
      _bill = invoice |> bill_fixture() |> expire()

      assert invoice.id in Enum.map(Invoices.awaiting_e_way_bill(), & &1.id)
    end

    test "an invoice with an expired bill can be cancelled" do
      invoice = invoice_fixture()
      _bill = invoice |> bill_fixture() |> expire()

      assert {:ok, cancelled} = Invoices.cancel_invoice(invoice, "Order withdrawn")
      assert cancelled.status == "Cancelled"
    end

    test "an invoice with a valid bill still cannot be cancelled" do
      invoice = invoice_fixture()
      _bill = bill_fixture(invoice)

      assert {:error, :live_e_way_bill} = Invoices.cancel_invoice(invoice, "Order withdrawn")
    end

    test "the Expired and Active filters agree with the stored and derived status" do
      invoice = invoice_fixture()
      old = invoice |> bill_fixture() |> expire()
      {:ok, new} = EWayBills.generate_e_way_bill(invoice, %{"vehicle_number" => "MH12XY9876"})

      expired_ids = Enum.map(EWayBills.page(status: "Expired").rows, & &1.id)
      active_ids = Enum.map(EWayBills.page(status: "Active").rows, & &1.id)

      assert old.id in expired_ids
      refute new.id in expired_ids
      assert new.id in active_ids
      refute old.id in active_ids
    end
  end

  describe "extend_validity/2" do
    test "extends a bill eight hours before expiry" do
      bill = bill_fixture() |> valid_until(8 * 3600 - 60)

      assert {:ok, extended} = EWayBills.extend_validity(bill, extension_params())

      assert NaiveDateTime.compare(extended.valid_until, bill.valid_until) == :gt
      assert extended.vehicle_number == "MH15EF4321"
      assert [%EWayBillExtension{} = extension] = extended.extensions
      assert extension.previous_valid_until == bill.valid_until
      assert extension.valid_until == extended.valid_until
      assert extension.reason == "Natural Calamity"
    end

    test "extends a bill that already reads as expired, up to eight hours after" do
      bill = bill_fixture() |> valid_until(-(8 * 3600) + 60)
      assert EWayBills.status(bill) == "Expired"

      assert {:ok, extended} = EWayBills.extend_validity(bill, extension_params())

      assert EWayBills.status(extended) == "Active"
      assert EWayBills.live_bill_for_invoice(bill.invoice_id).id == bill.id
    end

    test "refuses just outside the window, before and after" do
      too_early = bill_fixture() |> valid_until(8 * 3600 + 60)
      too_late = bill_fixture() |> valid_until(-(8 * 3600) - 60)

      assert {:error, :outside_extension_window} =
               EWayBills.extend_validity(too_early, extension_params())

      assert {:error, :outside_extension_window} =
               EWayBills.extend_validity(too_late, extension_params())

      assert Repo.aggregate(EWayBillExtension, :count) == 0
    end

    test "refuses a bill a newer bill has replaced" do
      invoice = invoice_fixture()
      old = invoice |> bill_fixture() |> valid_until(-60)
      {:ok, _new} = EWayBills.generate_e_way_bill(invoice, %{"vehicle_number" => "MH12XY9876"})

      assert {:error, :replaced} =
               EWayBills.extend_validity(Repo.reload!(old), extension_params())
    end

    test "refuses a cancelled bill" do
      bill = bill_fixture()

      {:ok, cancelled} =
        EWayBills.cancel_e_way_bill(bill, %{"cancellation_reason" => "Order Cancelled"})

      assert {:error, :already_cancelled} =
               EWayBills.extend_validity(valid_until(cancelled, 60), extension_params())
    end

    test "keeps a history of every extension and writes an audit entry" do
      bill = bill_fixture() |> valid_until(60)

      {:ok, once} = EWayBills.extend_validity(bill, extension_params())

      {:ok, twice} =
        EWayBills.extend_validity(
          valid_until(once, 60),
          extension_params(%{"reason" => "Accident"})
        )

      assert Enum.map(twice.extensions, & &1.reason) == ["Natural Calamity", "Accident"]

      assert Enum.any?(
               Audit.list_audit_logs(),
               &(to_string(&1.action) == "extend_e_way_bill" and
                   &1.resource_id == to_string(bill.id))
             )
    end

    test "goods waiting in transit need a place, and keep the bill's vehicle" do
      bill = bill_fixture() |> valid_until(60)

      assert {:error, %Ecto.Changeset{} = changeset} =
               EWayBills.extend_validity(
                 bill,
                 extension_params(%{"consignment_status" => "In Transit"})
               )

      assert "can't be blank" in errors_on(changeset).address

      assert {:ok, extended} =
               EWayBills.extend_validity(
                 bill,
                 extension_params(%{
                   "consignment_status" => "In Transit",
                   "transit_type" => "Warehouse",
                   "address" => "Godown 4, MIDC Ambad, Nashik"
                 })
               )

      assert extended.vehicle_number == bill.vehicle_number
      assert [%{transit_type: "Warehouse", vehicle_number: nil}] = extended.extensions
    end

    test "validates the details before the portal is asked" do
      bill = bill_fixture() |> valid_until(60)

      assert {:error, changeset} =
               EWayBills.extend_validity(
                 bill,
                 extension_params(%{"from_pincode" => "12", "remaining_distance_km" => "0"})
               )

      errors = errors_on(changeset)
      assert "must be a 6-digit PIN code" in errors.from_pincode
      assert "must be greater than 0" in errors.remaining_distance_km
      assert Repo.reload!(bill).valid_until == bill.valid_until
    end
  end

  # PR #111 review.
  describe "review fixes" do
    test "an extension checks the stored bill, not the caller's copy" do
      invoice = invoice_fixture()
      stale = invoice |> bill_fixture() |> valid_until(-60)
      {:ok, _new} = EWayBills.generate_e_way_bill(invoice, %{"vehicle_number" => "MH12XY9876"})

      # `stale` still says "Active" in memory; the row says "Expired".
      assert stale.status == "Active"
      assert {:error, :replaced} = EWayBills.extend_validity(stale, extension_params())
    end

    test "moving goods to a new vehicle keeps the old one as a leg" do
      bill = bill_fixture() |> valid_until(60)

      {:ok, extended} =
        EWayBills.extend_validity(bill, extension_params(%{"vehicle_number" => "MH15EF4321"}))

      assert [first, second] = extended.part_b_updates
      assert first.vehicle_number == "MH04CD5678"
      assert second.vehicle_number == "MH15EF4321"
      assert second.place == "Nashik"
      assert second.reason =~ "Validity extension"
    end

    test "the same vehicle adds no leg" do
      bill = bill_fixture() |> valid_until(60)

      {:ok, extended} =
        EWayBills.extend_validity(bill, extension_params(%{"vehicle_number" => "MH04CD5678"}))

      assert extended.part_b_updates == []
    end

    test "the distance left cannot be more than the bill's distance" do
      bill = bill_fixture() |> valid_until(60)

      assert {:error, changeset} =
               EWayBills.extend_validity(
                 bill,
                 extension_params(%{"remaining_distance_km" => "181"})
               )

      assert "cannot be more than the bill's distance (180 km)" in errors_on(changeset).remaining_distance_km
    end

    # Raised before transport documents were recorded: Rail, but no document.
    test "a legacy Rail bill still records its first leg on a Part-B update" do
      invoice = invoice_fixture()

      legacy =
        Repo.insert!(%EWayBill{
          invoice_id: invoice.id,
          ewb_number: "191000000123",
          ewb_date: ~D[2026-03-01],
          valid_until:
            NaiveDateTime.add(NaiveDateTime.utc_now(), 86_400) |> NaiveDateTime.truncate(:second),
          distance_km: 500,
          mode_of_transport: "Rail",
          portal_mode: "demo"
        })

      assert {:ok, updated} =
               EWayBills.update_part_b(legacy, %{
                 "mode_of_transport" => "Road",
                 "vehicle_number" => "MH12AB1234",
                 "place" => "Pune"
               })

      assert [first, second] = updated.part_b_updates
      assert first.mode_of_transport == "Rail"
      assert first.transport_document_number == nil
      assert second.vehicle_number == "MH12AB1234"
    end
  end

  describe "transport modes" do
    test "Road keeps a vehicle number" do
      bill = bill_fixture()

      assert bill.mode_of_transport == "Road"
      assert bill.vehicle_number == "MH04CD5678"
    end

    for mode <- ["Rail", "Air", "Ship"] do
      test "#{mode} records the transport document and no vehicle" do
        bill =
          bill_fixture(nil, %{
            "mode_of_transport" => unquote(mode),
            "vehicle_number" => "",
            "transport_document_number" => "DOC12345",
            "transport_document_date" => "2026-03-02"
          })

        assert bill.mode_of_transport == unquote(mode)
        assert bill.vehicle_number == nil
        assert bill.transport_document_number == "DOC12345"
        assert bill.transport_document_date == ~D[2026-03-02]
      end

      test "#{mode} cannot be raised without its transport document" do
        assert {:error, %Ecto.Changeset{} = changeset} =
                 EWayBills.generate_e_way_bill(invoice_fixture(), %{
                   "mode_of_transport" => unquote(mode),
                   "distance_km" => "500"
                 })

        assert "is required for #{unquote(mode)}" in errors_on(changeset).transport_document_number
      end

      test "a Part-B move to #{mode} needs its transport document, not a vehicle" do
        bill = bill_fixture()

        assert {:error, %Ecto.Changeset{} = changeset} =
                 EWayBills.update_part_b(bill, %{"mode_of_transport" => unquote(mode)})

        errors = errors_on(changeset)
        assert "is required for #{unquote(mode)}" in errors.transport_document_number
        assert "is required for #{unquote(mode)}" in errors.transport_document_date
        refute Map.has_key?(errors, :vehicle_number)

        assert {:ok, updated} =
                 EWayBills.update_part_b(bill, %{
                   "mode_of_transport" => unquote(mode),
                   "transport_document_number" => "DOC777",
                   "transport_document_date" => "2026-03-03",
                   "place" => "Mumbai"
                 })

        assert updated.mode_of_transport == unquote(mode)
        assert updated.transport_document_number == "DOC777"
        assert List.last(updated.part_b_updates).transport_document_number == "DOC777"
      end
    end

    test "a Part-B Road leg needs a vehicle" do
      bill = bill_fixture()

      assert {:error, changeset} = EWayBills.update_part_b(bill, %{"mode_of_transport" => "Road"})
      assert "is required when the goods go by road" in errors_on(changeset).vehicle_number

      assert {:ok, updated} =
               EWayBills.update_part_b(bill, %{
                 "mode_of_transport" => "Road",
                 "vehicle_number" => "KA01AB1234"
               })

      assert updated.vehicle_number == "KA01AB1234"
    end
  end

  test "an EWayBill changeset accepts the stored Expired status" do
    assert EWayBill.changeset(%EWayBill{}, %{status: "Expired"}).errors[:status] == nil
  end
end
