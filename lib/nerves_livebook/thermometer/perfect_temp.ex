defmodule PerfectTemp.Frontend do
  alias VegaLite, as: Vl

  def start() do
    treshold = 50

    range =
      Kino.Input.range(
        "Set the perfect temperature:",
        min: 20,
        max: 80,
        step: 1,
        default: treshold,
        debounce: 30
      )

    plot = plot()

    source_dir = Application.app_dir(:nerves_livebook, "priv")

    audio =
      Thermometer.Kino.Audio.new(File.read!(Path.join(source_dir, "audio/short_alarm.mp3")), :mp3,
        autoplay: false,
        loop: false
      )

    text = Live.Text.new("Current treshold: #{treshold}°C")

    Thermometer.PerfectTemp.start(%{
      input: range,
      treshold: treshold,
      plot: plot,
      update_fn: fn value ->
        Live.Text.replace(text, "Current treshold: #{value}°C")
      end,
      alert_fn: fn ->
        Thermometer.Kino.Audio.play(audio)
      end
    })

    Kino.Layout.grid([range, text, plot, audio], columns: 1)
  end

  def plot() do
    plot_width = 600
    plot_height = 400
    padding = 5

    Vl.new(width: plot_width, height: plot_height, padding: padding)
    |> Vl.repeat(
      [
        layer: [
          "ambient_temp",
          "object_temp",
          "treshold"
        ]
      ],
      Vl.new()
      |> Vl.mark(:line)
      |> Vl.encode_field(:x, "iter", type: :quantitative, title: "Tick")
      |> Vl.encode_repeat(:y, :layer, type: :quantitative, title: "Temperature (°C)")
      |> Vl.encode(:color, datum: [repeat: :layer], type: :nominal)
    )
    |> Kino.VegaLite.new()
  end
end

defmodule Thermometer.PerfectTemp do
  use GenServer

  def start(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  def init(args) do
    Phoenix.PubSub.subscribe(NervesLivebook.PubSub, "temperature")

    Kino.Control.subscribe(args.input, :input)

    {:ok,
     %{
       iter: 0,
       treshold: args.treshold,
       plot: args.plot,
       update_fn: args.update_fn,
       alert_fn: args.alert_fn
     }}
  end

  def handle_info({:input, %{value: value}}, state) do
    state.update_fn.(value)
    {:noreply, %{state | treshold: value}}
  end

  def handle_info(%{ambient_temp: ambient_temp, object_temp: object_temp}, state) do
    if close(object_temp, state.treshold) do
      state.alert_fn.()
    end

    Kino.VegaLite.push(
      state.plot,
      %{
        iter: state.iter,
        ambient_temp: ambient_temp,
        object_temp: object_temp,
        treshold: state.treshold
      },
      window: 500
    )

    {:noreply, %{state | iter: state.iter + 1}}
  end

  defp close(object_temp, treshold), do: abs(object_temp - treshold) < 1
end

defmodule Live.Text do
  use Kino.JS
  use Kino.JS.Live

  def new(html) do
    Kino.JS.Live.new(__MODULE__, html)
  end

  def replace(kino, html) do
    Kino.JS.Live.cast(kino, {:replace, html})
  end

  @impl true
  def init(html, ctx) do
    {:ok, assign(ctx, html: html)}
  end

  @impl true
  def handle_connect(ctx) do
    {:ok, ctx.assigns.html, ctx}
  end

  @impl true
  def handle_cast({:replace, html}, ctx) do
    broadcast_event(ctx, "replace", html)
    {:noreply, assign(ctx, html: html)}
  end

  asset "main.js" do
    """
    export function init(ctx, html) {
      ctx.root.innerHTML = html;

      ctx.handleEvent("replace", (html) => {
        ctx.root.innerHTML = html;
      });
    }
    """
  end
end
