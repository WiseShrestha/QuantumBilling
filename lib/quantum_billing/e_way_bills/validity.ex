defmodule QuantumBilling.EWayBills.Validity do
  @moduledoc """
  E-way bill validity under Rule 138(10) of the CGST Rules.

  One day per 200 km or part (20 km for over-dimensional cargo). Each day ends
  at midnight of the day after generation, so a 150 km bill made at 6pm is
  valid until the end of tomorrow.

  Days are counted on Indian Standard Time, a fixed UTC+05:30 with no
  daylight saving. Times go in and come out as UTC (`valid_until` is stored as
  a UTC `NaiveDateTime`); `to_ist/1` converts one for display.
  """

  @kilometres_per_day %{regular: 200, over_dimensional: 20}

  # IST is UTC+05:30 all year.
  @ist_offset_seconds 5 * 3600 + 30 * 60

  # Rule 138(10): an extension may be asked for from eight hours before to
  # eight hours after the bill expires.
  @extension_window_seconds 8 * 3600

  @doc """
  The last valid instant, in UTC, of a bill generated at `generated_at` (UTC).
  `cargo` is `:regular` (default) or `:over_dimensional`.
  """
  def valid_until(generated_at, distance_km, cargo \\ :regular)

  def valid_until(%NaiveDateTime{} = generated_at, distance_km, cargo) do
    generated_at
    |> ist_date()
    |> Date.add(days(distance_km, cargo))
    |> NaiveDateTime.new!(~T[23:59:59])
    |> from_ist()
  end

  def valid_until(%DateTime{} = generated_at, distance_km, cargo) do
    generated_at
    |> DateTime.shift_zone!("Etc/UTC")
    |> DateTime.to_naive()
    |> valid_until(distance_km, cargo)
  end

  @doc "The Indian calendar date of a UTC instant."
  def ist_date(%DateTime{} = at),
    do: at |> DateTime.shift_zone!("Etc/UTC") |> DateTime.to_naive() |> ist_date()

  def ist_date(%NaiveDateTime{} = at), do: at |> to_ist() |> NaiveDateTime.to_date()

  @doc "A UTC `NaiveDateTime` as Indian local time."
  def to_ist(%NaiveDateTime{} = utc), do: NaiveDateTime.add(utc, @ist_offset_seconds, :second)
  def to_ist(nil), do: nil

  @doc "An Indian local time as a UTC `NaiveDateTime`."
  def from_ist(%NaiveDateTime{} = ist), do: NaiveDateTime.add(ist, -@ist_offset_seconds, :second)

  @doc """
  Whether `now` (UTC) is inside the Rule 138(10) extension window of a bill
  valid until `valid_until` (UTC): eight hours either side, edges included.
  """
  def extendable?(%NaiveDateTime{} = valid_until, %NaiveDateTime{} = now) do
    abs(NaiveDateTime.diff(now, valid_until, :second)) <= @extension_window_seconds
  end

  def extendable?(_valid_until, _now), do: false

  @doc "The extension window either side of expiry, in hours."
  def extension_window_hours, do: div(@extension_window_seconds, 3600)

  @doc """
  How many days of validity a distance earns: one per 200 km or part of one,
  and never fewer than one.
  """
  def days(distance_km, cargo \\ :regular)

  def days(distance_km, cargo) when is_integer(distance_km) and distance_km > 0 do
    max(1, ceil(distance_km / kilometres_per_day(cargo)))
  end

  # No distance recorded: the one-day minimum.
  def days(_unknown_distance, _cargo), do: 1

  @doc "Kilometres that earn one day of validity, by cargo type."
  def kilometres_per_day(cargo), do: Map.get(@kilometres_per_day, cargo, 200)
end
