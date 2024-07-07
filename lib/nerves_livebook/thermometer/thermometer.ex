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
       call_down: nil,
       detection_params: %{
         moving_avg_window: 5,
         point_spacing: 10,
         min_grad: 0.5,
         max_grad: 5
       }
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
        consecutive_detected: cd,
        call_down: call_down,
        detection_params: dp
      }) do
    datum = new_point(object_temp, Enum.take(data, dp.moving_avg_window))

    data = [datum | data] |> Enum.take(3 * dp.point_spacing)

    {g1, g2, g3} =
      if iter > 3 * dp.point_spacing do
        point1 = Enum.at(data, dp.point_spacing - 1)
        poing2 = Enum.at(data, 2 * dp.point_spacing - 1)
        poing3 = Enum.at(data, 3 * dp.point_spacing - 1)

        {
          grad({3 * dp.point_spacing, datum}, {2 * dp.point_spacing, point1}),
          grad({2 * dp.point_spacing, point1}, {1 * dp.point_spacing, poing2}),
          grad({1 * dp.point_spacing, poing2}, {0, poing3})
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

    cd =
      if detected, do: cd + 1, else: 0

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
       call_down: call_down,
       detection_params: dp
     }}
  end

  defp new_point(datum, old_data) do
    Enum.sum([datum | old_data]) / (length(old_data) + 1)
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
