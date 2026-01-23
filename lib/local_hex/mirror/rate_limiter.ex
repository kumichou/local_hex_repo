defmodule LocalHex.Mirror.RateLimiter do
  @moduledoc """
  Simple token-bucket rate limiter for upstream (Hex.pm) requests.

  This is intentionally lightweight and process-local: it limits requests per BEAM instance.
  """

  use GenServer

  @name __MODULE__

  def start_link(opts) when is_map(opts) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @doc """
  Block until a token is available.

  No-op if the limiter is not started.
  """
  def wait do
    case Process.whereis(@name) do
      nil ->
        :ok

      _pid ->
        do_wait()
    end
  end

  defp do_wait do
    case GenServer.call(@name, :acquire, :infinity) do
      :ok ->
        :ok

      {:wait, ms} when is_integer(ms) and ms > 0 ->
        Process.sleep(ms)
        do_wait()
    end
  end

  @impl true
  def init(opts) do
    rps = Map.get(opts, :hex_rps, 2.0)
    burst = Map.get(opts, :hex_burst, 5)

    state = %{
      rps: rps * 1.0,
      capacity: burst,
      tokens: burst * 1.0,
      last_ms: now_ms()
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:acquire, _from, state) do
    state = refill(state)

    if state.tokens >= 1.0 do
      {:reply, :ok, %{state | tokens: state.tokens - 1.0}}
    else
      ms =
        if state.rps > 0 do
          ceil((1.0 - state.tokens) / state.rps * 1000)
        else
          1000
        end

      {:reply, {:wait, ms}, state}
    end
  end

  defp refill(state) do
    now = now_ms()
    elapsed = max(0, now - state.last_ms)
    add = state.rps * elapsed / 1000.0
    tokens = min(state.capacity * 1.0, state.tokens + add)
    %{state | tokens: tokens, last_ms: now}
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
