defmodule QuantumBilling.EWayBills.EWayBill do
  @moduledoc """
  One e-way bill raised against one invoice.

  `status` stores `"Active"`, `"Cancelled"` or `"Expired"`. A bill past its
  `valid_until` reads as expired (`EWayBills.status/1`) while still stored as
  `"Active"`; it is stored as `"Expired"` once a new bill replaces it, in the
  same transaction. Cancelled rows are kept (Rule 138(9)), and a partial
  unique index allows one stored `"Active"` bill per invoice. Binning sets
  `deleted_at` locally only; the portal is not told.

  Road needs a vehicle number; Rail, Air and Ship need the transport document
  (railway receipt, airway bill or bill of lading) number and date instead.
  """
  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  alias QuantumBilling.CustomFields
  alias QuantumBilling.EWayBills.EWayBillExtension
  alias QuantumBilling.EWayBills.PartBUpdate
  alias QuantumBilling.Invoices.Invoice

  @statuses ["Active", "Cancelled", "Expired"]
  @transport_modes ["Road", "Rail", "Air", "Ship"]
  @portal_modes ["demo", "live"]

  @castable ~w(ewb_number ewb_date valid_until status distance_km mode_of_transport
               vehicle_number transporter_id transporter_name cancelled_at
               cancellation_reason invoice_id portal_mode transport_document_number
               transport_document_date)a

  schema "e_way_bills" do
    field :ewb_number, :string
    field :ewb_date, :date
    field :valid_until, :naive_datetime
    field :status, :string, default: "Active"
    field :distance_km, :integer
    field :mode_of_transport, :string, default: "Road"
    field :vehicle_number, :string
    field :transporter_id, :string
    field :transporter_name, :string
    # Railway receipt, airway bill or bill of lading; required for Rail, Air and Ship.
    field :transport_document_number, :string
    field :transport_document_date, :date
    field :cancelled_at, :utc_datetime
    field :cancellation_reason, :string
    field :deleted_at, :utc_datetime
    # "live" when the NIC portal issued the number; "demo" when it was minted locally.
    field :portal_mode, :string, default: "demo"

    belongs_to :invoice, Invoice
    has_many :part_b_updates, PartBUpdate, foreign_key: :e_way_bill_id
    has_many :extensions, EWayBillExtension, foreign_key: :e_way_bill_id

    # Values for the business's own fields. Written only by CustomFields.cast/4.
    field :custom_fields, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  @doc "True when the bill was generated locally and never filed with the portal."
  def demo?(%__MODULE__{portal_mode: "live"}), do: false
  def demo?(%__MODULE__{}), do: true

  @doc """
  Builds a changeset for a bill. `invoice_id` and `portal_mode` come from the context, never user input.
  """
  def changeset(e_way_bill, attrs) do
    e_way_bill
    |> cast(attrs, @castable)
    |> validate_required([:ewb_number, :ewb_date, :valid_until, :distance_km, :invoice_id])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:mode_of_transport, @transport_modes)
    |> validate_inclusion(:portal_mode, @portal_modes)
    |> validate_number(:distance_km, greater_than_or_equal_to: 0, less_than_or_equal_to: 4_000)
    |> validate_transport()
    |> CustomFields.cast("e_way_bill", attrs)
    |> foreign_key_constraint(:invoice_id)
    |> unique_constraint(:ewb_number)
    |> unique_constraint(:invoice_id,
      name: :e_way_bills_one_live_bill_per_invoice_index,
      message: "already has a live e-way bill"
    )
  end

  @doc "The transport modes, Road first."
  def transport_modes, do: @transport_modes

  @doc """
  Road needs `vehicle_field`; Rail, Air and Ship need the transport document
  number and date. Shared with the form and the Part-B update.
  """
  def validate_transport(
        changeset,
        mode_field \\ :mode_of_transport,
        vehicle_field \\ :vehicle_number
      ) do
    case get_field(changeset, mode_field) do
      "Road" ->
        validate_required(changeset, [vehicle_field],
          message: "is required when the goods go by road"
        )

      mode when mode in ["Rail", "Air", "Ship"] ->
        changeset
        |> validate_required([:transport_document_number, :transport_document_date],
          message: "is required for #{mode}"
        )
        |> validate_length(:transport_document_number, max: 15)

      _unknown ->
        changeset
    end
  end

  @doc "Marks a bill cancelled. The context enforces the 24-hour window."
  def cancel_changeset(e_way_bill, attrs) do
    e_way_bill
    |> cast(attrs, [:cancellation_reason])
    |> put_change(:status, "Cancelled")
    |> put_change(:cancelled_at, DateTime.utc_now() |> DateTime.truncate(:second))
    |> validate_required([:cancellation_reason],
      message: "a reason is required to cancel an e-way bill"
    )
    |> validate_length(:cancellation_reason, min: 3, max: 255)
  end

  @doc "Narrows `query` to bills that are not in the Bin."
  def kept(query \\ __MODULE__) do
    from b in query, where: is_nil(b.deleted_at)
  end

  @doc "Narrows `query` to bills that are in the Bin."
  def binned(query \\ __MODULE__) do
    from b in query, where: not is_nil(b.deleted_at)
  end

  @doc "Moves a bill to the Bin."
  def bin_changeset(e_way_bill), do: change(e_way_bill, deleted_at: DateTime.utc_now(:second))

  @doc """
  Takes a bill out of the Bin. If its invoice already has a live bill, the changeset gets an error.
  """
  def restore_changeset(e_way_bill) do
    e_way_bill
    |> change(deleted_at: nil)
    |> unique_constraint(:invoice_id,
      name: :e_way_bills_one_live_bill_per_invoice_index,
      message: "already has a live e-way bill"
    )
  end
end
