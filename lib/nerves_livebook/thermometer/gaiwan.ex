defmodule Thermometer.Gaiwan do
  use GenServer

  def start(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  def running? do
    Process.whereis(__MODULE__) != nil
  end

  def update_plots(plots) do
    GenServer.call(__MODULE__, {:update_plots, plots})
  end

  def update_detection_params(params) do
    GenServer.call(__MODULE__, {:update_detection_params, params})
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

  def handle_call({:update_plots, plots}, _from, state) do
    {:reply, state.plots, %{state | plots: plots}}
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

    update_plot(plots.temp, %{
      iter: iter,
      ambient_temp: ambient_temp,
      object_temp: object_temp,
      moving_avg: datum
    })

    update_plot(plots.g, %{
      iter: iter,
      g1: g1,
      g2: g2,
      g3: g3
    })

    update_plot(plots.detect, %{
      iter: iter,
      detected: detectedInt,
      detection_level: detection_level
    })

    update_plot(plots.call_down, %{
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
