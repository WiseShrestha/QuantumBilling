defmodule QuantumBilling.Repo.TenantMigrations.EWayBillExpiryExtensionsAndTransportDocuments do
  use Ecto.Migration

  @moduledoc """
  E-way bills can be replaced after expiry, extended under Rule 138(10), and
  carried by Rail, Air or Ship.

  * `status` may now also store `"Expired"`: a bill gets it when a new bill
    replaces it. The one-live-bill index covers only `"Active"` rows, which is
    the same set of rows as before for existing data (they are all `"Active"`
    or `"Cancelled"`).
  * `e_way_bills` and `e_way_bill_part_b_updates` get the transport document
    number and date (railway receipt, airway bill or bill of lading). A
    Part-B leg's `vehicle_number` may be empty, as a bill's already may.
  * `e_way_bill_extensions` keeps one row per validity extension.

  Existing bills are moved onto IST. Their validity was counted from the UTC
  date and stored as 23:59:59 meaning the end of that day in India; read as
  UTC it ended 5.5 hours late. `valid_until` loses 5h30m so it is the same
  instant in UTC, and `ewb_date` becomes the Indian date of `inserted_at`
  (both used the UTC date before). `down` adds the 5h30m back; the Indian
  dates are kept, being correct either way.
  """

  def up do
    drop index(:e_way_bills, [:invoice_id], name: :e_way_bills_one_live_bill_per_invoice_index)

    create unique_index(:e_way_bills, [:invoice_id],
             name: :e_way_bills_one_live_bill_per_invoice_index,
             where: "status = 'Active' AND deleted_at IS NULL"
           )

    alter table(:e_way_bills) do
      add :transport_document_number, :string
      add :transport_document_date, :date
    end

    # Onto IST (see the moduledoc). Runs once, so only bills raised before
    # this migration are moved.
    execute("""
    UPDATE "#{prefix()}"."e_way_bills"
    SET valid_until = valid_until - interval '5 hours 30 minutes',
        ewb_date = (inserted_at + interval '5 hours 30 minutes')::date
    WHERE valid_until IS NOT NULL
    """)

    # A Rail, Air or Ship leg has a transport document instead of a vehicle.
    alter table(:e_way_bill_part_b_updates) do
      add :transport_document_number, :string
      add :transport_document_date, :date
      modify :vehicle_number, :string, null: true, from: {:string, null: false}
    end

    create table(:e_way_bill_extensions) do
      add :e_way_bill_id, references(:e_way_bills, on_delete: :delete_all), null: false
      add :previous_valid_until, :naive_datetime, null: false
      add :valid_until, :naive_datetime, null: false
      add :reason, :string, null: false
      add :remarks, :string, null: false
      add :consignment_status, :string, null: false
      add :transit_type, :string
      add :address, :string
      add :from_place, :string, null: false
      add :from_state, :string, null: false
      add :from_pincode, :string, null: false
      add :remaining_distance_km, :integer, null: false
      add :mode_of_transport, :string
      add :vehicle_number, :string
      add :transport_document_number, :string
      add :transport_document_date, :date
      add :extended_on, :utc_datetime, null: false
      timestamps(type: :utc_datetime)
    end

    create index(:e_way_bill_extensions, [:e_way_bill_id])
  end

  # Fails while an invoice has an expired bill and its replacement; cancel or
  # purge one of them first. Also fails while a Rail, Air or Ship Part-B leg
  # has no vehicle number (the old column was NOT NULL): give those legs a
  # vehicle number, or delete them, before rolling back.
  def down do
    drop table(:e_way_bill_extensions)

    alter table(:e_way_bill_part_b_updates) do
      remove :transport_document_number
      remove :transport_document_date
      modify :vehicle_number, :string, null: false, from: {:string, null: true}
    end

    alter table(:e_way_bills) do
      remove :transport_document_number
      remove :transport_document_date
    end

    drop index(:e_way_bills, [:invoice_id], name: :e_way_bills_one_live_bill_per_invoice_index)

    execute(~s(UPDATE "#{prefix()}"."e_way_bills" SET status = 'Active' WHERE status = 'Expired'))

    execute("""
    UPDATE "#{prefix()}"."e_way_bills"
    SET valid_until = valid_until + interval '5 hours 30 minutes'
    WHERE valid_until IS NOT NULL
    """)

    create unique_index(:e_way_bills, [:invoice_id],
             name: :e_way_bills_one_live_bill_per_invoice_index,
             where: "status <> 'Cancelled' AND deleted_at IS NULL"
           )
  end
end
