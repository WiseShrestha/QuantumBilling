defmodule QuantumBilling.Repo.TenantMigrations.AddGstReverseChargeTax do
  use Ecto.Migration

  @moduledoc """
  Reverse charge under GST (CGST Act section 9(3), IGST Act section 5(3)).

  On a reverse-charge invoice the supplier charges no tax: `cgst_amount`,
  `sgst_amount`, `igst_amount` and `cess_amount` are 0 and `grand_total` is the
  taxable value plus round-off, as a VAT reverse-charge invoice already is. The
  tax the recipient pays is kept in its own columns, so the document, GSTR-1
  and the e-invoice can still show it. Credit and debit notes on such an
  invoice keep theirs in `rc_tax_amount`.

  Every existing row gets 0, which is what it already means: until now a GST
  invoice could not be made reverse charge.
  """

  def change do
    for table <- [:invoices, :quotations] do
      alter table(table) do
        add :rc_cgst_amount, :bigint, null: false, default: 0
        add :rc_sgst_amount, :bigint, null: false, default: 0
        add :rc_igst_amount, :bigint, null: false, default: 0
        add :rc_cess_amount, :bigint, null: false, default: 0
      end
    end

    alter table(:credit_notes) do
      add :rc_tax_amount, :bigint, null: false, default: 0
    end
  end
end
