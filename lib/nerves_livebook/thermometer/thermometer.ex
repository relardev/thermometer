defmodule Thermometer.MLX90614 do
  @moduledoc """
  Module to interface with MLX90614 sensor via I2C
  """
  alias Circuits.I2C
  import Bitwise

  @i2c_address 0x5A

  def start do
    {:ok, ref} = I2C.open("i2c-1")
    {:ok, %{ref: ref}}
  end

  def read_temp(ts) do
    ambient_temp = read_data(ts.ref, 0x06)
    object_temp = read_data(ts.ref, 0x07)
    {ambient_temp, object_temp, ts}
  end

  defp read_data(ref, register) do
    {:ok, <<lsb::8, msb::8, _pec::8>>} = I2C.write_read(ref, @i2c_address, <<register>>, 3)
    temp = ((msb <<< 8) + lsb) * 0.02 - 273.15
    temp
  end
end

defmodule Thermometer.Sin do
  @pi :math.pi()

  def start do
    {:ok, %{x: 0}}
  end

  def read_temp(ts) do
    step = 0.01
    new_x = if ts.x >= 2 * @pi, do: step, else: ts.x + step
    {23.0, 40.0 + :math.sin(ts.x) * 15.0, %{ts | x: new_x}}
  end
end

defmodule Thermometer.Step do
  def start do
    {:ok, %{temp: 0, temp_low: 20, temp_high: 40, remaining_before_change: 50}}
  end

  def read_temp(ts) do
    state =
      if ts.remaining_before_change == 0 do
        temp = if ts.temp == ts.temp_low, do: ts.temp_high, else: ts.temp_low
        remaining_before_change = 50
        %{ts | temp: temp, remaining_before_change: remaining_before_change}
      else
        %{ts | remaining_before_change: ts.remaining_before_change - 1}
      end

    {23.0, state.temp, state}
  end
end

defmodule Thermometer.Broadcast do
  use GenServer

  require Logger

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  def init(args) do
    send(self(), :tick)

    thermometer =
      case args.thermometer do
        :sin -> Thermometer.Sin
        :step -> Thermometer.Step
        :mlx90614 -> Thermometer.MLX90614
      end

    {:ok, ts} =
      thermometer.start()

    {:ok, %{thermometer: thermometer, thermometer_state: ts}}
  end

  def handle_info(:tick, %{thermometer_state: ts} = state) do
    Process.send_after(self(), :tick, 200)

    {ambient_temp, object_temp, ts} =
      state.thermometer.read_temp(ts)

    Phoenix.PubSub.broadcast(NervesLivebook.PubSub, "temperature", %{
      ambient_temp: ambient_temp,
      object_temp: object_temp
    })

    {:noreply, %{state | thermometer_state: ts}}
  end
end
