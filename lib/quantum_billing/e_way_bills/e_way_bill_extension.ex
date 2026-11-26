defmodule QuantumBilling.EWayBills.EWayBillExtension do
  @moduledoc """
  One extension of an e-way bill's validity under Rule 138(10).

  Asked for from eight hours before to eight hours after expiry, when the
  goods have not reached their destination. Each extension is a row, as each
  Part-B leg is, so the bill's history shows every one; the bill's
  `valid_until` is the latest.

  `consignment_status` is `"In Movement"` (the goods are on a vehicle or with
  a carrier) or `"In Transit"` (they are waiting, on the road, in a warehouse
  or elsewhere: `transit_type` and `address` say where). A consignment in
  movement needs the same transport details as a bill: a vehicle for Road, a
  transport document for Rail, Air and Ship.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias QuantumBilling.EWayBills.EWayBill
  alias QuantumBilling.EWayBills.NICClient

  @consignment_statuses ["In Movement", "In Transit"]
  @transit_types ["Road", "Warehouse", "Others"]

  @required ~w(reason remarks consignment_status from_place from_state from_pincode
               remaining_distance_km)a

  @castable @required ++
              ~w(transit_type address mode_of_transport vehicle_number
                 transport_document_number transport_document_date)a

  schema "e_way_bill_extensions" do
    field :previous_valid_until, :naive_datetime
    field :valid_until, :naive_datetime
    field :reason, :string
    field :remarks, :string
    field :consignment_status, :string, default: "In Movement"
    field :transit_type, :string
    field :address, :string
    field :from_place, :string
    field :from_state, :string
    field :from_pincode, :string
    field :remaining_distance_km, :integer
    field :mode_of_transport, :string
    field :vehicle_number, :string
    field :transport_document_number, :string
    field :transport_document_date, :date
    field :extended_on, :utc_datetime

    belongs_to :e_way_bill, EWayBill

    timestamps(type: :utc_datetime)
  end

  @doc """
  Validates what the user entered. `previous_valid_until`, `valid_until`,
  `extended_on` and `e_way_bill_id` are set by the context.
  """
  def changeset(extension, attrs) do
    extension
    |> cast(attrs, @castable)
    |> update_change(:vehicle_number, &normalise_vehicle/1)
    |> validate_required(@required)
    |> validate_inclusion(:reason, NICClient.extension_reasons())
    |> validate_inclusion(:consignment_status, @consignment_statuses)
    |> validate_length(:remarks, min: 3, max: 50)
    |> validate_length(:from_place, max: 50)
    |> validate_format(:from_pincode, ~r/^[1-9]\d{5}$/, message: "must be a 6-digit PIN code")
    |> validate_format(:from_state, ~r/\(\d{2}\)$/, message: "must be a GST state")
    |> validate_number(:remaining_distance_km, greater_than: 0, less_than_or_equal_to: 4000)
    |> validate_where_goods_are()
  end

  @doc """
  Checks the extension against the bill: the distance left cannot be more
  than the bill's own distance, which the portal refuses too.
  """
  def validate_against_bill(changeset, %EWayBill{distance_km: distance})
      when is_integer(distance) and distance > 0 do
    validate_number(changeset, :remaining_distance_km,
      less_than_or_equal_to: distance,
      message: "cannot be more than the bill's distance (#{distance} km)"
    )
  end

  def validate_against_bill(changeset, _bill), do: changeset

  @doc "Sets what the context works out: the validity before and after, and when."
  def record_changeset(changeset, %EWayBill{} = bill, %NaiveDateTime{} = valid_until) do
    changeset
    |> put_change(:e_way_bill_id, bill.id)
    |> put_change(:previous_valid_until, bill.valid_until)
    |> put_change(:valid_until, valid_until)
    |> put_change(:extended_on, DateTime.utc_now(:second))
  end

  def consignment_statuses, do: @consignment_statuses
  def transit_types, do: @transit_types

  # Moving goods need transport details; waiting goods need a place.
  defp validate_where_goods_are(changeset) do
    case get_field(changeset, :consignment_status) do
      "In Movement" ->
        changeset
        |> put_change(:transit_type, nil)
        |> put_change(:address, nil)
        |> validate_required([:mode_of_transport])
        |> validate_inclusion(:mode_of_transport, EWayBill.transport_modes())
        |> EWayBill.validate_transport()
        |> validate_length(:vehicle_number, min: 4, max: 20)

      "In Transit" ->
        changeset
        |> put_change(:mode_of_transport, nil)
        |> put_change(:vehicle_number, nil)
        |> put_change(:transport_document_number, nil)
        |> put_change(:transport_document_date, nil)
        |> validate_required([:transit_type, :address])
        |> validate_inclusion(:transit_type, @transit_types)
        |> validate_length(:address, max: 120)

      _unknown ->
        changeset
    end
  end

  defp normalise_vehicle(nil), do: nil
  defp normalise_vehicle(vehicle), do: vehicle |> String.replace(~r/\s/, "") |> String.upcase()
end
