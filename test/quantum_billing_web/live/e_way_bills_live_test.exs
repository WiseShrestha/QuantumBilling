defmodule QuantumBillingWeb.EWayBillsLiveTest do
  @moduledoc """
  The e-way bill list: display, cancellation and vehicle changes. Bills are made
  with `EWayBills.generate_e_way_bill/2`, so they are real.
  """
  use QuantumBillingWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias QuantumBilling.EWayBills
  alias QuantumBilling.Invoices
  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Repo

  setup :register_and_log_in_user

  defp invoice(attrs) do
    defaults = %{
      invoice_number: "INV-#{System.unique_integer([:positive])}",
      invoice_date: ~D[2026-03-01],
      place_of_supply: "Maharashtra",
      company_state: "Maharashtra",
      client_state: "Karnataka",
      client_name: "Acme India Pvt Ltd",
      taxable_value: 100_000,
      grand_total: 118_000
    }

    Repo.insert!(struct(%Invoice{}, Map.merge(defaults, attrs)))
  end

  defp bill(attrs) do
    {transport, invoice_attrs} = Map.split(attrs, [:distance_km, :vehicle_number])

    {:ok, bill} =
      EWayBills.generate_e_way_bill(invoice(invoice_attrs), %{
        "distance_km" => to_string(Map.get(transport, :distance_km, 180)),
        "vehicle_number" => Map.get(transport, :vehicle_number, "MH04CD5678")
      })

    bill
  end

  # Expiry comes from the clock, so the validity is moved into the past.
  defp expire(bill) do
    bill
    |> Ecto.Changeset.change(valid_until: ~N[2020-01-01 00:00:00])
    |> Repo.update!()
  end

  test "renders the page shell", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/e-way-bills")

    assert html =~ "Track consignments and generate new e-way bills"
  end

  test "links to the generate form", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/e-way-bills")

    assert html =~ ~s(href="/e-way-bills/new")
    assert html =~ "Generate New E-Way Bill"
  end

  test "shows an empty state rather than a bare table", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/e-way-bills")

    assert html =~ "No e-way bills yet"
    refute html =~ "entries"
  end

  test "distinguishes an empty account from an empty search", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/e-way-bills")

    html = view |> form("#ewb-search", %{"q" => "anything"}) |> render_change()

    assert html =~ "No e-way bills match these filters"
  end

  test "renders a real bill", %{conn: conn} do
    bill = bill(%{client_name: "Northwind Traders"})

    {:ok, _view, html} = live(conn, ~p"/e-way-bills")

    assert html =~ bill.ewb_number
    assert html =~ "Northwind Traders"
    assert html =~ bill.invoice.invoice_number
    assert html =~ "Maharashtra"
    assert html =~ "Karnataka"
    refute html =~ "No e-way bills"
  end

  test "searches on the EWB number, the document number and the consignee", %{conn: conn} do
    northwind = bill(%{client_name: "Northwind Traders"})
    contoso = bill(%{client_name: "Contoso Logistics"})

    {:ok, view, _html} = live(conn, ~p"/e-way-bills")

    # Read the table alone: the notification bell can show another async test's client.
    search = fn q ->
      view |> form("#ewb-search", %{"q" => q}) |> render_change()
      view |> element("#e-way-bills") |> render()
    end

    html = search.("Northwind")
    assert html =~ "Northwind Traders"
    refute html =~ "Contoso Logistics"

    html = search.(contoso.ewb_number)
    assert html =~ "Contoso Logistics"
    refute html =~ "Northwind Traders"

    html = search.(northwind.invoice.invoice_number)
    assert html =~ "Northwind Traders"
    refute html =~ "Contoso Logistics"
  end

  test "filters by a status derived from validity and cancellation", %{conn: conn} do
    bill(%{client_name: "Still Valid Ltd"})
    expire(bill(%{client_name: "Long Gone Ltd"}))

    {:ok, _cancelled} =
      EWayBills.cancel_e_way_bill(bill(%{client_name: "Called Off Ltd"}), %{
        "cancellation_reason" => "Order Cancelled"
      })

    {:ok, view, html} = live(conn, ~p"/e-way-bills")
    assert html =~ "Still Valid Ltd"
    assert html =~ "Long Gone Ltd"

    html = render_click(view, "filter_status", %{"status" => "Expired"})
    assert html =~ "Long Gone Ltd"
    refute html =~ "Still Valid Ltd"

    html = render_click(view, "filter_status", %{"status" => "Active"})
    assert html =~ "Still Valid Ltd"
    refute html =~ "Long Gone Ltd"
    refute html =~ "Called Off Ltd"

    html = render_click(view, "filter_status", %{"status" => "Cancelled"})
    assert html =~ "Called Off Ltd"
    refute html =~ "Still Valid Ltd"
  end

  test "pages rather than listing everything", %{conn: conn} do
    for index <- 1..12 do
      bill(%{client_name: "Consignee #{String.pad_leading(to_string(index), 2, "0")}"})
    end

    {:ok, view, html} = live(conn, ~p"/e-way-bills")

    # Ten to a page, newest first, with the id as tie-breaker.
    assert html =~ "Consignee 12"
    refute html =~ "Consignee 01"

    html = render_click(view, "paginate", %{"page" => "2"})
    assert html =~ "Consignee 01"
    assert html =~ "Consignee 02"
    refute html =~ "Consignee 12"
  end

  test "survives a sort on a column it does not sort by", %{conn: conn} do
    bill(%{client_name: "Northwind Traders"})

    {:ok, view, _html} = live(conn, ~p"/e-way-bills")

    # An unknown sort field must not crash the page.
    assert render_click(view, "sort", %{"field" => "not_a_column"}) =~ "Northwind Traders"
    assert render_click(view, "sort", %{"field" => "value"}) =~ "Northwind Traders"
  end

  test "carries the current filters into the export", %{conn: conn} do
    bill(%{client_name: "Northwind Traders"})

    {:ok, view, _html} = live(conn, ~p"/e-way-bills")

    # The export carries the current filter.
    html = view |> form("#ewb-search", %{"q" => "Northwind"}) |> render_change()

    assert html =~ ~s(href="/e-way-bills/export?q=Northwind&amp;status=All+Status")
  end

  describe "cancelling a bill" do
    test "records the cancellation and moves the row out of Active", %{conn: conn} do
      bill = bill(%{client_name: "Northwind Traders"})

      {:ok, view, _html} = live(conn, ~p"/e-way-bills")

      # Asserted before cancelling too, so the refute below is meaningful.
      assert has_element?(view, "#ewb-#{bill.ewb_number}")

      render_click(view, "open_action", %{"action" => "cancel", "id" => to_string(bill.id)})
      assert has_element?(view, "#ewb-cancel-form")

      html =
        view
        |> form("#ewb-cancel-form", %{"cancellation_reason" => "Order Cancelled"})
        |> render_submit()

      assert html =~ "cancelled"
      refute has_element?(view, "#ewb-cancel-form")

      cancelled = EWayBills.get_e_way_bill(bill.id)
      assert cancelled.status == "Cancelled"
      assert cancelled.cancellation_reason == "Order Cancelled"
      assert cancelled.cancelled_at

      # Scoped to the row: the notification bell also names the client.
      render_click(view, "filter_status", %{"status" => "Active"})
      refute has_element?(view, "#ewb-#{bill.ewb_number}")
    end

    # Rule 138(9): twenty-four hours to cancel.
    test "refuses a bill whose twenty-four hours have passed", %{conn: conn} do
      bill = bill(%{client_name: "Northwind Traders"})

      stale =
        bill
        |> Ecto.Changeset.change(
          inserted_at: DateTime.add(DateTime.utc_now(), -25, :hour) |> DateTime.truncate(:second)
        )
        |> Repo.update!()

      {:ok, view, html} = live(conn, ~p"/e-way-bills")

      # The button is not offered at all once the window has closed.
      refute html =~ ~s(phx-value-action="cancel")

      # And the event behind it refuses even if it is reached anyway.
      render_click(view, "open_action", %{"action" => "cancel", "id" => to_string(stale.id)})

      html =
        view
        |> form("#ewb-cancel-form", %{"cancellation_reason" => "Order Cancelled"})
        |> render_submit()

      assert html =~ "24 hours"
      assert EWayBills.get_e_way_bill(stale.id).status == "Active"
    end

    test "refuses a bill that is already cancelled", %{conn: conn} do
      bill = bill(%{client_name: "Northwind Traders"})

      {:ok, view, _html} = live(conn, ~p"/e-way-bills")

      render_click(view, "open_action", %{"action" => "cancel", "id" => to_string(bill.id)})

      {:ok, _cancelled} =
        EWayBills.cancel_e_way_bill(bill, %{"cancellation_reason" => "Duplicate"})

      html =
        view
        |> form("#ewb-cancel-form", %{"cancellation_reason" => "Order Cancelled"})
        |> render_submit()

      assert html =~ "already cancelled"
    end
  end

  describe "updating Part-B" do
    test "moves the consignment onto another vehicle", %{conn: conn} do
      bill = bill(%{client_name: "Northwind Traders", vehicle_number: "MH04CD5678"})

      {:ok, view, _html} = live(conn, ~p"/e-way-bills")

      render_click(view, "open_action", %{"action" => "part_b", "id" => to_string(bill.id)})
      assert has_element?(view, "#ewb-part-b-form")

      html =
        view
        |> form("#ewb-part-b-form", %{
          "vehicle_number" => "KA05CD9876",
          "mode_of_transport" => "Road",
          "place" => "Belgaum",
          "reason" => "Breakdown"
        })
        |> render_submit()

      assert html =~ "KA05CD9876"
      refute has_element?(view, "#ewb-part-b-form")

      updated = EWayBills.get_e_way_bill(bill.id)
      assert updated.vehicle_number == "KA05CD9876"

      # Both legs are kept: Part-B on the real form is a table, and the first
      # entry is the vehicle the bill was raised with.
      assert [first, second] = updated.part_b_updates
      assert first.vehicle_number == "MH04CD5678"
      assert second.vehicle_number == "KA05CD9876"
      assert second.place == "Belgaum"
    end

    test "refuses an expired bill", %{conn: conn} do
      bill = expire(bill(%{client_name: "Northwind Traders"}))

      {:ok, view, _html} = live(conn, ~p"/e-way-bills")

      render_click(view, "open_action", %{"action" => "part_b", "id" => to_string(bill.id)})

      html =
        view
        |> form("#ewb-part-b-form", %{
          "vehicle_number" => "KA05CD9876",
          "mode_of_transport" => "Road"
        })
        |> render_submit()

      assert html =~ "expired"
      assert EWayBills.get_e_way_bill(bill.id).vehicle_number == "MH04CD5678"
    end
  end

  describe "extending validity (Rule 138(10))" do
    defp valid_for(bill, seconds) do
      valid_until =
        NaiveDateTime.utc_now()
        |> NaiveDateTime.add(seconds, :second)
        |> NaiveDateTime.truncate(:second)

      bill |> Ecto.Changeset.change(valid_until: valid_until) |> Repo.update!()
    end

    defp extension_form do
      %{
        "reason" => "Law and Order Situation",
        "remarks" => "Highway blockade",
        "from_place" => "Hubli",
        "from_state" => "Karnataka (29)",
        "from_pincode" => "580020",
        "remaining_distance_km" => "90",
        "consignment_status" => "In Movement",
        "mode_of_transport" => "Road",
        "vehicle_number" => "KA25AB1234"
      }
    end

    test "is offered from 8 hours before expiry, and extends the bill", %{conn: conn} do
      bill = bill(%{client_name: "Northwind Traders"}) |> valid_for(3600)
      far = bill(%{client_name: "Contoso"})

      {:ok, view, _html} = live(conn, ~p"/e-way-bills")

      assert has_element?(
               view,
               ~s(button[aria-label="Extend validity of e-way bill #{bill.ewb_number}"])
             )

      refute has_element?(
               view,
               ~s(button[aria-label="Extend validity of e-way bill #{far.ewb_number}"])
             )

      render_click(view, "open_action", %{"action" => "extend", "id" => to_string(bill.id)})
      html = view |> form("#ewb-extend-form", extension_form()) |> render_submit()

      assert html =~ "extended: valid until"
      refute has_element?(view, "#ewb-extend-form")

      extended = EWayBills.get_e_way_bill(bill.id)
      assert NaiveDateTime.compare(extended.valid_until, bill.valid_until) == :gt
      assert extended.vehicle_number == "KA25AB1234"
      assert [%{reason: "Law and Order Situation"}] = extended.extensions
    end

    test "is offered on a bill that reads as expired, within 8 hours", %{conn: conn} do
      bill = bill(%{client_name: "Northwind Traders"}) |> valid_for(-3600)

      {:ok, view, _html} = live(conn, ~p"/e-way-bills")

      assert has_element?(
               view,
               ~s(button[aria-label="Extend validity of e-way bill #{bill.ewb_number}"])
             )

      render_click(view, "open_action", %{"action" => "extend", "id" => to_string(bill.id)})
      view |> form("#ewb-extend-form", extension_form()) |> render_submit()

      assert EWayBills.status(EWayBills.get_e_way_bill(bill.id)) == "Active"
    end

    test "says why when the window has closed", %{conn: conn} do
      bill = bill(%{client_name: "Northwind Traders"}) |> valid_for(-9 * 3600)

      {:ok, view, _html} = live(conn, ~p"/e-way-bills")

      refute has_element?(
               view,
               ~s(button[aria-label="Extend validity of e-way bill #{bill.ewb_number}"])
             )

      # A stale page can still submit; the context refuses.
      render_click(view, "open_action", %{"action" => "extend", "id" => to_string(bill.id)})
      html = view |> form("#ewb-extend-form", extension_form()) |> render_submit()

      assert html =~ "Rule 138(10) allows an extension only"
      assert EWayBills.get_e_way_bill(bill.id).extensions == []
    end

    test "closes the extension form if the invoice is cancelled while it is open", %{conn: conn} do
      bill = bill(%{}) |> valid_for(-3600)
      {:ok, view, _html} = live(conn, ~p"/e-way-bills")

      action = %{"action" => "extend", "id" => to_string(bill.id)}
      render_click(view, "open_action", action)
      assert has_element?(view, "#ewb-extend-form")

      invoice = Invoices.get_invoice!(bill.invoice_id)
      assert {:ok, _cancelled} = Invoices.cancel_invoice(invoice, "Order cancelled")

      assert view |> form("#ewb-extend-form", extension_form()) |> render_submit() =~
               "An e-way bill for a cancelled invoice cannot be extended."

      refute has_element?(
               view,
               ~s(button[aria-label="Extend validity of e-way bill #{bill.ewb_number}"])
             )

      render_click(view, "open_action", action)
      refute has_element?(view, "#ewb-extend-form")
    end

    test "shows the first missing detail", %{conn: conn} do
      bill = bill(%{client_name: "Northwind Traders"}) |> valid_for(3600)

      {:ok, view, _html} = live(conn, ~p"/e-way-bills")

      render_click(view, "open_action", %{"action" => "extend", "id" => to_string(bill.id)})

      html =
        view
        |> form("#ewb-extend-form", Map.put(extension_form(), "from_pincode", "12"))
        |> render_submit()

      assert html =~ "From pincode must be a 6-digit PIN code."
    end
  end

  describe "Part-B by Rail, Air and Ship" do
    for mode <- ["Rail", "Air", "Ship"] do
      test "#{mode} takes the transport document instead of a vehicle", %{conn: conn} do
        bill = bill(%{client_name: "Northwind Traders"})

        {:ok, view, _html} = live(conn, ~p"/e-way-bills")
        render_click(view, "open_action", %{"action" => "part_b", "id" => to_string(bill.id)})

        html =
          view
          |> form("#ewb-part-b-form", %{
            "mode_of_transport" => unquote(mode),
            "vehicle_number" => ""
          })
          |> render_submit()

        assert html =~ "is required for #{unquote(mode)}"

        view
        |> form("#ewb-part-b-form", %{
          "mode_of_transport" => unquote(mode),
          "vehicle_number" => "",
          "transport_document_number" => "DOC5566",
          "transport_document_date" => "2026-03-02",
          "place" => "Mumbai"
        })
        |> render_submit()

        updated = EWayBills.get_e_way_bill(bill.id)
        assert updated.mode_of_transport == unquote(mode)
        assert updated.transport_document_number == "DOC5566"
      end
    end
  end

  describe "moving a bill to the Bin" do
    test "is offered on a bill in every state", %{conn: conn} do
      active = bill(%{client_name: "Active Co"})
      expired = expire(bill(%{client_name: "Expired Co"}))

      {:ok, cancelled} =
        EWayBills.cancel_e_way_bill(bill(%{client_name: "Cancelled Co"}), %{
          "cancellation_reason" => "Duplicate"
        })

      {:ok, view, _html} = live(conn, ~p"/e-way-bills")

      for row <- [active, expired, cancelled] do
        assert has_element?(
                 view,
                 ~s|#ewb-#{row.ewb_number} button#ewb-delete-#{row.id}[data-confirm*="Bin"]|
               )

        refute has_element?(view, "#ewb-#{row.ewb_number} ul #ewb-delete-#{row.id}")
      end
    end

    # Taking a live bill off this list does nothing on the portal, and someone
    # who expects it to would go on to move goods under a bill they think is
    # dead — or skip cancelling one that should be.
    test "says of a live bill that it is not being cancelled", %{conn: conn} do
      active = bill(%{client_name: "Active Co"})

      {:ok, cancelled} =
        EWayBills.cancel_e_way_bill(bill(%{client_name: "Cancelled Co"}), %{
          "cancellation_reason" => "Duplicate"
        })

      {:ok, view, _html} = live(conn, ~p"/e-way-bills")

      assert has_element?(view, ~s|#ewb-delete-#{active.id}[data-confirm*="NOT cancelled"]|)
      refute has_element?(view, ~s|#ewb-delete-#{cancelled.id}[data-confirm*="NOT cancelled"]|)
    end

    test "takes the row off the list and into the Bin", %{conn: conn, user: user} do
      bill = bill(%{client_name: "Northwind Traders"})
      other = bill(%{client_name: "Contoso"})

      {:ok, view, _html} = live(conn, ~p"/e-way-bills")

      view |> element("#ewb-delete-#{bill.id}") |> render_click()

      refute has_element?(view, "#ewb-#{bill.ewb_number}")
      assert has_element?(view, "#ewb-#{other.ewb_number}")
      assert has_element?(view, "#flash-info", "moved to the Bin")

      # Off the list, not out of the database — and still the bill it was.
      assert EWayBills.get_e_way_bill(bill.id) == nil
      assert EWayBills.get_deleted_e_way_bill(bill.id).status == "Active"

      assert Enum.any?(QuantumBilling.Audit.list_audit_logs(), fn log ->
               log.action == "bin_e_way_bill" and log.user_id == user.id and
                 log.resource_id == to_string(bill.id)
             end)

      {:ok, bin, _html} = live(conn, ~p"/bin")
      assert has_element?(bin, "#bin-e_way_bill-#{bill.id}", bill.ewb_number)
    end

    test "a bill that is already gone is reported, not raised", %{conn: conn} do
      bill = bill(%{client_name: "Northwind Traders"})

      {:ok, view, _html} = live(conn, ~p"/e-way-bills")

      {:ok, _binned} = EWayBills.delete_e_way_bill(bill)

      render_click(view, "delete", %{"id" => to_string(bill.id)})
      assert has_element?(view, "#flash-error", "no longer exists")

      render_click(view, "delete", %{"id" => "not-an-id"})
      assert has_element?(view, "#flash-error", "no longer exists")
    end
  end

  test "serves no sample records", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/e-way-bills")

    refute html =~ "V2V Technologies"
    refute html =~ "INV-2024-"
  end

  test "requires authentication" do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(build_conn(), ~p"/e-way-bills")
  end
end
