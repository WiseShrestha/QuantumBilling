defmodule QuantumBillingWeb.HsnSuggestions do
  @moduledoc """
  HSN/SAC suggestions on the invoice and quotation item rows (GST only).

  The state lives in one assign, `:hsn`, read by
  `DocumentFormComponents.items_section/1`:

    * `open` and `list`: the row whose suggestions are showing, and them.
      Typing a description suggests from `HsnFinder.suggest/2` (the
      business's own history first, then the catalogue); typing digits in
      the HSN/SAC box suggests codes under that prefix.
    * `lookup`: the row whose "Find HSN/SAC" search is open, and its query.
    * `suggested`: rows whose code was filled from a suggestion and not yet
      edited by hand; they carry a "Suggested" tag.
    * `manual`: rows whose code or rate was typed by hand. Picking a
      suggestion there asks first (`data-confirm`), so a typed value is
      never replaced without the user saying so.
    * `notice`: the "please verify" note after a pick, for a few seconds.

  Adding or removing a row closes the panel and carries the manual and
  suggested flags to each surviving row's new index.
  """

  import Phoenix.Component, only: [assign: 3]

  alias QuantumBilling.HsnFinder

  @notice_ms 6_000

  # Below this many letters a description says too little to match.
  @min_description 3

  @doc "The starting state. Off (nil) for a VAT business or document."
  def init(socket, vat?) do
    assign(socket, :hsn, if(vat?, do: nil, else: blank()))
  end

  defp blank do
    %{
      open: nil,
      list: [],
      from: nil,
      lookup: nil,
      query: "",
      suggested: MapSet.new(),
      manual: MapSet.new(),
      notice: nil
    }
  end

  @doc """
  Follows a `phx-change` on the document form: `form` is its name
  ("invoice"), `params` its values and `target` the event's `_target`.
  """
  def on_change(%{assigns: %{hsn: nil}} = socket, _form, _params, _target), do: socket

  def on_change(socket, form, params, target) do
    update(socket, fn hsn -> changed(hsn, form, params, target || []) end)
  end

  defp changed(hsn, form, params, [form, "items", index, "description"]) do
    description = get_in(params, ["items", index, "description"]) || ""

    if String.length(String.trim(description)) >= @min_description do
      %{hsn | open: index, from: :description, list: HsnFinder.suggest(description), lookup: nil}
    else
      close(hsn)
    end
  end

  defp changed(hsn, form, params, [form, "items", index, "hsn_sac"]) do
    code = params |> get_in(["items", index, "hsn_sac"]) |> to_string() |> String.trim()

    hsn = %{
      hsn
      | manual: MapSet.put(hsn.manual, index),
        suggested: MapSet.delete(hsn.suggested, index)
    }

    if Regex.match?(~r/^\d{2,}$/, code),
      do: %{hsn | open: index, from: :code, list: HsnFinder.suggest_code(code), lookup: nil},
      else: close(hsn)
  end

  defp changed(hsn, form, _params, [form, "items", index, "tax_rate"]) do
    %{
      hsn
      | manual: MapSet.put(hsn.manual, index),
        suggested: MapSet.delete(hsn.suggested, index)
    }
  end

  # The "Find HSN/SAC" search box.
  defp changed(%{lookup: index} = hsn, _form, params, ["hsn_lookup"]) when is_binary(index) do
    query = params |> Map.get("hsn_lookup", "") |> to_string()
    %{hsn | query: query}
  end

  defp changed(hsn, form, params, [form, key | _rest]) when key in ["items_sort", "items_drop"] do
    # The form sends every existing index in items_sort. Ecto drops the
    # removed indexes and assigns a position to each remaining or new row.
    order = List.wrap(params["items_sort"]) -- List.wrap(params["items_drop"])
    indexes = Enum.with_index(order)

    %{
      blank()
      | manual: reindex(hsn.manual, indexes),
        suggested: reindex(hsn.suggested, indexes)
    }
  end

  defp changed(hsn, _form, _params, _target), do: hsn

  defp reindex(flags, indexes) do
    for {old, new} <- indexes, MapSet.member?(flags, old), into: MapSet.new() do
      Integer.to_string(new)
    end
  end

  @doc "The \"Find HSN/SAC\" search for a row, by keyword or by code."
  def lookup_results(%{query: query}) do
    query = String.trim(query)

    cond do
      query == "" -> []
      Regex.match?(~r/^\d+$/, query) -> HsnFinder.suggest_code(query, limit: 8)
      true -> HsnFinder.suggest(query, history: false, limit: 8)
    end
  end

  @doc "Opens the \"Find HSN/SAC\" search on a row."
  def open_lookup(socket, index) do
    update(socket, &%{close(&1) | lookup: index, query: ""})
  end

  @doc "Closes the suggestions and the search."
  def close_all(socket), do: update(socket, &close/1)

  defp close(hsn), do: %{hsn | open: nil, list: [], from: nil, lookup: nil, query: ""}

  @doc """
  The form params with a picked code and rate on row `index`, and nothing
  else changed. A rate the form does not offer (an old slab from a past
  invoice) is left as it was; only the code is filled.
  """
  def pick_params(params, index, code, rate) do
    item =
      params
      |> get_in(["items", index])
      |> Kernel.||(%{})
      |> Map.put("hsn_sac", code)
      |> put_rate(rate)

    put_in(params, [Access.key("items", %{}), index], item)
  end

  defp put_rate(item, rate) do
    if to_string(rate) in Enum.map(QuantumBilling.Settings.Organization.gst_rates(), &to_string/1),
      do: Map.put(item, "tax_rate", to_string(rate)),
      else: item
  end

  @doc """
  Marks a row as filled from a suggestion and shows the "please verify"
  note for a few seconds.
  """
  def picked(socket, index, code, rate) do
    Process.send_after(self(), {:clear_hsn_notice, index}, @notice_ms)

    type = code |> HsnFinder.code_type() |> to_string() |> String.upcase()

    update(socket, fn hsn ->
      %{
        close(hsn)
        | suggested: MapSet.put(hsn.suggested, index),
          manual: MapSet.delete(hsn.manual, index),
          notice:
            {index,
             "Suggested #{type} #{code} at #{rate}% — please verify against your product classification."}
      }
    end)
  end

  @doc "Clears the note, unless a later pick has replaced it."
  def clear_notice(socket, index) do
    update(socket, fn
      %{notice: {^index, _text}} = hsn -> %{hsn | notice: nil}
      hsn -> hsn
    end)
  end

  defp update(%{assigns: %{hsn: nil}} = socket, _fun), do: socket
  defp update(socket, fun), do: assign(socket, :hsn, fun.(socket.assigns.hsn))
end
