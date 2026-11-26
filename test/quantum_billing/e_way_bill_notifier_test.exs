defmodule QuantumBilling.EWayBillNotifierTest do
  @moduledoc "The e-way bill generated email. PR #111 review: validity in IST."
  use QuantumBilling.DataCase, async: true

  alias QuantumBilling.EWayBillNotifier
  alias QuantumBilling.EWayBills
  alias QuantumBilling.Invoices.Invoice

  test "the email gives the validity in IST, as the EWB-01 does" do
    invoice =
      Repo.insert!(%Invoice{
        invoice_number: "INV-#{System.unique_integer([:positive])}",
        invoice_date: ~D[2026-03-01],
        place_of_supply: "Maharashtra",
        company_state: "Maharashtra",
        client_name: "Acme India Pvt Ltd",
        taxable_value: 100_000,
        grand_total: 118_000
      })

    {:ok, bill} = EWayBills.generate_e_way_bill(invoice, %{"vehicle_number" => "MH04CD5678"})

    # Stored as 18:29:59 UTC: 23:59 IST.
    bill = %{bill | valid_until: ~N[2026-03-02 18:29:59]}
    {:ok, email} = EWayBillNotifier.build_email("ops@example.com", bill)

    assert email.text_body =~ "02/03/2026 23:59 IST"
    assert email.html_body =~ "02/03/2026 23:59 IST"
    refute email.text_body =~ "18:29"
  end

  test "a Rail bill names its railway receipt instead of a vehicle" do
    invoice =
      Repo.insert!(%Invoice{
        invoice_number: "INV-#{System.unique_integer([:positive])}",
        invoice_date: ~D[2026-03-01],
        place_of_supply: "Maharashtra",
        company_state: "Maharashtra",
        client_name: "Acme India Pvt Ltd",
        taxable_value: 100_000,
        grand_total: 118_000
      })

    {:ok, bill} =
      EWayBills.generate_e_way_bill(invoice, %{
        "mode_of_transport" => "Rail",
        "transport_document_number" => "RR4455",
        "transport_document_date" => "2026-03-01"
      })

    {:ok, email} = EWayBillNotifier.build_email("ops@example.com", bill)

    assert email.text_body =~ "Vehicle:     Rail document RR4455"
  end
end
