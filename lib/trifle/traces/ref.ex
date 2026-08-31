defmodule Trifle.Traces.Ref do
  @moduledoc false
  use GenServer

  import Bitwise

  @encoding "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
  @random_mask (1 <<< 80) - 1

  def start_link(_options), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def generate(at \\ DateTime.utc_now()) do
    GenServer.call(__MODULE__, {:generate, at})
  end

  @impl true
  def init(_), do: {:ok, %{last_at_ms: 0, last_random: 0}}

  @impl true
  def handle_call({:generate, at}, _from, state) do
    at_ms = DateTime.to_unix(at, :millisecond)

    {next_ms, random} =
      if at_ms > state.last_at_ms do
        {at_ms, :crypto.strong_rand_bytes(10) |> :binary.decode_unsigned()}
      else
        {state.last_at_ms, band(state.last_random + 1, @random_mask)}
      end

    reference = encode(bor(next_ms <<< 80, random), 26, []) |> IO.iodata_to_binary()
    {:reply, reference, %{last_at_ms: next_ms, last_random: random}}
  end

  defp encode(_value, 0, acc), do: acc

  defp encode(value, remaining, acc) do
    index = band(value, 0x1F)
    encode(value >>> 5, remaining - 1, [binary_part(@encoding, index, 1) | acc])
  end
end
