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

defmodule SinThermometer do
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

defmodule StepThermometer do
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

defmodule Thermometer do
  use GenServer

  require Logger

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  def init(args) do
    send(self(), :tick)

    thermometer =
      case args.thermometer do
        :sin -> SinThermometer
        :step -> StepThermometer
        :mlx90614 -> MLX90614
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
       call_down: nil,
       detection_params: %{
         moving_avg_window: 3,
         point_spacing: 10,
         min_grad: 0.5,
         max_grad: 5
       },
       prev_detected: []
     }}
  end

  def handle_call({:update_detection_params, params}, _from, state) do
    new_params = Map.merge(state.detection_params, params)
    {:reply, new_params, %{state | detection_params: new_params}}
  end

  def handle_info(%{ambient_temp: ambient_temp, object_temp: object_temp}, %{
        plots: plots,
        iter: iter,
        data: data,
        call_down: call_down,
        prev_detected: prev_detected,
        detection_params: dp
      }) do
    datum = EmaCalculator.new_point(object_temp, Enum.take(data, dp.moving_avg_window))

    data = [datum | data] |> Enum.take(3 * dp.point_spacing)

    {g1, g2, g3} =
      if iter > 3 * dp.point_spacing do
        second = 2 * dp.point_spacing
        third = 3 * dp.point_spacing
        point1s = Enum.slice(data, (dp.point_spacing - 3)..(dp.point_spacing - 1))
        point2s = Enum.slice(data, (second - 3)..(second - 1))
        point3s = Enum.slice(data, (third - 3)..(third - 1))

        point1 = Enum.reduce(point1s, 0, &Kernel.+/2) / Enum.count(point1s)
        point2 = Enum.reduce(point2s, 0, &Kernel.+/2) / Enum.count(point2s)
        point3 = Enum.reduce(point3s, 0, &Kernel.+/2) / Enum.count(point3s)


        {
          grad({3 * dp.point_spacing, datum}, {2 * dp.point_spacing, point1}),
          grad({2 * dp.point_spacing, point1}, {1 * dp.point_spacing, point2}),
          grad({1 * dp.point_spacing, point2}, {0, point3})
        }
      else
        {0, 0, 0}
      end

    g1 = g1 * 20
    g2 = g2 * 20
    g3 = g3 * 20

    detected =
      dp.min_grad < g1 && g1 < dp.max_grad &&
        dp.min_grad < g2 && g2 < dp.max_grad &&
        dp.min_grad < g3 && g3 < dp.max_grad &&
        g1 < g2 && g2 < g3

    prev_detected = [detected | Enum.take(prev_detected, 100)]

    detection_level = Enum.count(prev_detected, & &1)

    detectedInt = if detected, do: 10, else: 0

    update_plot(plots.temp_plot, %{
      iter: iter,
      ambient_temp: ambient_temp,
      object_temp: object_temp,
      moving_avg: datum
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
      detection_level: detection_level
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
      if detection_level == 15 && call_down == nil do
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
       prev_detected: prev_detected,
       call_down: call_down,
       detection_params: dp
     }}
  end

  def grad({x1, y1}, {x2, y2}) do
    (y2 - y1) / (x2 - x1)
  end

  defp update_plot(plot, data) do
    Kino.VegaLite.push(plot, data, window: 500)
  end
end

defmodule EmaCalculator do
  def new_point(datum, old_data) do
    len = length(old_data)

    if len == 0 do
      datum
    else
      weights = [1 | Enum.map(0..(len - 1), &((len - &1) / (2 * len)))]

      data_weighted = Enum.zip([datum | old_data], weights)

      weights_sum = Enum.sum(weights)

      new_point = Enum.reduce(data_weighted, 0, fn {d, w}, acc -> d * w + acc end)
      final = new_point / weights_sum

      final
    end
  end
end

defmodule Thermometer.Show do
  alias VegaLite, as: Vl

  def update_detection_params(params) do
    GenServer.call(Thermometer.Kino, {:update_detection_params, params})
  end

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
            "moving_avg"
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
            "detection_level"
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

    GenServer.start(
      Thermometer.Kino,
      %{
        temp_plot: temp_plot,
        g_plot: g_plot,
        detect_plot: detect_plot,
        call_down_plot: call_down_plot
      },
      name: Thermometer.Kino
    )

    Kino.Layout.grid([temp_plot, g_plot, detect_plot, call_down_plot], columns: 2)
  end
end
