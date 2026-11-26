defmodule QuantumBilling.EWayBills.NICClient do
  @moduledoc """
  HTTP client for the NIC e-way bill portal, using `Req`.

  Without `NIC_EWB_API_URL` it runs in demo mode with plausible numbers and the
  same validity rules; each bill records its `portal_mode`. With a portal set,
  an unreachable portal is an error, never a demo number.

  Payloads follow the NIC e-way bill API v1.03
  (https://docs.ewaybillgst.gov.in/apidocs/version1.03/): `GENEWAYBILL`,
  `CANEWB`, `VEHEWB` and `EXTENDVALIDITY`. Dates go to the portal as
  `dd/mm/yyyy`; the portal answers with Indian local times
  (`dd/mm/yyyy hh:mm:ss AM`), which are stored as UTC.
  """

  require Logger

  alias QuantumBilling.EWayBills.EWayBill
  alias QuantumBilling.EWayBills.Validity
  alias QuantumBilling.Invoices.Invoice

  @generate_path "/ewaybillapi/v1.03/gstr1/generate"
  @cancel_path "/ewaybillapi/v1.03/ewayapi/canewb"
  @part_b_path "/ewaybillapi/v1.03/ewayapi/vehewb"
  @extend_path "/ewaybillapi/v1.03/ewayapi/extendvalidity"

  # NIC `extnRsnCode` values for EXTENDVALIDITY.
  @extension_reasons [
    {"Natural Calamity", 1},
    {"Law and Order Situation", 2},
    {"Transshipment", 4},
    {"Accident", 5},
    {"Others", 99}
  ]

  @doc """
  Requests a bill number and validity: `{:ok, attrs}` of `EWayBill` fields; the caller adds `invoice_id`.

  A live bill keeps the date and validity the portal returns. Only a demo
  bill has them worked out here.
  """
  def generate_ewb(%Invoice{} = invoice, params \\ %{}) do
    params = stringify(params)

    client_gstin = invoice.client_gstin || "27AAAAA0000A1Z5"
    company_gstin = invoice.company_gstin || "27BBBBB0000B1Z5"

    distance = integer(Map.get(params, "distance_km"), 250)
    transporter_id = presence(Map.get(params, "transporter_id")) || "27AAACG1234A1ZP"
    transporter_name = presence(Map.get(params, "transporter_name")) || "Express Logistics India"
    mode = presence(Map.get(params, "mode_of_transport")) || "Road"
    vehicle_no = vehicle_number(params, mode)
    document_number = presence(Map.get(params, "transport_document_number"))
    document_date = date(Map.get(params, "transport_document_date"))

    ewb_payload = %{
      "supplyType" => "O",
      "subSupplyType" => 1,
      "docType" => "INV",
      "docNo" => invoice.invoice_number,
      "docDate" => to_string(invoice.invoice_date),
      "fromGstin" => company_gstin,
      "fromTrdName" => invoice.company_name,
      "fromAddr1" => invoice.company_address,
      "fromPlace" => invoice.company_state || "Mumbai",
      "fromPincode" => 400_001,
      "toGstin" => client_gstin,
      "toTrdName" => invoice.client_name,
      "toAddr1" => invoice.client_billing_address,
      "toPlace" => invoice.client_state || "Pune",
      "toPincode" => 411_001,
      "totalValue" => rupees(invoice.taxable_value),
      "cgstValue" => rupees(invoice.cgst_amount),
      "sgstValue" => rupees(invoice.sgst_amount),
      "igstValue" => rupees(invoice.igst_amount),
      "totInvValue" => rupees(invoice.grand_total),
      "transporterId" => transporter_id,
      "transporterName" => transporter_name,
      "transDistance" => distance,
      "transMode" => transport_code(mode),
      "vehicleNo" => vehicle_no || "",
      "transDocNo" => document_number || "",
      "transDocDate" => portal_date(document_date)
    }

    attrs = %{
      distance_km: distance,
      vehicle_number: vehicle_no,
      mode_of_transport: mode,
      transporter_id: transporter_id,
      transporter_name: transporter_name,
      transport_document_number: document_number,
      transport_document_date: document_date
    }

    if live?() do
      with {:ok, body} <- post(@generate_path, ewb_payload),
           {:ok, issue} <- portal_issue(body, distance) do
        {:ok, attrs |> Map.put(:portal_mode, "live") |> Map.merge(issue)}
      end
    else
      {:ok, attrs |> Map.put(:portal_mode, "demo") |> Map.merge(demo_issue(distance))}
    end
  end

  @doc """
  A sentence for the user on why the portal refused, or `nil` if `reason` isn't a portal failure.

  A refusal the portal itself sent (its error text or codes) is passed on.
  """
  def error_message(:portal_unavailable),
    do: "The e-way bill portal is not responding. Nothing was filed; try again shortly."

  def error_message(:unexpected_response),
    do: "The e-way bill portal sent an answer this app does not understand. Nothing was filed."

  def error_message(:portal_not_configured),
    do:
      "This bill was filed on the portal, but no portal is configured now (NIC_EWB_API_URL). " <>
        "Nothing was changed."

  def error_message({:portal_refused, detail}),
    do: "The e-way bill portal refused this: #{detail}"

  def error_message(_reason), do: nil

  @doc """
  True when `NIC_EWB_API_URL` points at a portal. Otherwise bills are minted
  locally and recorded as `"demo"`.
  """
  def live? do
    case System.get_env("NIC_EWB_API_URL") do
      "http" <> _rest -> true
      _other -> false
    end
  end

  @doc """
  Cancels a bill on the portal (Rule 138(9)). The caller records it locally only after `{:ok, response}`.
  """
  def cancel_ewb(%EWayBill{} = bill, params \\ %{}) do
    params = stringify(params)

    payload = %{
      "ewbNo" => bill.ewb_number,
      # Portal codes: 1 duplicate, 2 order cancelled, 3 data entry mistake, 4 others.
      "cancelRsnCode" => cancel_reason_code(Map.get(params, "cancellation_reason")),
      "cancelRmrk" => Map.get(params, "cancellation_reason")
    }

    # A demo bill was never on the portal, so there is nothing there to cancel.
    if EWayBill.demo?(bill) do
      {:ok, %{"ewbNo" => bill.ewb_number, "cancelDate" => now_string()}}
    else
      post(@cancel_path, payload)
    end
  end

  @doc """
  Files a Part-B update against a bill: the consignment has changed vehicle,
  or, for Rail, Air and Ship, has a new transport document.
  """
  def update_part_b(%EWayBill{} = bill, params) do
    params = stringify(params)
    mode = presence(Map.get(params, "mode_of_transport")) || "Road"

    payload = %{
      "ewbNo" => bill.ewb_number,
      "vehicleNo" => presence(Map.get(params, "vehicle_number")) || "",
      "fromPlace" => Map.get(params, "place"),
      "reasonCode" => "1",
      "reasonRem" => Map.get(params, "reason"),
      "transDocNo" => presence(Map.get(params, "transport_document_number")) || "",
      "transDocDate" => portal_date(date(Map.get(params, "transport_document_date"))),
      "transMode" => transport_code(mode)
    }

    if EWayBill.demo?(bill) do
      {:ok, %{"ewbNo" => bill.ewb_number, "vehUpdDate" => now_string()}}
    else
      post(@part_b_path, payload)
    end
  end

  @doc """
  Extends a bill's validity on the portal (Rule 138(10), NIC `EXTENDVALIDITY`).

  `params` are the extension's fields (see `EWayBillExtension`), already
  validated. Returns `{:ok, valid_until}` (UTC): the portal's new validity
  for a live bill, or one worked out from the remaining distance for a demo
  bill.
  """
  def extend_validity(%EWayBill{} = bill, params) do
    params = stringify(params)
    in_transit? = Map.get(params, "consignment_status") == "In Transit"
    mode = presence(Map.get(params, "mode_of_transport")) || "Road"
    distance = integer(Map.get(params, "remaining_distance_km"), 1)
    address = presence(Map.get(params, "address")) || ""

    payload = %{
      "ewbNo" => bill.ewb_number,
      "vehicleNo" =>
        if(in_transit?, do: "", else: presence(Map.get(params, "vehicle_number")) || ""),
      "fromPlace" => Map.get(params, "from_place"),
      "fromState" => state_code(Map.get(params, "from_state")),
      "fromPincode" => integer(Map.get(params, "from_pincode"), 0),
      "remainingDistance" => distance,
      "transDocNo" => presence(Map.get(params, "transport_document_number")) || "",
      "transDocDate" => portal_date(date(Map.get(params, "transport_document_date"))),
      # 5 is "in transit" on the portal: the goods are not moving.
      "transMode" => if(in_transit?, do: "5", else: to_string(transport_code(mode))),
      "extnRsnCode" => extension_reason_code(Map.get(params, "reason")),
      "extnRemarks" => Map.get(params, "remarks"),
      "consignmentStatus" => if(in_transit?, do: "T", else: "M"),
      "transitType" =>
        if(in_transit?, do: transit_code(Map.get(params, "transit_type")), else: ""),
      "addressLine1" => if(in_transit?, do: address, else: ""),
      "addressLine2" => "",
      "addressLine3" => ""
    }

    if EWayBill.demo?(bill) do
      {:ok,
       NaiveDateTime.utc_now()
       |> Validity.valid_until(distance)
       |> NaiveDateTime.truncate(:second)}
    else
      with {:ok, body} <- post(@extend_path, payload) do
        case portal_time(body["validUpto"]) do
          %NaiveDateTime{} = valid_until -> {:ok, valid_until}
          nil -> {:error, :unexpected_response}
        end
      end
    end
  end

  @doc "The extension reasons the portal accepts, in its order."
  def extension_reasons, do: Enum.map(@extension_reasons, &elem(&1, 0))

  # No fallback to a made-up answer: a portal that does not answer is an error,
  # so a failed request can never be recorded as a filed bill.
  defp post(path, payload) do
    if live?() do
      base_url = System.get_env("NIC_EWB_API_URL")
      api_key = System.get_env("NIC_EWB_API_KEY", "")

      case Req.post(base_url <> path,
             json: payload,
             headers: [{"x-api-key", api_key}, {"content-type", "application/json"}],
             receive_timeout: 5000,
             # Req's connect timeout defaults to 30 s; the transaction around
             # this call (EWayBills) must outlast the whole request.
             connect_options: [timeout: 5000]
           ) do
        {:ok, %{status: 200, body: %{"status" => "1"} = body}} -> {:ok, body}
        {:ok, %{body: %{"error" => error}}} -> {:error, refusal(error)}
        {:ok, %{status: 200}} -> {:error, :unexpected_response}
        {:ok, _not_200} -> {:error, :portal_unavailable}
        {:error, _exception} -> {:error, :portal_unavailable}
      end
    else
      # A live bill, but the portal is no longer configured.
      {:error, :portal_not_configured}
    end
  end

  # The portal's own refusal, kept so the user sees what it said.
  defp refusal(error) when is_binary(error) and error != "", do: {:portal_refused, error}

  defp refusal(%{"message" => message}) when is_binary(message) and message != "",
    do: {:portal_refused, message}

  defp refusal(%{"errorCodes" => codes}) when is_binary(codes) and codes != "",
    do: {:portal_refused, error_codes_text(codes)}

  # Some GSPs send the code as a number (240) or a list of them.
  defp refusal(%{"errorCodes" => code}) when is_integer(code),
    do: refusal(%{"errorCodes" => Integer.to_string(code)})

  defp refusal(%{"errorCodes" => [_ | _] = codes}),
    do: refusal(%{"errorCodes" => Enum.map_join(codes, ",", &to_string/1)})

  defp refusal(_unreadable), do: :unexpected_response

  # 604 is the portal's answer to a second bill on a document number it has
  # already used; the others are passed on by number.
  defp error_codes_text(codes) do
    codes = codes |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

    if "604" in codes do
      "it already holds an e-way bill for this document number and will not issue another " <>
        "on it (error 604). Extend the existing bill's validity instead, if it is still within " <>
        "#{Validity.extension_window_hours()} hours of expiry."
    else
      "error code(s) #{Enum.join(codes, ", ")}."
    end
  end

  # The portal answers GENEWAYBILL with `ewayBillNo`, `ewayBillDate` and
  # `validUpto`; some GSPs name the number `ewbNo`. Its validity is stored as
  # given. Once the portal has issued a number the bill exists there, so an
  # answer without a readable validity is still recorded, with the validity
  # worked out here, rather than refused.
  defp portal_issue(body, distance) do
    case body["ewayBillNo"] || body["ewbNo"] do
      nil ->
        {:error, :unexpected_response}

      number ->
        issued_at = portal_time(body["ewayBillDate"]) || utc_now()

        valid_until =
          case portal_time(body["validUpto"]) do
            %NaiveDateTime{} = valid_until ->
              valid_until

            nil ->
              Logger.warning(
                "[NICClient] e-way bill #{number}: no readable validUpto; validity worked out locally"
              )

              Validity.valid_until(issued_at, distance)
          end

        {:ok,
         %{
           ewb_number: to_string(number),
           ewb_date: Validity.ist_date(issued_at),
           valid_until: valid_until
         }}
    end
  end

  defp utc_now, do: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

  defp demo_issue(distance) do
    now = utc_now()

    %{
      ewb_number: sandbox_number(),
      ewb_date: Validity.ist_date(now),
      valid_until: Validity.valid_until(now, distance)
    }
  end

  @doc false
  # An Indian local time from the portal ("05/01/2018 10:44:00 AM", or the
  # 24-hour "05/01/2018 22:44:00") as UTC, or `nil`.
  def portal_time(value) when is_binary(value) do
    with [_, day, month, year, hour, minute, second, meridiem] <-
           Regex.run(
             ~r"^\s*(\d{1,2})/(\d{1,2})/(\d{4})\s+(\d{1,2}):(\d{2})(?::(\d{2}))?\s*([AaPp][Mm])?\s*$",
             value,
             capture: :all
           )
           |> pad_capture(),
         {:ok, date} <- Date.new(int(year), int(month), int(day)),
         {:ok, time} <- Time.new(hour(int(hour), meridiem), int(minute), int(second)) do
      date |> NaiveDateTime.new!(time) |> Validity.from_ist()
    else
      _unreadable -> nil
    end
  end

  def portal_time(_value), do: nil

  # Regex.run drops unmatched trailing groups; put them back as "".
  defp pad_capture(nil), do: nil
  defp pad_capture(groups), do: groups ++ List.duplicate("", 8 - length(groups))

  defp int(""), do: 0
  defp int(digits), do: String.to_integer(digits)

  defp hour(12, meridiem) when meridiem in ["AM", "am", "Am", "aM"], do: 0
  defp hour(hour, meridiem) when meridiem in ["PM", "pm", "Pm", "pM"] and hour < 12, do: hour + 12
  defp hour(hour, _meridiem), do: hour

  defp portal_date(%Date{} = date), do: Calendar.strftime(date, "%d/%m/%Y")
  defp portal_date(_none), do: ""

  # The portal takes rupees as JSON numbers; two decimals survive a float.
  defp rupees(nil), do: 0
  defp rupees(paise) when is_integer(paise), do: paise / 100

  # Only Road carries a vehicle number; a demo Road bill without one gets a
  # placeholder, as before.
  defp vehicle_number(params, "Road"),
    do: presence(Map.get(params, "vehicle_number")) || "MH12AB1234"

  defp vehicle_number(params, _mode), do: presence(Map.get(params, "vehicle_number"))

  defp sandbox_number do
    "1910" <> Enum.map_join(1..8, fn _ -> to_string(Enum.random(0..9)) end)
  end

  defp transport_code("Road"), do: 1
  defp transport_code("Rail"), do: 2
  defp transport_code("Air"), do: 3
  defp transport_code("Ship"), do: 4
  defp transport_code(_other), do: 1

  defp transit_code("Warehouse"), do: "W"
  defp transit_code("Others"), do: "O"
  defp transit_code(_road), do: "R"

  defp extension_reason_code(reason) do
    Enum.find_value(@extension_reasons, 99, fn {label, code} -> if label == reason, do: code end)
  end

  # "Maharashtra (27)" -> 27.
  defp state_code(state) when is_binary(state) do
    case Regex.run(~r/\((\d{2})\)\s*$/, state) do
      [_, code] -> String.to_integer(code)
      _none -> 0
    end
  end

  defp state_code(_state), do: 0

  defp cancel_reason_code(reason) when is_binary(reason) do
    downcased = String.downcase(reason)

    cond do
      String.contains?(downcased, "duplicate") -> "1"
      String.contains?(downcased, "cancel") -> "2"
      String.contains?(downcased, "mistake") or String.contains?(downcased, "error") -> "3"
      true -> "4"
    end
  end

  defp cancel_reason_code(_reason), do: "4"

  defp now_string, do: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second) |> to_string()

  defp stringify(params) do
    Map.new(params, fn {key, value} -> {to_string(key), value} end)
  end

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(value), do: value

  defp date(%Date{} = date), do: date

  defp date(value) when is_binary(value) do
    case Date.from_iso8601(String.trim(value)) do
      {:ok, date} -> date
      {:error, _reason} -> nil
    end
  end

  defp date(_value), do: nil

  defp integer(value, _default) when is_integer(value), do: value

  defp integer(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, _rest} -> parsed
      :error -> default
    end
  end

  defp integer(_value, default), do: default
end
