defmodule NervesLivebook.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  def start(_type, _args) do
    initialize_data_directory()

    setup_wifi()
    add_mix_install()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: NervesLivebook.Supervisor]

    children =
      [
        NervesLivebook.UI,
        {Phoenix.PubSub, name: NervesLivebook.PubSub}
      ] ++ target_children(Nerves.Runtime.mix_target())

    Supervisor.start_link(children, opts)
  end

  defp initialize_data_directory() do
    destination_dir = "/data/livebook"
    source_dir = Application.app_dir(:nerves_livebook, "priv")

    # Best effort create everything
    _ = File.mkdir_p(destination_dir)
    Enum.each(["welcome.livemd", "samples"], &symlink(source_dir, destination_dir, &1))
  end

  defp symlink(source_dir, destination_dir, filename) do
    source = Path.join(source_dir, filename)
    dest = Path.join(destination_dir, filename)

    _ = File.rm(dest)
    _ = File.ln_s(source, dest)
  end

  if Mix.target() == :host do
    defp setup_wifi(), do: :ok
  else
    defp setup_wifi() do
      kv = Nerves.Runtime.KV.get_all()

      if true?(kv["wifi_force"]) or not wlan0_configured?() do
        ssid = kv["wifi_ssid"]
        passphrase = kv["wifi_passphrase"]

        unless empty?(ssid) do
          _ = VintageNetWiFi.quick_configure(ssid, passphrase)
          :ok
        end
      end
    end

    defp wlan0_configured?() do
      VintageNet.get_configuration("wlan0") |> VintageNetWiFi.network_configured?()
    catch
      _, _ -> false
    end

    defp true?(""), do: false
    defp true?(nil), do: false
    defp true?("false"), do: false
    defp true?("FALSE"), do: false
    defp true?(_), do: true

    defp empty?(""), do: true
    defp empty?(nil), do: true
    defp empty?(_), do: false
  end

  if Mix.env() != :test do
    defp add_mix_install() do
      # This needs to be done this way since redefining Mix at compile time
      # doesn't make anyone happy.
      _ =
        Code.eval_string("""
        defmodule Mix do
          def install(deps, opts \\\\ []) when is_list(deps) and is_list(opts) do
            NervesLivebook.MixInstall.install(deps, opts)
          end
        end
        """)

      :ok
    end
  else
    defp add_mix_install(), do: :ok
  end

  if Mix.target() == :host do
    defp target_children(_),
      do: [
        # {Thermometer, %{thermometer: :sin}}
        {Thermometer, %{thermometer: :step}}
      ]
  else
    defp target_children(:srhub), do: [NervesLivebook.WiFiMonitor]

    defp target_children(_),
      do: [
        {Thermometer, %{thermometer: :mlx90614}}
      ]
  end
end
