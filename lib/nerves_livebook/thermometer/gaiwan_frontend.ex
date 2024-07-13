defmodule Gaiwan.Frontend do
  alias VegaLite, as: Vl

  def start() do
    plots = create_plots()

    source_dir = Application.app_dir(:nerves_livebook, "priv")

    audio =
      Thermometer.Kino.Audio.new(File.read!(Path.join(source_dir, "audio/short_alarm.mp3")), :mp3,
        autoplay: false,
        loop: false
      )

    gaiwan_args = %{
      alert_fn: fn ->
        Thermometer.Kino.Audio.play(audio)
      end,
      plots: plots
    }

    if !Thermometer.Gaiwan.running?() do
      {:ok, _} =
        Thermometer.Gaiwan.start(gaiwan_args)

      plots
    else
      Thermometer.Gaiwan.update_args(gaiwan_args)
    end

    Kino.Layout.grid([plots.temp, plots.g, plots.detect, plots.call_down, audio], columns: 2)
  end

  defp create_plots() do
    plot_width = 300
    plot_height = 300
    padding = 5

    temp =
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

    g =
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

    detect =
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

    call_down =
      Vl.new(width: plot_width, height: plot_height, padding: padding)
      |> Vl.mark(:line)
      |> Vl.encode_field(:x, "iter", type: :quantitative, title: "Tick")
      |> Vl.encode_field(:y, "call_down", type: :quantitative, title: "CallDown (s)")
      |> Kino.VegaLite.new()

    %{
      temp: temp,
      g: g,
      detect: detect,
      call_down: call_down
    }
  end
end
