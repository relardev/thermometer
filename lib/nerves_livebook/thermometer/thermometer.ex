defmodule MLX90614 do
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

defmodule FakeThermometer do
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

defmodule Thermometer do
  use GenServer

  require Logger

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  def init(args) do
    send(self(), :tick)

    {:ok, ts} =
      if args.fake do
        FakeThermometer.start()
      else
        MLX90614.start()
      end

    {:ok, %{fake: args.fake, thermometer_state: ts}}
  end

  def handle_info(:tick, %{thermometer_state: ts} = state) do
    Process.send_after(self(), :tick, 200)

    {ambient_temp, object_temp, ts} =
      if state.fake do
        FakeThermometer.read_temp(ts)
      else
        MLX90614.read_temp(ts)
      end

    Phoenix.PubSub.broadcast(NervesLivebook.PubSub, "temperature", %{
      ambient_temp: ambient_temp,
      object_temp: object_temp
    })

    {:noreply, %{state | thermometer_state: ts}}
  end
end

defmodule Thermometer.Kino do
  use GenServer

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  def init(args) do
    Phoenix.PubSub.subscribe(NervesLivebook.PubSub, "temperature")

    {:ok,
     %{
       plots: args,
       iter: 0,
       data: [],
       consecutive_detected: 0,
       call_down: nil
     }}
  end

  def handle_info(%{ambient_temp: ambient_temp, object_temp: object_temp}, %{
        plots: plots,
        iter: iter,
        data: data,
        consecutive_detected: cd,
        call_down: call_down
      }) do
    data = [object_temp | data] |> Enum.take(75)

    {g1, g2, g3} =
      if iter > 75 do
        element_25 = Enum.at(data, 24)
        element_50 = Enum.at(data, 49)
        element_75 = Enum.at(data, 74)

        {
          grad({75, object_temp}, {50, element_25}),
          grad({50, element_25}, {25, element_50}),
          grad({25, element_50}, {0, element_75})
        }
      else
        {0, 0, 0}
      end

    g1 = g1 * 20
    g2 = g2 * 20
    g3 = g3 * 20

    detected =
      0.5 < g1 && g1 < 5 &&
        0.5 < g2 && g2 < 5 &&
        0.5 < g3 && g3 < 5 &&
        g1 < g2 && g2 < g3

    cd =
      if detected, do: cd + 1, else: 0

    detectedInt = if detected, do: 10, else: 0

    update_plot(plots.temp_plot, %{
      iter: iter,
      ambient_temp: ambient_temp,
      object_temp: object_temp
    })

    update_plot(plots.g_plot, %{
      iter: iter,
      g1: g1,
      g2: g2,
      g3: g3
    })

    update_plot(plots.detect_plot, %{
      iter: iter,
      detected: detectedInt,
      conseq_detected: cd
    })

    update_plot(plots.call_down_plot, %{
      iter: iter,
      call_down:
        if call_down != nil do
          DateTime.diff(call_down, DateTime.utc_now(), :second)
        else
          0
        end
    })

    call_down =
      if call_down != nil && DateTime.compare(DateTime.utc_now(), call_down) == :gt do
        nil
      else
        call_down
      end

    call_down =
      if cd == 25 && call_down == nil do
        dbg("Send Alert")
        DateTime.add(DateTime.utc_now(), 2 * 60, :second)
      else
        call_down
      end

    {:noreply,
     %{
       plots: plots,
       iter: iter + 1,
       data: data,
       consecutive_detected: cd,
       call_down: call_down
     }}
  end

  def grad({x1, y1}, {x2, y2}) do
    (y2 - y1) / (x2 - x1)
  end

  defp update_plot(plot, data) do
    Kino.VegaLite.push(plot, data, window: 500)
  end
end

defmodule Thermometer.Show do
  alias VegaLite, as: Vl

  def plot() do
    plot_width = 300
    plot_height = 300
    padding = 5

    temp_plot =
      Vl.new(width: plot_width, height: plot_height, padding: padding)
      |> Vl.repeat(
        [
          layer: [
            "ambient_temp",
            "object_temp",
            "call_down"
          ]
        ],
        Vl.new()
        |> Vl.mark(:line)
        |> Vl.encode_field(:x, "iter", type: :quantitative, title: "Tick")
        |> Vl.encode_repeat(:y, :layer, type: :quantitative, title: "Temperature (°C)")
        |> Vl.encode(:color, datum: [repeat: :layer], type: :nominal)
      )
      |> Kino.VegaLite.new()

    g_plot =
      Vl.new(width: plot_width, height: plot_height, padding: padding)
      |> Vl.repeat(
        [
          layer: [
            "g1",
            "g2",
            "g3"
          ]
        ],
        Vl.new()
        |> Vl.mark(:line)
        |> Vl.encode_field(:x, "iter", type: :quantitative, title: "Tick")
        |> Vl.encode_repeat(:y, :layer, type: :quantitative, title: "Angle (°)")
        |> Vl.encode(:color, datum: [repeat: :layer], type: :nominal)
      )
      |> Kino.VegaLite.new()

    detect_plot =
      Vl.new(width: plot_width, height: plot_height, padding: padding)
      |> Vl.repeat(
        [
          layer: [
            "detected",
            "conseq_detected"
          ]
        ],
        Vl.new()
        |> Vl.mark(:line)
        |> Vl.encode_field(:x, "iter", type: :quantitative, title: "Tick")
        |> Vl.encode_repeat(:y, :layer, type: :quantitative, title: "Unit")
        |> Vl.encode(:color, datum: [repeat: :layer], type: :nominal)
      )
      |> Kino.VegaLite.new()

    call_down_plot =
      Vl.new(width: plot_width, height: plot_height, padding: padding)
      |> Vl.mark(:line)
      |> Vl.encode_field(:x, "iter", type: :quantitative, title: "Tick")
      |> Vl.encode_field(:y, "call_down", type: :quantitative, title: "CallDown (s)")
      |> Kino.VegaLite.new()

    GenServer.start(Thermometer.Kino, %{
      temp_plot: temp_plot,
      g_plot: g_plot,
      detect_plot: detect_plot,
      call_down_plot: call_down_plot
    })

    Kino.Layout.grid([temp_plot, g_plot, detect_plot, call_down_plot], columns: 2)
  end
end
