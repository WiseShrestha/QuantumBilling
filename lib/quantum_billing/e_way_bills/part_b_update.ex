defmodule QuantumBilling.EWayBills.PartBUpdate do
  @moduledoc """
  One Part-B entry: the vehicle for one leg of a consignment's journey.

  EWB-01 lists every leg, so they are rows. The bill's `vehicle_number` is
  still the current vehicle. A Road leg needs a vehicle number; a Rail, Air or
  Ship leg needs its transport document number and date instead.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias QuantumBilling.EWayBills.EWayBill

  @castable ~w(vehicle_number mode_of_transport place reason updated_on e_way_bill_id
               transport_document_number transport_document_date)a

  schema "e_way_bill_part_b_updates" do
    field :vehicle_number, :string
    field :mode_of_transport, :string, default: "Road"
    field :place, :string
    field :reason, :string
    field :transport_document_number, :string
    field :transport_document_date, :date
    field :updated_on, :utc_datetime

    belongs_to :e_way_bill, EWayBill

    timestamps(type: :utc_datetime)
  end

  def changeset(part_b_update, attrs) do
    part_b_update
    |> cast(attrs, @castable)
    |> put_updated_on()
    |> validate_required([:mode_of_transport, :updated_on, :e_way_bill_id])
    |> validate_inclusion(:mode_of_transport, EWayBill.transport_modes())
    |> EWayBill.validate_transport()
    |> validate_length(:vehicle_number, min: 4, max: 20)
    |> foreign_key_constraint(:e_way_bill_id)
  end

  @doc """
  The first leg, rebuilt from what the bill already holds. Not held to the
  transport rules of `changeset/2`: a bill raised before transport documents
  were recorded may have neither a vehicle nor a document, and its history
  must still be kept.
  """
  def history_changeset(part_b_update, attrs) do
    part_b_update
    |> cast(attrs, @castable)
    |> put_updated_on()
    |> validate_required([:mode_of_transport, :updated_on, :e_way_bill_id])
    |> foreign_key_constraint(:e_way_bill_id)
  end

  defp put_updated_on(changeset) do
    case get_field(changeset, :updated_on) do
      nil -> put_change(changeset, :updated_on, DateTime.utc_now() |> DateTime.truncate(:second))
      _already_set -> changeset
    end
  end
end
