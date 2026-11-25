defmodule QuantumBilling.GSTReverseChargeTest do
  @moduledoc """
  Issue #79: reverse charge under GST (CGST Act section 9(3), IGST Act
  section 5(3)). The invoice charges no tax; the tax the recipient pays is
  kept in `rc_*` and reported on the document, GSTR-1 and the e-invoice.
  """
  # Not async: sets the organisation's details, which every invoice snapshots.
  use QuantumBilling.DataCase, async: false

  import QuantumBilling.AccountsFixtures

  alias QuantumBilling.Accounts.Scope
  alias QuantumBilling.Compliance.GSTNExporter
  alias QuantumBilling.CreditNotes
  alias QuantumBilling.EInvoice
  alias QuantumBilling.Invoices
  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Payments.QRCode
  alias QuantumBilling.Quotations
  alias QuantumBilling.Reports
  alias QuantumBilling.Settings
  alias QuantumBilling.Tax

  @buyer_gstin "27AAACN1234B1Z2"

  setup do
    {:ok, organization} =
      Settings.update_section(
        Settings.ensure_organization(),
        %{
          "company_name" => "Acme Legal Services LLP",
          "address" => "221B Example Street",
          "city" => "Mumbai",
          "pincode" => "400001",
          "gstin" => "27AABCA1234A1Z5",
          "pan" => "AABCA1234A",
          "state" => "Maharashtra (27)"
        },
        :general
      )

    %{organization: organization}
  end

  # ₹1,00,000 at 18%: ₹18,000 of GST.
  defp invoice(attrs, item_attrs \\ %{}) do
    item =
      Map.merge(
        %{
          "description" => "Legal services",
          "hsn_sac" => "998211",
          "quantity" => "1",
          "unit" => "Nos",
          "rate" => "100000",
          "tax_rate" => "18"
        },
        item_attrs
      )

    # One client per buyer GSTIN: GSTINs are unique.
    client =
      Repo.get_by(QuantumBilling.Clients.Client, gstin: @buyer_gstin) ||
        Repo.insert!(%QuantumBilling.Clients.Client{
          name: "Northwind Traders",
          gstin: @buyer_gstin,
          billing_line1: "12 Harbour Road",
          billing_city: "Mumbai",
          billing_state: "Maharashtra (27)",
          billing_pin: "400002"
        })

    Invoices.create_invoice(
      Map.merge(
        %{
          "client_id" => to_string(client.id),
          "client_billing_address" => "12 Harbour Road",
          "client_city" => "Mumbai",
          "client_pincode" => "400002",
          "invoice_date" => "2026-04-18",
          "place_of_supply" => "Maharashtra (27)",
          "client_name" => "Northwind Traders",
          "client_gstin" => @buyer_gstin,
          "client_state" => "Maharashtra (27)",
          "reverse_charge" => "true",
          "items" => %{"0" => item}
        },
        attrs
      )
    )
  end

  defp invoice!(attrs \\ %{}, item_attrs \\ %{}) do
    {:ok, invoice} = invoice(attrs, item_attrs)
    Repo.preload(invoice, :items, force: true)
  end

  describe "totals" do
    test "an intra-state invoice charges no tax and keeps the CGST and SGST apart" do
      invoice = invoice!()

      assert invoice.taxable_value == 10_000_000
      assert {invoice.cgst_amount, invoice.sgst_amount, invoice.igst_amount} == {0, 0, 0}
      assert invoice.rc_cgst_amount == 900_000
      assert invoice.rc_sgst_amount == 900_000
      assert invoice.rc_igst_amount == 0
      assert invoice.grand_total == 10_000_000
      assert Tax.reverse_charge_tax(invoice) == 1_800_000
    end

    test "an inter-state invoice keeps the IGST apart" do
      invoice =
        invoice!(%{"place_of_supply" => "Karnataka (29)", "client_state" => "Karnataka (29)"})

      assert invoice.igst_amount == 0
      assert invoice.rc_igst_amount == 1_800_000
      assert invoice.grand_total == 10_000_000
    end

    test "the total is the taxable value plus round-off" do
      invoice = invoice!(%{}, %{"rate" => "999.50"})

      assert invoice.taxable_value == 99_950
      assert invoice.round_off == 50
      assert invoice.grand_total == 100_000
    end

    test "a forward-charge invoice is unchanged" do
      invoice = invoice!(%{"reverse_charge" => "false"})

      assert invoice.cgst_amount == 900_000
      assert invoice.sgst_amount == 900_000
      assert Tax.reverse_charge_tax(invoice) == 0
      assert invoice.grand_total == 11_800_000
    end

    test "a reverse-charge invoice needs the buyer's GSTIN" do
      assert {:error, changeset} = invoice(%{"client_gstin" => ""})

      assert "is required for a reverse-charge invoice: the buyer pays the tax" in errors_on(
               changeset
             ).client_gstin
    end

    # Before #79 the flag could be set on a GST invoice by a crafted submit
    # and the tax was still charged. Now the flag always means the same thing.
    test "turning reverse charge on or off recomputes the totals" do
      forward = invoice!(%{"reverse_charge" => "false"})

      assert {:ok, reversed} = Invoices.update_invoice(forward, %{"reverse_charge" => "true"})
      assert reversed.grand_total == 10_000_000
      assert reversed.cgst_amount == 0
      assert reversed.rc_cgst_amount == 900_000

      assert {:ok, back} = Invoices.update_invoice(reversed, %{"reverse_charge" => "false"})
      assert back.grand_total == 11_800_000
      assert back.rc_cgst_amount == 0
    end
  end

  describe "the document note (Rule 46(p))" do
    test "declares reverse charge and lists each head's rate and amount" do
      invoice = invoice!()

      assert Tax.reverse_charge_legend(invoice) =~ "Tax payable on reverse charge basis: Yes"

      assert Tax.reverse_charge_heads(invoice) == [
               %{label: "CGST @ 9%", amount: 900_000},
               %{label: "SGST @ 9%", amount: 900_000}
             ]
    end

    test "a forward-charge invoice has no note" do
      invoice = invoice!(%{"reverse_charge" => "false"})

      assert Tax.reverse_charge_legend(invoice) == nil
      assert Tax.reverse_charge_heads(invoice) == []
    end
  end

  describe "the e-invoice" do
    defp tree(invoice) do
      {:ok, xml} = EInvoice.xml_for(invoice)
      {:ok, parsed} = Saxy.SimpleForm.parse_string(xml)
      parsed
    end

    defp text(node, path), do: node |> at(path) |> content()

    defp at({_name, _attrs, children}, [step | rest]) do
      children
      |> Enum.find(&match?({^step, _, _}, &1))
      |> case do
        nil -> nil
        found -> at(found, rest)
      end
    end

    defp at(node, []), do: node

    defp content({_name, _attrs, children}),
      do: children |> Enum.filter(&is_binary/1) |> Enum.join()

    test "flags reverse charge and reports the tax, which the total leaves out" do
      invoice = invoice!()
      xml = tree(invoice)

      assert text(xml, ["TranDtls", "RegRev"]) == "Y"
      assert text(xml, ["ValDtls", "CgstVal"]) == "9000.00"
      assert text(xml, ["ValDtls", "SgstVal"]) == "9000.00"
      assert text(xml, ["ValDtls", "TotInvVal"]) == "100000.00"
      assert text(xml, ["ItemList", "Item", "CgstAmt"]) == "9000.00"
      # With RegRev "Y" the IRP accepts an item value without the tax.
      assert text(xml, ["ItemList", "Item", "TotItemVal"]) == "100000.00"

      json = EInvoice.to_json(invoice)
      assert json["TranDetails"]["RegRev"] == "Y"
      assert json["ValDetails"]["CgstVal"] == 9000.0
      assert json["ValDetails"]["TotInvVal"] == 100_000.0
    end

    test "a forward-charge invoice is not flagged" do
      xml = tree(invoice!(%{"reverse_charge" => "false"}))

      assert text(xml, ["TranDtls", "RegRev"]) == "N"
      assert text(xml, ["ItemList", "Item", "TotItemVal"]) == "118000.00"
    end
  end

  describe "GSTR-1" do
    defp b2b_entry(json, number) do
      json["b2b"] |> Enum.flat_map(& &1["inv"]) |> Enum.find(&(&1["inum"] == number))
    end

    test "reports the taxable value, the recipient's tax and the invoice value, flagged rchrg Y" do
      invoice = invoice!()

      assert {:ok, json} = GSTNExporter.generate_gstr1_json("042026")
      entry = b2b_entry(json, invoice.invoice_number)

      assert entry["rchrg"] == "Y"
      assert entry["val"] == 100_000.0
      assert [%{"itm_det" => details}] = entry["itms"]
      assert details["txval"] == 100_000.0
      assert details["camt"] == 9000.0
      assert details["samt"] == 9000.0
      assert details["rt"] == 18.0
    end

    test "a note on a reverse-charge invoice reports its share of the recipient's tax" do
      invoice = invoice!()

      {:ok, _note} =
        CreditNotes.create_credit_note_for_invoice(invoice, %{"grand_total" => "50000"})

      {:ok, json} = GSTNExporter.generate_gstr1_json(note_period())
      assert [%{"nt" => [note]}] = json["cdnr"]

      assert note["rchrg"] == "Y"
      assert note["val"] == 50_000.0
      assert [%{"itm_det" => details}] = note["itms"]
      assert details["txval"] == 50_000.0
      assert details["camt"] + details["samt"] == 9000.0
    end

    defp note_period do
      today = QuantumBilling.Compliance.local_date()
      Calendar.strftime(today, "%m%Y")
    end
  end

  describe "credit and debit notes" do
    test "charge no tax and keep their share of the recipient's tax" do
      invoice = invoice!()

      assert {:ok, note} =
               CreditNotes.create_credit_note_for_invoice(invoice, %{"grand_total" => "25000"})

      assert note.grand_total == 2_500_000
      assert note.subtotal == 2_500_000
      assert note.tax_total == 0
      assert note.rc_tax_amount == 450_000
    end

    test "refuse a tax amount the invoice did not charge" do
      invoice = invoice!()

      assert {:error, changeset} =
               CreditNotes.create_credit_note_for_invoice(invoice, %{
                 "grand_total" => "11800",
                 "subtotal" => "10000",
                 "tax_total" => "1800"
               })

      assert [message] = errors_on(changeset).tax_total
      assert message =~ "reverse charge"
    end

    test "on a forward-charge invoice they split the tax as before" do
      invoice = invoice!(%{"reverse_charge" => "false"})

      {:ok, note} =
        CreditNotes.create_credit_note_for_invoice(invoice, %{"grand_total" => "11800"})

      assert note.subtotal == 1_000_000
      assert note.tax_total == 180_000
      assert note.rc_tax_amount == 0
    end
  end

  describe "quotation to invoice" do
    test "a reverse-charge quotation becomes a reverse-charge invoice" do
      scope = %{Scope.for_user(user_fixture()) | business: Repo.business()}

      {:ok, quotation} =
        Quotations.create_quotation(scope, %{
          "quotation_date" => Date.to_iso8601(Quotations.today()),
          "valid_until" => Date.to_iso8601(Date.add(Quotations.today(), 30)),
          "place_of_supply" => "Maharashtra (27)",
          "client_name" => "Northwind Traders",
          "client_gstin" => @buyer_gstin,
          "reverse_charge" => "true",
          "items" => %{
            "0" => %{
              "description" => "Legal services",
              "hsn_sac" => "998211",
              "quantity" => "1",
              "unit" => "Nos",
              "rate" => "100000",
              "tax_rate" => "18",
              "position" => "0"
            }
          }
        })

      assert quotation.grand_total == 10_000_000
      assert quotation.rc_cgst_amount == 900_000

      {:ok, accepted} = Quotations.accept(scope, quotation)

      params =
        accepted
        |> Quotations.invoice_params()
        |> Map.put("invoice_date", Date.to_iso8601(Quotations.today()))

      assert {:ok, %Invoice{} = invoice} =
               Invoices.create_invoice(params, quotation_id: accepted.id)

      assert invoice.reverse_charge
      assert invoice.grand_total == 10_000_000
      assert invoice.cgst_amount == 0
      assert invoice.rc_cgst_amount == 900_000
    end

    test "a GST reverse-charge quotation also needs the buyer's GSTIN" do
      scope = %{Scope.for_user(user_fixture()) | business: Repo.business()}

      assert {:error, changeset} =
               Quotations.create_quotation(
                 scope,
                 QuantumBilling.QuotationsFixtures.quotation_params(%{"reverse_charge" => "true"})
               )

      assert errors_on(changeset).client_gstin != []
    end
  end

  # Once the tax charged is 0, these follow without changes of their own.
  describe "reports, dashboard and payments" do
    @all %{
      date_range: "All Time",
      report_type: "All Reports",
      client: "All Clients",
      status: "All Status",
      gstin: ""
    }

    test "the recipient's tax is not the supplier's output tax" do
      _reverse = invoice!()
      _forward = invoice!(%{"reverse_charge" => "false"})

      [total] = Enum.filter(Reports.tax_rows(@all), & &1.total?)
      assert total.taxable_value == 20_000_000
      assert total.total_tax == 1_800_000

      assert Invoices.totals().tax == 1_800_000
    end

    test "a payment asks for the taxable value only", %{organization: organization} do
      invoice = invoice!()
      organization = %{organization | upi_vpa: "acme@okaxis"}

      assert {:ok, uri} = QRCode.upi_uri(invoice, organization)
      assert uri =~ "am=100000.00"

      assert QuantumBilling.Payments.open_for_payment?(invoice)
      assert invoice.grand_total == invoice.taxable_value
    end
  end
end
