defmodule QuantumBillingWeb.GSTReverseChargeLiveTest do
  @moduledoc """
  Issue #79 on screen: the reverse-charge toggle on the GST invoice and
  quotation forms, the live summary, and the Rule 46(p) note on the invoice
  page and the public page.
  """
  use QuantumBillingWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias QuantumBilling.Invoices
  alias QuantumBilling.Settings

  setup :register_and_log_in_user

  setup do
    {:ok, _} =
      Settings.update_section(
        Settings.get_organization(),
        %{
          "company_name" => "Acme Legal Services LLP",
          "gstin" => "27AABCA1234A1Z5",
          "pan" => "AABCA1234A",
          "state" => "Maharashtra (27)",
          "address" => "221B Example Street, Mumbai"
        },
        :general
      )

    :ok
  end

  defp reverse_charge_invoice do
    {:ok, invoice} =
      Invoices.create_invoice(%{
        "invoice_date" => "2026-04-18",
        "place_of_supply" => "Karnataka (29)",
        "client_name" => "Northwind Traders",
        "client_gstin" => "29AAACN1234B1Z2",
        "client_state" => "Karnataka (29)",
        "reverse_charge" => "true",
        "items" => %{
          "0" => %{
            "description" => "Legal services",
            "hsn_sac" => "998211",
            "quantity" => "1",
            "unit" => "Nos",
            "rate" => "100000",
            "tax_rate" => "18"
          }
        }
      })

    invoice
  end

  test "the GST invoice form offers reverse charge", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/invoices/new")

    assert has_element?(view, "#invoice-reverse-charge")
    assert has_element?(view, "#invoice-reverse-charge", "The buyer pays the GST")
  end

  test "the GST quotation form offers reverse charge", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/quotations/new")

    assert has_element?(view, "#quotation-reverse-charge")
  end

  test "the summary leaves the tax out of the total and says why", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/invoices/new")

    render_change(view, "validate", %{
      "invoice" => %{
        "place_of_supply" => "Maharashtra (27)",
        "client_name" => "Northwind Traders",
        "reverse_charge" => "true",
        "items" => %{
          "0" => %{
            "description" => "Legal services",
            "quantity" => "1",
            "rate" => "100000",
            "tax_rate" => "18"
          }
        }
      }
    })

    assert has_element?(view, "#invoice-summary-grand-total", "1,00,000.00")
    assert has_element?(view, "#invoice-summary-reverse-charge", "18,000.00")
  end

  test "the invoice page prints the Rule 46(p) note with the rate and amount", %{conn: conn} do
    invoice = reverse_charge_invoice()

    {:ok, _view, html} = live(conn, ~p"/invoices/#{invoice.id}")

    assert html =~ "Tax payable on reverse charge basis: Yes"
    assert html =~ "IGST @ 18% (payable by recipient)"
    assert html =~ "18,000.00"
  end

  test "the public page prints it too", %{conn: conn} do
    invoice = reverse_charge_invoice()
    slug = QuantumBilling.Businesses.default!().slug

    {:ok, _view, html} = live(conn, ~p"/p/#{slug}/#{invoice.public_token}")

    assert html =~ "Tax payable on reverse charge basis: Yes"
    assert html =~ "IGST @ 18% (payable by recipient)"
  end
end
