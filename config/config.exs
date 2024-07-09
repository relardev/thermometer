import Config

# Enable the Nerves integration with Mix
Application.start(:nerves_bootstrap)

# Customize non-Elixir parts of the firmware. See
# https://hexdocs.pm/nerves/advanced-configuration.html for details.

config :nerves, :firmware,
  rootfs_overlay: "rootfs_overlay",
  provisioning: "config/provisioning.conf"

if Mix.env() != :test do
  # Set log level to warning by default to reduce output except for testing
  # The unit tests rely on info level log messages.
  config :logger, level: :warning
end

# Set the SOURCE_DATE_EPOCH date for reproducible builds.
# See https://reproducible-builds.org/docs/source-date-epoch/ for more information

config :nerves, source_date_epoch: "1603310828"

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Add mime type to upload notebooks with `Phoenix.LiveView.Upload`
config :mime, :types, %{
  "text/plain" => ["livemd"]
}

# Sets the default storage backend
config :livebook, :storage, Livebook.Storage.Ets

# Livebook's learn section is built at compile-time
config :livebook, :learn_notebooks, [
  %{
    path: "#{File.cwd!()}/priv/steep.livemd",
    slug: "steep",
    details: %{
      cover_path: "#{File.cwd!()}/assets/nerves.svg",
      description: "Steep tea with thermometer"
    }
  },
  %{
    path: "#{File.cwd!()}/priv/samples/networking/configure_wifi.livemd",
    slug: "wifi",
    details: %{
      cover_path: "#{File.cwd!()}/assets/wifi-setup.svg",
      description: "Connect Nerves Livebook to a wireless network."
    }
  }
]

# Enable the embedded runtime which isn't available by default
config :livebook, :runtime_modules, [Livebook.Runtime.Embedded, Livebook.Runtime.Attached]

# Forward the package search trough a custom handler to only show local ones.
config :livebook, Livebook.Runtime.Embedded,
  load_packages: {NervesLivebook.Dependencies, :packages, []}

# Allow Livebook to power off  the device
config :livebook, :shutdown_callback, {Process, :spawn, [Nerves.Runtime, :poweroff, [], []]}

# Defaults for required configurations
config :livebook,
  teams_url: "https://teams.livebook.dev",
  app_service_name: nil,
  app_service_url: nil,
  feature_flags: [],
  force_ssl_host: nil,
  update_instructions_url: nil,
  within_iframe: false,
  allowed_uri_schemes: [],
  aws_credentials: false

if Mix.target() == :host do
  import_config "host.exs"
else
  import_config "target.exs"
end
