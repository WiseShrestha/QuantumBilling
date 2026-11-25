defmodule QuantumBillingWeb.API.ReverseChargeTest do
  @moduledoc """
  Issue #79: a GST business creates reverse-charge invoices and quotations
  through the API. None of the tax is charged; it is returned in `rc_*`.
  """
  use QuantumBillingWeb.ConnCase, async: true

  import QuantumBilling.AccountsFixtures
  import QuantumBilling.ApiFixtures

  defp registered_client(gstin) do
    client_fixture(%{"client_type" => "Registered Business", "gstin" => gstin})
  end

  defp post_as(owner, scope, path, body) do
    {raw, _key} = api_key_fixture([scope], %{owner: owner})
    raw |> api_conn() |> api_post(path, body)
  end

  defp invoice_body(client, over \\ %{}) do
    Map.merge(
      %{
        "client_id" => client.id,
        "invoice_type" => "Tax Invoice",
        "invoice_date" => "2026-11-02",
        "place_of_supply" => "Maharashtra (27)",
        "reverse_charge" => true,
        "items" => [
          %{
            "description" => "Legal services",
            "hsn_sac" => "998211",
            "quantity" => 1,
            "rate" => 10_000_000,
            "tax_rate" => 18
          }
        ]
      },
      over
    )
  end

  setup do
    %{owner: owner_fixture()}
  end

  test "a GST business creates a reverse-charge invoice; the tax is not charged", %{owner: owner} do
    client = registered_client("27AAACN1234B1Z2")

    response =
      owner
      |> post_as("invoices:write", ~p"/api/v1/invoices", invoice_body(client))
      |> json_response(201)

    invoice = response["data"] || response

    assert invoice["reverse_charge"] == true
    assert invoice["tax_regime"] == "gst"

    assert %{
             "taxable_value" => 10_000_000,
             "cgst" => 0,
             "sgst" => 0,
             "igst" => 0,
             "rc_cgst" => 900_000,
             "rc_sgst" => 900_000,
             "rc_igst" => 0,
             "grand_total" => 10_000_000
           } = invoice["amounts"]
  end

  test "a client without a GSTIN is refused", %{owner: owner} do
    client = client_fixture()

    assert %{"error" => %{"fields" => fields}} =
             owner
             |> post_as("invoices:write", ~p"/api/v1/invoices", invoice_body(client))
             |> json_response(422)

    assert [message] = fields["client_gstin"]
    assert message =~ "reverse-charge"
  end

  test "a forward-charge invoice reports no reverse-charge tax", %{owner: owner} do
    client = registered_client("27AAACN1234B1Z3")

    response =
      owner
      |> post_as(
        "invoices:write",
        ~p"/api/v1/invoices",
        invoice_body(client, %{"reverse_charge" => false})
      )
      |> json_response(201)

    amounts = (response["data"] || response)["amounts"]
    assert amounts["cgst"] == 900_000
    assert amounts["rc_cgst"] == 0
    assert amounts["grand_total"] == 11_800_000
  end

  test "a GST business creates a reverse-charge quotation", %{owner: owner} do
    client = registered_client("27AAACN1234B1Z4")

    body =
      client
      |> invoice_body()
      |> Map.drop(["invoice_type", "invoice_date"])
      |> Map.merge(%{
        "quotation_date" => Date.to_iso8601(QuantumBilling.Quotations.today()),
        "valid_until" => Date.to_iso8601(Date.add(QuantumBilling.Quotations.today(), 30))
      })

    response =
      owner
      |> post_as("quotations:write", ~p"/api/v1/quotations", body)
      |> json_response(201)

    quotation = response["data"] || response
    assert quotation["reverse_charge"] == true
    assert quotation["amounts"]["rc_igst"] + quotation["amounts"]["rc_cgst"] > 0
    assert quotation["amounts"]["grand_total"] == 10_000_000
  end
end
