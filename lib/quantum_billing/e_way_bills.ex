defmodule QuantumBilling.EWayBills do
  @moduledoc """
  E-way bills: raising, cancelling, Part-B updates and validity extensions.

  A bill is *live* when it is not binned, is stored as "Active" and its
  `valid_until` has not passed (`live/1`). One live bill per invoice: the
  invoice page, the new-bill page, `Invoices.awaiting_e_way_bill/1` and
  `Invoices.cancel_invoice/3` all use this meaning. A bill past `valid_until`
  reads as "Expired" while still stored as "Active", so it can be extended;
  when a new bill replaces it, it is stored as "Expired" in the same
  transaction, which keeps the one-"Active"-bill-per-invoice index true.

  Deleting moves a bill to the Bin and does not cancel it on the portal.
  """

  import Ecto.Query, warn: false

  alias QuantumBilling.Audit
  alias QuantumBilling.EWayBills.EWayBill
  alias QuantumBilling.EWayBills.EWayBillExtension
  alias QuantumBilling.EWayBills.NICClient
  alias QuantumBilling.EWayBills.PartBUpdate
  alias QuantumBilling.EWayBills.Validity
  alias QuantumBilling.EWayBillNotifier
  alias QuantumBilling.Events
  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Notifications
  alias QuantumBilling.Paging
  alias QuantumBilling.Repo
  alias QuantumBilling.Webhooks
  alias QuantumBilling.Settings

  # Allowlisted sort columns; `value` lives on the invoice.
  @sortable %{
    ewb_no: {:bill, :ewb_number},
    issued_on: {:bill, :ewb_date},
    value: {:invoice, :grand_total}
  }

  @statuses ["Active", "Expired", "Cancelled"]

  # The portal is called inside the transaction that records its answer, so a
  # filed bill is never left unrecorded. Longer than the client's own connect
  # and receive timeouts (NICClient), so the portal gives up first.
  @portal_transaction_timeout 30_000

  # Rule 138(9): a bill may be cancelled within twenty-four hours of generation.
  @cancellation_window_hours 24

  @default_per_page 10
  @max_per_page 200

  @doc """
  Raises an e-way bill against an invoice.

  An invoice whose bill has expired can get a new one: the expired bill is
  stored as "Expired" in the same transaction as the new bill's insert. The
  invoice row is locked meanwhile, so two requests cannot both pass the
  live-bill check and file two bills on the portal.

  Returns `{:ok, bill}` or `{:error, :gst_only | :already_issued | :cancelled | changeset | portal_reason}`;
  `:gst_only` for a VAT business or invoice.
  """
  def generate_e_way_bill(%Invoice{} = invoice, params \\ %{}) do
    with :ok <- QuantumBilling.Tax.ensure_gst(invoice),
         {:ok, {bill, replaced}} <- issue(invoice, params) do
      bill = preload_bill(bill)

      Audit.log_event(:generate_e_way_bill, "EWayBill", bill.id,
        details: %{
          ewb_number: bill.ewb_number,
          invoice_id: invoice.id,
          invoice_number: invoice.invoice_number,
          distance_km: bill.distance_km,
          mode_of_transport: bill.mode_of_transport,
          vehicle_number: bill.vehicle_number,
          transport_document_number: bill.transport_document_number,
          replaced_ewb_numbers: replaced
        }
      )

      announce_generated(bill, invoice)
      {:ok, bill}
    end
  end

  # Everything that must hold together: the live-bill check, the portal call,
  # retiring the expired bill and recording the new one. The check reads the
  # locked row, not the caller's copy, which may be stale.
  defp issue(%Invoice{} = invoice, params) do
    Repo.transaction(
      fn ->
        locked = lock_invoice!(invoice.id)

        with :ok <- ensure_issuable(locked),
             {:ok, attrs} <- NICClient.generate_ewb(invoice, params),
             replaced = retire_expired(invoice.id),
             {:ok, bill} <- insert_bill(invoice, attrs, params) do
          {bill, replaced}
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end,
      timeout: @portal_transaction_timeout
    )
  end

  # The invoice row, locked. Issuing, extending and cancelling the invoice all
  # take this lock, so none of them can interleave.
  defp lock_invoice!(invoice_id) do
    Repo.one!(from i in Invoice, where: i.id == ^invoice_id, lock: "FOR UPDATE")
  end

  # Stores "Expired" on the invoice's lapsed bills, so the new one is the only
  # "Active" row. Returns their numbers.
  defp retire_expired(invoice_id) do
    now = NaiveDateTime.utc_now()

    {_count, numbers} =
      EWayBill.kept()
      |> where([b], b.invoice_id == ^invoice_id and b.status == "Active" and b.valid_until < ^now)
      |> select([b], b.ewb_number)
      |> Repo.update_all(set: [status: "Expired", updated_at: DateTime.utc_now(:second)])

    numbers
  end

  defp insert_bill(invoice, attrs, params) do
    attrs =
      attrs
      |> Map.put(:invoice_id, invoice.id)
      |> Map.put(:status, "Active")
      |> put_custom_fields(params)

    %EWayBill{}
    |> EWayBill.changeset(attrs)
    |> Repo.insert()
  end

  defp announce_generated(bill, invoice) do
    # The bill already exists on the portal, so the result is not matched.
    _ = EWayBillNotifier.notify_generated(bill)

    if Settings.get_organization().notify_ewb_generated != false do
      Notifications.notify(%{
        kind: "e_way_bill",
        title:
          if(EWayBill.demo?(bill),
            do: "Demo e-way bill #{bill.ewb_number} created (not filed)",
            else: "E-Way Bill #{bill.ewb_number} generated"
          ),
        body: "#{invoice.invoice_number} · #{carrier(bill)}",
        path: "/invoices/#{invoice.id}",
        dedupe_key: "ewb_generated:#{bill.id}"
      })
    end

    broadcast_change(bill)
    Webhooks.publish("e_way_bill.generated", bill.id)
  end

  defp carrier(%EWayBill{vehicle_number: vehicle}) when is_binary(vehicle), do: vehicle

  defp carrier(%EWayBill{transport_document_number: document, mode_of_transport: mode})
       when is_binary(document),
       do: "#{mode} document #{document}"

  defp carrier(_bill), do: "no vehicle recorded"

  # The form's custom fields go to the bill's own changeset, which validates them.
  defp put_custom_fields(attrs, params) do
    case Map.get(params, "custom_fields", Map.get(params, :custom_fields)) do
      values when is_map(values) -> Map.put(attrs, :custom_fields, values)
      _none -> attrs
    end
  end

  @doc """
  Cancels a bill under Rule 138(9): within 24 hours, with a reason.

  Returns `{:ok, bill}` or `{:error, :already_cancelled | :window_closed | changeset}`.
  """
  def cancel_e_way_bill(%EWayBill{} = bill, params \\ %{}) do
    with :ok <- ensure_cancellable(bill),
         {:ok, _portal} <- NICClient.cancel_ewb(bill, params) do
      bill
      |> EWayBill.cancel_changeset(params)
      |> Repo.update()
      |> case do
        {:ok, cancelled} ->
          cancelled = preload_bill(cancelled)

          Audit.log_event(:cancel_e_way_bill, "EWayBill", cancelled.id,
            details: %{
              ewb_number: cancelled.ewb_number,
              reason: cancelled.cancellation_reason
            }
          )

          # Always sent: a cancelled bill on a moving consignment must be known.
          Notifications.notify(%{
            kind: "e_way_bill",
            severity: "warning",
            title: "E-Way Bill #{cancelled.ewb_number} cancelled",
            body: cancelled.cancellation_reason,
            path: "/invoices/#{cancelled.invoice_id}",
            dedupe_key: "ewb_cancelled:#{cancelled.id}"
          })

          broadcast_change(cancelled)
          Webhooks.publish("e_way_bill.cancelled", cancelled.id)
          {:ok, cancelled}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  @doc """
  Records a Part-B update (a new vehicle) and moves the bill to it.

  Cancelled and expired bills cannot be updated.
  """
  def update_part_b(%EWayBill{} = bill, params) do
    with :ok <- ensure_updatable(bill),
         {:ok, _portal} <- NICClient.update_part_b(bill, params) do
      attrs = Map.put(stringify(params), "e_way_bill_id", bill.id)

      Ecto.Multi.new()
      |> Ecto.Multi.run(:first_leg, fn _repo, _changes -> ensure_first_leg(bill) end)
      |> Ecto.Multi.insert(:part_b, PartBUpdate.changeset(%PartBUpdate{}, attrs))
      |> Ecto.Multi.update(:bill, fn %{part_b: part_b} ->
        Ecto.Changeset.change(bill, %{
          vehicle_number: part_b.vehicle_number,
          mode_of_transport: part_b.mode_of_transport,
          transport_document_number: part_b.transport_document_number,
          transport_document_date: part_b.transport_document_date
        })
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{bill: updated, part_b: part_b}} ->
          updated = preload_bill(updated, force: true)

          Audit.log_event(:update_e_way_bill_part_b, "EWayBill", updated.id,
            details: %{
              ewb_number: updated.ewb_number,
              vehicle_number: part_b.vehicle_number,
              mode_of_transport: part_b.mode_of_transport,
              transport_document_number: part_b.transport_document_number,
              place: part_b.place
            }
          )

          broadcast_change(updated)
          {:ok, updated}

        {:error, _step, changeset, _changes} ->
          {:error, changeset}
      end
    end
  end

  @doc """
  Extends a bill's validity under Rule 138(10).

  Allowed from #{Validity.extension_window_hours()} hours before to
  #{Validity.extension_window_hours()} hours after `valid_until`, so it works
  on a bill that already reads as expired, but not on one a newer bill has
  replaced. The extension is kept as a row (`EWayBillExtension`), the bill
  moves to the new `valid_until` (and to the new vehicle or transport
  document when the goods are moving), and an audit entry is written. A
  demo bill is extended locally.

  Returns `{:ok, bill}` or `{:error, :cancelled | :already_cancelled | :replaced |
  :outside_extension_window | changeset | portal_reason}`.
  """
  def extend_validity(%EWayBill{} = bill, params) do
    changeset =
      %EWayBillExtension{}
      |> EWayBillExtension.changeset(stringify(params))
      |> EWayBillExtension.validate_against_bill(bill)

    # Checked before anything is sent: a detail the portal would refuse is
    # never filed.
    with {:ok, extension} <- Ecto.Changeset.apply_action(changeset, :insert) do
      Repo.transaction(
        fn ->
          invoice = lock_invoice!(bill.invoice_id)

          # Re-read under the lock: a new bill may have replaced this one, or
          # it may have been cancelled, since the caller loaded it.
          current = Repo.get!(EWayBill, bill.id)

          with :ok <- ensure_extendable(current, invoice),
               {:ok, valid_until} <-
                 NICClient.extend_validity(current, Map.from_struct(extension)),
               {:ok, _legs} <- record_extension_legs(current, extension),
               {:ok, _row} <-
                 Repo.insert(EWayBillExtension.record_changeset(changeset, current, valid_until)),
               {:ok, updated} <-
                 Repo.update(
                   Ecto.Changeset.change(current, extended_bill(extension, valid_until))
                 ) do
            {current, updated}
          else
            {:error, reason} -> Repo.rollback(reason)
          end
        end,
        timeout: @portal_transaction_timeout
      )
      |> case do
        {:ok, {before, updated}} ->
          updated = preload_bill(updated, force: true)

          Audit.log_event(:extend_e_way_bill, "EWayBill", updated.id,
            details: %{
              ewb_number: updated.ewb_number,
              previous_valid_until: before.valid_until,
              valid_until: updated.valid_until,
              reason: extension.reason,
              remarks: extension.remarks,
              consignment_status: extension.consignment_status,
              remaining_distance_km: extension.remaining_distance_km
            }
          )

          broadcast_change(updated)
          {:ok, updated}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Goods that moved to another vehicle or transport document: the journey's
  # legs keep the one they left (as the first leg, if none is recorded yet)
  # and gain the new one, as a Part-B update would.
  defp record_extension_legs(%EWayBill{} = bill, %EWayBillExtension{} = extension) do
    if moved?(bill, extension) do
      with {:ok, _first} <- ensure_first_leg(bill) do
        Repo.insert(
          PartBUpdate.changeset(%PartBUpdate{}, %{
            "e_way_bill_id" => bill.id,
            "vehicle_number" => extension.vehicle_number,
            "mode_of_transport" => extension.mode_of_transport,
            "transport_document_number" => extension.transport_document_number,
            "transport_document_date" => extension.transport_document_date,
            "place" => extension.from_place,
            "reason" => "Validity extension: #{extension.reason}"
          })
        )
      end
    else
      {:ok, :unchanged}
    end
  end

  defp moved?(bill, %EWayBillExtension{consignment_status: "In Movement"} = extension) do
    {bill.mode_of_transport, bill.vehicle_number, bill.transport_document_number} !=
      {extension.mode_of_transport, extension.vehicle_number, extension.transport_document_number}
  end

  defp moved?(_bill, _in_transit), do: false

  # Waiting goods keep the bill's last vehicle; moving goods move to the new one.
  defp extended_bill(
         %EWayBillExtension{consignment_status: "In Movement"} = extension,
         valid_until
       ) do
    %{
      valid_until: valid_until,
      mode_of_transport: extension.mode_of_transport,
      vehicle_number: extension.vehicle_number,
      transport_document_number: extension.transport_document_number,
      transport_document_date: extension.transport_document_date
    }
  end

  defp extended_bill(_in_transit, valid_until), do: %{valid_until: valid_until}

  @doc "Whether the bill can be extended now (Rule 138(10))."
  def extendable?(%EWayBill{} = bill), do: ensure_extendable(bill, bill.invoice) == :ok

  @doc "One non-binned bill with its invoice and history, or `nil` (also for bad ids)."
  def get_e_way_bill(id), do: fetch_by_id(EWayBill.kept(), id)

  @doc "One non-binned bill. Raises if missing."
  def get_e_way_bill!(id) do
    EWayBill.kept()
    |> Repo.get!(id)
    |> preload_bill()
  end

  @doc "One binned bill, or `nil` (also for bad ids)."
  def get_deleted_e_way_bill(id), do: fetch_by_id(EWayBill.binned(), id)

  defp fetch_by_id(query, id) do
    case Integer.parse(to_string(id)) do
      {int_id, ""} -> query |> Repo.get(int_id) |> preload_bill()
      _not_an_id -> nil
    end
  end

  @doc "Binned bills, most recently deleted first; `limit:` bounds the rows."
  def list_deleted_e_way_bills(opts \\ []) do
    from(b in EWayBill.binned(), order_by: [desc: b.deleted_at, desc: b.id], preload: [:invoice])
    |> Paging.bounded(opts)
    |> Repo.all()
  end

  @doc "How many bills are in the Bin."
  def count_deleted_e_way_bills, do: Repo.aggregate(EWayBill.binned(), :count)

  @doc """
  Moves a bill to the Bin. An Active bill stays active on the portal.

  `opts` may carry `:user_id` for the audit entry.
  """
  def delete_e_way_bill(bill, opts \\ [])

  def delete_e_way_bill(%EWayBill{deleted_at: %DateTime{}} = bill, _opts), do: {:ok, bill}

  def delete_e_way_bill(%EWayBill{} = bill, opts) do
    bill
    |> EWayBill.bin_changeset()
    |> Repo.update()
    |> announce(:bin_e_way_bill, opts)
  end

  @doc "Restores a bill. Returns `{:error, :invoice_has_live_bill}` if a newer live bill exists."
  def restore_e_way_bill(%EWayBill{} = bill, opts \\ []) do
    bill
    |> EWayBill.restore_changeset()
    |> Repo.update()
    |> case do
      {:error, %Ecto.Changeset{}} -> {:error, :invoice_has_live_bill}
      result -> result
    end
    |> announce(:restore_e_way_bill, opts)
  end

  @doc "Deletes a binned bill and its Part-B history. Returns `{:error, :not_in_bin}` otherwise."
  def purge_e_way_bill(bill, opts \\ [])

  def purge_e_way_bill(%EWayBill{deleted_at: nil}, _opts), do: {:error, :not_in_bin}

  def purge_e_way_bill(%EWayBill{} = bill, opts) do
    bill
    |> Repo.delete()
    |> announce(:purge_e_way_bill, opts)
  end

  defp announce({:ok, %EWayBill{} = bill} = result, action, opts) do
    Audit.log_event(action, "EWayBill", bill.id,
      user_id: Keyword.get(opts, :user_id),
      details: %{ewb_number: bill.ewb_number, invoice_id: bill.invoice_id, status: bill.status}
    )

    broadcast_change(bill)
    result
  end

  defp announce(result, _action, _opts), do: result

  @doc """
  The live bill for an invoice (see the moduledoc), or `nil`. An expired or
  cancelled bill does not count.
  """
  def live_bill_for_invoice(invoice_id) do
    EWayBill.kept()
    |> live()
    |> where([b], b.invoice_id == ^invoice_id)
    # The index allows one "Active" row per invoice; this never raises if
    # older data holds more.
    |> order_by([b], desc: b.id)
    |> limit(1)
    |> Repo.one()
    |> preload_bill()
  end

  @doc """
  Narrows `query` (of `EWayBill`) to live bills: stored "Active" and not past
  `valid_until`. Binned bills are left to the caller (`EWayBill.kept/1`).
  """
  def live(query \\ EWayBill) do
    now = NaiveDateTime.utc_now()

    from b in query, where: b.status == "Active" and b.valid_until >= ^now
  end

  @doc "Every e-way bill, newest first. Unbounded; the page uses `page/1`."
  def list_e_way_bills do
    base_query()
    |> order_by([bill: b], desc: b.ewb_date, desc: b.id)
    |> Repo.all()
    |> Enum.map(&to_row/1)
  end

  @doc """
  One page of e-way bills, filtered and sorted in the database.

  Options: `:search`, `:status`, `:sort_field`, `:sort_dir`, `:page`, `:per_page`.
  """
  def page(opts \\ []) do
    per_page = opts |> Keyword.get(:per_page, @default_per_page) |> clamp(1, @max_per_page)

    sort_field = Keyword.get(opts, :sort_field, :issued_on)
    sort_dir = Keyword.get(opts, :sort_dir, :desc)

    query =
      base_query()
      |> search_where(Keyword.get(opts, :search))
      |> status_where(Keyword.get(opts, :status))

    # `:keyset` pages newest-created first below `:before_id`, for the API.
    result =
      if Keyword.get(opts, :keyset, false) do
        Paging.keyset(query, Keyword.get(opts, :before_id), per_page)
      else
        Paging.page(query, &order(&1, sort_field, sort_dir),
          page: Keyword.get(opts, :page, 1),
          per_page: per_page
        )
      end

    # `records: true` returns the bills themselves (used by the API).
    if Keyword.get(opts, :records, false),
      do: result,
      else: %{result | rows: Enum.map(result.rows, &to_row/1)}
  end

  @doc "Every bill matching the list filters, for CSV export. Ignores `:page`."
  def export_rows(opts \\ []) do
    base_query()
    |> search_where(Keyword.get(opts, :search))
    |> status_where(Keyword.get(opts, :status))
    |> order(Keyword.get(opts, :sort_field, :issued_on), Keyword.get(opts, :sort_dir, :desc))
    |> Repo.all()
    |> Enum.map(&to_row/1)
  end

  @doc "The columns the list page may sort on."
  def sortable_fields, do: Map.keys(@sortable)

  @doc "The statuses the list page may filter on, the catch-all first."
  def status_options, do: ["All Status" | @statuses]

  @doc "How long after generation a bill may still be cancelled, in hours."
  def cancellation_window_hours, do: @cancellation_window_hours

  @doc """
  Whether this bill is still inside its Rule 138(9) cancellation window.
  """
  def cancellable?(%EWayBill{} = bill), do: ensure_cancellable(bill) == :ok

  @doc """
  A bill's status. "Expired" is stored once a bill is replaced; before that it
  is derived from `valid_until`.
  """
  def status(%EWayBill{status: "Cancelled"}), do: "Cancelled"
  def status(%EWayBill{status: "Expired"}), do: "Expired"
  def status(%EWayBill{valid_until: nil}), do: "Active"

  def status(%EWayBill{valid_until: valid_until}) do
    if NaiveDateTime.compare(valid_until, NaiveDateTime.utc_now()) == :lt,
      do: "Expired",
      else: "Active"
  end

  defp ensure_issuable(%Invoice{status: "Cancelled"}), do: {:error, :cancelled}

  # Only a live bill blocks a new one: a cancelled bill (Rule 138(9)) or an
  # expired one does not.
  defp ensure_issuable(%Invoice{id: id}) do
    exists =
      EWayBill.kept()
      |> live()
      |> where([b], b.invoice_id == ^id)
      |> Repo.exists?()

    if exists, do: {:error, :already_issued}, else: :ok
  end

  defp ensure_cancellable(%EWayBill{status: "Cancelled"}), do: {:error, :already_cancelled}

  defp ensure_cancellable(%EWayBill{inserted_at: nil}), do: :ok

  defp ensure_cancellable(%EWayBill{inserted_at: generated_at}) do
    hours = DateTime.diff(DateTime.utc_now(), generated_at, :second) / 3600

    if hours <= @cancellation_window_hours, do: :ok, else: {:error, :window_closed}
  end

  # Not `ensure_updatable/1`: an extension is asked for around expiry, so a
  # bill that reads as expired may still be extended.
  defp ensure_extendable(_bill, %Invoice{status: "Cancelled"}), do: {:error, :cancelled}

  defp ensure_extendable(%EWayBill{status: "Cancelled"}, _invoice),
    do: {:error, :already_cancelled}

  defp ensure_extendable(%EWayBill{status: "Expired"}, _invoice), do: {:error, :replaced}

  defp ensure_extendable(%EWayBill{valid_until: valid_until}, _invoice) do
    if Validity.extendable?(valid_until, NaiveDateTime.utc_now()),
      do: :ok,
      else: {:error, :outside_extension_window}
  end

  defp ensure_updatable(%EWayBill{} = bill) do
    case status(bill) do
      "Active" -> :ok
      "Cancelled" -> {:error, :already_cancelled}
      "Expired" -> {:error, :expired}
    end
  end

  defp preload_bill(bill, opts \\ [])

  defp preload_bill(nil, _opts), do: nil

  defp preload_bill(%EWayBill{} = bill, opts) do
    Repo.preload(
      bill,
      [
        invoice: :items,
        part_b_updates: from(p in PartBUpdate, order_by: [asc: p.updated_on, asc: p.id]),
        extensions: from(e in EWayBillExtension, order_by: [asc: e.extended_on, asc: e.id])
      ],
      opts
    )
  end

  # Keeps the original vehicle as the first Part-B leg. It records what the
  # bill already holds, so it is not held to today's rules: a Rail bill raised
  # before transport documents were recorded has none, and its first leg must
  # still be written.
  defp ensure_first_leg(%EWayBill{} = bill) do
    recorded? = Repo.exists?(from p in PartBUpdate, where: p.e_way_bill_id == ^bill.id)

    if recorded? do
      {:ok, :already_recorded}
    else
      Repo.insert(
        PartBUpdate.history_changeset(%PartBUpdate{}, %{
          "e_way_bill_id" => bill.id,
          "vehicle_number" => bill.vehicle_number,
          "mode_of_transport" => bill.mode_of_transport,
          "transport_document_number" => bill.transport_document_number,
          "transport_document_date" => bill.transport_document_date,
          "updated_on" => bill.inserted_at
        })
      )
    end
  end

  @doc "A bill by id on the same terms as `page/1`: neither it nor its invoice is binned."
  def get_listed_e_way_bill(id) do
    case Integer.parse(to_string(id)) do
      {id, ""} -> Repo.one(from [bill: b] in base_query(), where: b.id == ^id)
      _not_an_id -> nil
    end
  end

  defp base_query do
    from b in EWayBill.kept(),
      as: :bill,
      join: i in assoc(b, :invoice),
      as: :invoice,
      where: is_nil(i.deleted_at),
      preload: [invoice: i]
  end

  defp search_where(query, blank) when blank in [nil, ""], do: query

  defp search_where(query, search) do
    pattern = "%" <> String.trim(search) <> "%"

    where(
      query,
      [bill: b, invoice: i],
      ilike(b.ewb_number, ^pattern) or ilike(i.invoice_number, ^pattern) or
        ilike(i.client_name, ^pattern)
    )
  end

  defp status_where(query, status) when status in [nil, "", "All Status"], do: query

  defp status_where(query, "Cancelled"), do: where(query, [bill: b], b.status == "Cancelled")

  defp status_where(query, "Expired") do
    now = NaiveDateTime.utc_now()

    where(
      query,
      [bill: b],
      b.status == "Expired" or (b.status == "Active" and b.valid_until < ^now)
    )
  end

  defp status_where(query, "Active"), do: live(query)

  defp status_where(query, _unknown), do: query

  defp order(query, field, direction) do
    {binding, column} = Map.get(@sortable, field, {:bill, :ewb_date})
    direction = if direction == :asc, do: :asc, else: :desc

    # The id breaks ties so paging is stable.
    case binding do
      :bill ->
        order_by(query, [bill: b], [{^direction, field(b, ^column)}, {^direction, b.id}])

      :invoice ->
        order_by(query, [bill: b, invoice: i], [
          {^direction, field(i, ^column)},
          {^direction, b.id}
        ])
    end
  end

  defp clamp(value, minimum, maximum) when is_integer(value),
    do: value |> max(minimum) |> min(maximum)

  defp clamp(_value, minimum, _maximum), do: minimum

  defp stringify(params) do
    Map.new(params, fn {key, value} -> {to_string(key), value} end)
  end

  defp to_row(%EWayBill{invoice: %Invoice{} = invoice} = bill) do
    %{
      id: bill.id,
      invoice_id: invoice.id,
      ewb_no: bill.ewb_number,
      portal_mode: bill.portal_mode,
      document_no: invoice.invoice_number,
      issued_on: bill.ewb_date,
      valid_until: bill.valid_until,
      to_party: invoice.client_name,
      from_place: invoice.company_state || "—",
      to_place: invoice.client_state || invoice.place_of_supply || "—",
      value: invoice.grand_total,
      distance_km: bill.distance_km,
      vehicle_number: bill.vehicle_number,
      transporter_name: bill.transporter_name,
      mode_of_transport: bill.mode_of_transport,
      transport_document_number: bill.transport_document_number,
      status: status(bill),
      cancellable: cancellable?(bill),
      extendable: extendable?(bill),
      custom_fields: bill.custom_fields || %{}
    }
  end

  @doc """
  Subscribes the caller to e-way bill changes.
  """
  def subscribe, do: Events.subscribe(Events.e_way_bills_topic())

  @doc """
  Announces an e-way bill change to every listening page.
  """
  def broadcast_change(e_way_bill, event \\ :e_way_bill_changed) do
    Events.broadcast(Events.e_way_bills_topic(), {event, e_way_bill})
  end
end
