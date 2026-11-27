defmodule QuantumBilling.EWayBills.NICClientTest do
  @moduledoc """
  Demo and live e-way bills. A live portal that fails is an error, never a
  locally minted number. Requests are stubbed with `Req.Test`.
  """
  # Not async: sets NIC_EWB_API_URL and Req's default options, which every
  # process reads.
  use QuantumBilling.DataCase, async: false

  alias QuantumBilling.EWayBills
  alias QuantumBilling.EWayBills.EWayBill
  alias QuantumBilling.EWayBills.NICClient
  alias QuantumBilling.EWayBills.Validity
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

  defp go_live do
    System.put_env("NIC_EWB_API_URL", "https://nic.example.test")
    on_exit(fn -> System.delete_env("NIC_EWB_API_URL") end)

    previous = Req.default_options()
    Req.default_options(plug: {Req.Test, __MODULE__})
    on_exit(fn -> Req.default_options(previous) end)
  end

  describe "without a portal configured" do
    test "mints a demo bill and says so" do
      refute NICClient.live?()

      assert {:ok, attrs} = NICClient.generate_ewb(invoice_fixture(), %{"distance_km" => "100"})
      assert attrs.portal_mode == "demo"
      assert attrs.ewb_number =~ ~r/^\d{12}$/
    end
  end

  describe "with a portal configured" do
    setup do
      go_live()
      :ok
    end

    test "records the portal's number as live" do
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{"status" => "1", "ewbNo" => 321_000_000_001})
      end)

      assert NICClient.live?()
      assert {:ok, bill} = EWayBills.generate_e_way_bill(invoice_fixture(), %{})
      assert bill.ewb_number == "321000000001"
      assert bill.portal_mode == "live"
      refute EWayBill.demo?(bill)
    end

    test "a portal that fails is an error, and no bill is recorded" do
      Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 503, "down") end)

      assert {:error, :portal_unavailable} =
               EWayBills.generate_e_way_bill(invoice_fixture(), %{})

      assert Repo.aggregate(EWayBill, :count) == 0
    end

    test "a portal that cannot be reached is an error" do
      Req.Test.stub(__MODULE__, fn conn -> Req.Test.transport_error(conn, :timeout) end)

      assert {:error, :portal_unavailable} = NICClient.generate_ewb(invoice_fixture(), %{})
    end

    test "an answer the client does not understand is an error" do
      Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, %{"status" => "0"}) end)

      assert {:error, :unexpected_response} = NICClient.generate_ewb(invoice_fixture(), %{})
    end

    test "the portal's own refusal is passed on" do
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{"status" => "0", "error" => "Invalid GSTIN"})
      end)

      assert {:error, {:portal_refused, "Invalid GSTIN"} = reason} =
               NICClient.generate_ewb(invoice_fixture(), %{})

      assert NICClient.error_message(reason) =~ "Invalid GSTIN"
    end

    # A demo bill does not exist on the portal; cancelling it there would fail.
    test "cancelling a demo bill does not call the portal" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, :portal_called)
        Plug.Conn.send_resp(conn, 500, "")
      end)

      bill = %EWayBill{ewb_number: "191012345678", portal_mode: "demo"}

      assert {:ok, %{"ewbNo" => "191012345678"}} =
               NICClient.cancel_ewb(bill, %{"cancellation_reason" => "Order cancelled"})

      refute_received :portal_called
    end

    test "cancelling a live bill while the portal is down is an error" do
      Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 502, "") end)

      bill = %EWayBill{ewb_number: "321000000001", portal_mode: "live"}

      assert {:error, :portal_unavailable} =
               NICClient.cancel_ewb(bill, %{"cancellation_reason" => "Order cancelled"})
    end
  end

  # Issue #80: the portal's own validity, transport documents, the 604
  # refusal on a reissue, and EXTENDVALIDITY.
  describe "a live portal, issue #80" do
    setup do
      go_live()
      :ok
    end

    # Sends each request's path and JSON body to the test, then answers.
    defp capture(answer) do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:portal, conn.request_path, Jason.decode!(raw)})
        Req.Test.json(conn, answer)
      end)
    end

    defp transit_extension do
      %{
        "reason" => "Accident",
        "remarks" => "Truck overturned",
        "from_place" => "Nashik",
        "from_state" => "Maharashtra (27)",
        "from_pincode" => "422001",
        "remaining_distance_km" => "120",
        "consignment_status" => "In Transit",
        "transit_type" => "Warehouse",
        "address" => "Godown 4, MIDC Ambad"
      }
    end

    test "stores the validity and date the portal returns, in UTC" do
      capture(%{
        "status" => "1",
        "ewayBillNo" => 331_000_000_002,
        "ewayBillDate" => "25/09/2026 02:00:00 AM",
        "validUpto" => "26/09/2026 11:59:00 PM"
      })

      assert {:ok, bill} = EWayBills.generate_e_way_bill(invoice_fixture(), %{})

      assert bill.ewb_number == "331000000002"
      # 23:59 IST on 26 Sep is 18:29 UTC; 02:00 IST is still 24 Sep in UTC.
      assert bill.valid_until == ~N[2026-09-26 18:29:00]
      assert bill.ewb_date == ~D[2026-09-25]
    end

    test "a refusal with numeric error codes is passed on, not unreadable" do
      capture(%{"status" => "0", "error" => %{"errorCodes" => 240}})
      assert {:error, {:portal_refused, detail}} = NICClient.generate_ewb(invoice_fixture(), %{})
      assert detail =~ "240"

      capture(%{"status" => "0", "error" => %{"errorCodes" => [604, 240]}})
      assert {:error, {:portal_refused, detail}} = NICClient.generate_ewb(invoice_fixture(), %{})
      assert detail =~ "error 604"
    end

    test "reads the portal's times in 12- and 24-hour forms" do
      assert NICClient.portal_time("05/01/2018 12:15:00 AM") == ~N[2018-01-04 18:45:00]
      assert NICClient.portal_time("05/01/2018 12:15:00 PM") == ~N[2018-01-05 06:45:00]
      assert NICClient.portal_time("05/01/2018 22:44:00") == ~N[2018-01-05 17:14:00]
      assert NICClient.portal_time("not a time") == nil
    end

    test "sends the transport document for Rail and no vehicle" do
      capture(%{
        "status" => "1",
        "ewayBillNo" => 331_000_000_003,
        "validUpto" => "27/09/2026 11:59:00 PM"
      })

      assert {:ok, bill} =
               EWayBills.generate_e_way_bill(invoice_fixture(), %{
                 "mode_of_transport" => "Rail",
                 "transport_document_number" => "RR998877",
                 "transport_document_date" => "2026-09-24"
               })

      assert_received {:portal, "/ewaybillapi/v1.03/gstr1/generate", payload}
      assert payload["transMode"] == 2
      assert payload["transDocNo"] == "RR998877"
      assert payload["transDocDate"] == "24/09/2026"
      assert payload["vehicleNo"] == ""
      assert bill.vehicle_number == nil
    end

    test "a portal refusing a second bill on the same document is shown, and nothing changes" do
      invoice = invoice_fixture()

      capture(%{
        "status" => "1",
        "ewayBillNo" => 331_000_000_004,
        "validUpto" => "01/01/2020 11:59:00 PM"
      })

      {:ok, expired} = EWayBills.generate_e_way_bill(invoice, %{})
      assert EWayBills.status(expired) == "Expired"

      capture(%{"status" => "0", "error" => %{"errorCodes" => "604"}})

      assert {:error, reason} = EWayBills.generate_e_way_bill(invoice, %{})
      assert NICClient.error_message(reason) =~ "error 604"
      assert NICClient.error_message(reason) =~ "Extend the existing bill"

      # Rolled back: the expired bill is not marked replaced, and no new bill.
      assert Repo.reload!(expired).status == "Active"
      assert Repo.aggregate(EWayBill, :count) == 1
    end

    test "extends on the portal with the EXTENDVALIDITY fields and stores its validity" do
      capture(%{
        "status" => "1",
        "ewayBillNo" => 331_000_000_005,
        "validUpto" => "26/11/2026 11:59:00 PM"
      })

      {:ok, bill} = EWayBills.generate_e_way_bill(invoice_fixture(), %{})

      soon = NaiveDateTime.utc_now() |> NaiveDateTime.add(3600) |> NaiveDateTime.truncate(:second)
      bill = bill |> Ecto.Changeset.change(valid_until: soon) |> Repo.update!()
      new_expiry = NaiveDateTime.add(soon, 24, :hour)

      capture(%{
        "status" => "1",
        "ewayBillNo" => 331_000_000_005,
        "validUpto" => Calendar.strftime(Validity.to_ist(new_expiry), "%d/%m/%Y %I:%M:%S %p")
      })

      assert {:ok, extended} = EWayBills.extend_validity(bill, transit_extension())

      assert_received {:portal, "/ewaybillapi/v1.03/ewayapi/extendvalidity", payload}

      assert payload["ewbNo"] == "331000000005"
      assert payload["extnRsnCode"] == 5
      assert payload["extnRemarks"] == "Truck overturned"
      assert payload["fromPlace"] == "Nashik"
      assert payload["fromState"] == 27
      assert payload["fromPincode"] == 422_001
      assert payload["remainingDistance"] == 120
      assert payload["consignmentStatus"] == "T"
      assert payload["transitType"] == "W"
      assert payload["transMode"] == "5"
      assert payload["addressLine1"] == "Godown 4, MIDC Ambad"

      assert extended.valid_until == new_expiry
    end

    test "rejects extending a bill on a cancelled invoice before calling NIC" do
      capture(%{
        "status" => "1",
        "ewayBillNo" => 331_000_000_007,
        "validUpto" => "26/11/2026 11:59:00 PM"
      })

      invoice = invoice_fixture()
      {:ok, bill} = EWayBills.generate_e_way_bill(invoice, %{})
      assert_received {:portal, _, _}

      expired =
        NaiveDateTime.utc_now() |> NaiveDateTime.add(-1, :hour) |> NaiveDateTime.truncate(:second)

      bill = bill |> Ecto.Changeset.change(valid_until: expired) |> Repo.update!()

      assert {:ok, %{status: "Cancelled"}} = Invoices.cancel_invoice(invoice, "Order cancelled")
      assert {:error, :cancelled} = EWayBills.extend_validity(bill, transit_extension())
      refute_received {:portal, _, _}

      unchanged = EWayBills.get_e_way_bill(bill.id)
      assert unchanged.valid_until == expired
      assert unchanged.extensions == []
    end

    test "a Part-B update to Ship sends the bill of lading" do
      capture(%{
        "status" => "1",
        "ewayBillNo" => 331_000_000_006,
        "validUpto" => "26/12/2099 11:59:00 PM"
      })

      {:ok, bill} = EWayBills.generate_e_way_bill(invoice_fixture(), %{})

      capture(%{"status" => "1", "vehUpdDate" => "25/11/2026 10:00:00 AM"})

      assert {:ok, _updated} =
               EWayBills.update_part_b(bill, %{
                 "mode_of_transport" => "Ship",
                 "transport_document_number" => "BOL4455",
                 "transport_document_date" => "2026-11-25",
                 "place" => "Mumbai Port"
               })

      assert_received {:portal, "/ewaybillapi/v1.03/ewayapi/vehewb", payload}
      assert payload["transMode"] == 4
      assert payload["transDocNo"] == "BOL4455"
      assert payload["transDocDate"] == "25/11/2026"
    end
  end

  test "a live bill cannot be changed once no portal is configured" do
    bill = %EWayBill{ewb_number: "321000000001", portal_mode: "live"}

    assert {:error, :portal_not_configured} =
             NICClient.update_part_b(bill, %{"vehicle_number" => "MH01AA0001"})

    assert NICClient.error_message(:portal_not_configured) =~ "Nothing was changed"
  end
end
