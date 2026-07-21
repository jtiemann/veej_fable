import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/veejr start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :veejr, VeejrWeb.Endpoint, server: true
end

config :veejr, VeejrWeb.Endpoint, http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :prod do
  config :veejr,
    instance_mode:
      if(System.get_env("VEEJR_MODE") == "personal", do: :personal, else: :community),
    blob_dir: System.get_env("VEEJR_BLOB_DIR") || "/var/lib/veejr/uploads",
    migration_dir: System.get_env("VEEJR_MIGRATION_DIR") || "/var/lib/veejr/migrations",
    provisioner_token: System.get_env("VEEJR_PROVISIONER_TOKEN")

  if repo = System.get_env("VEEJR_UPDATE_REPO") do
    config :veejr, update_repo: repo
  end

  # WebRTC ICE servers: comma-separated STUN URLs, plus optional TURN relay
  # URLs with static credentials (see OPERATIONS.md for a coturn sidecar).
  stun_servers =
    case System.get_env("VEEJR_STUN_URLS") do
      nil -> [%{urls: ["stun:stun.l.google.com:19302"]}]
      urls -> [%{urls: urls |> String.split(",", trim: true) |> Enum.map(&String.trim/1)}]
    end

  turn_servers =
    case System.get_env("VEEJR_TURN_URLS") || System.get_env("VEEJR_TURN_URL") do
      nil ->
        []

      configured_urls ->
        # Advertise TCP alongside UDP when the URL does not pin a transport.
        # `turns:` is TLS-over-TCP, so it only needs its explicit TCP variant.
        urls =
          configured_urls
          |> String.split(",", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.flat_map(fn url ->
            separator = if String.contains?(url, "?"), do: "&", else: "?"

            cond do
              String.contains?(url, "transport=") -> [url]
              String.starts_with?(url, "turns:") -> [url <> separator <> "transport=tcp"]
              true -> [url, url <> separator <> "transport=tcp"]
            end
          end)
          |> Enum.uniq()

        [
          %{
            urls: urls,
            username: System.get_env("VEEJR_TURN_USERNAME") || "",
            credential: System.get_env("VEEJR_TURN_PASSWORD") || ""
          }
        ]
    end

  config :veejr, ice_servers: stun_servers ++ turn_servers

  database_path =
    System.get_env("DATABASE_PATH") ||
      raise """
      environment variable DATABASE_PATH is missing.
      For example: /etc/veejr/veejr.db
      """

  config :veejr, Veejr.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5")

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :veejr, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :veejr, VeejrWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  mail_from_address =
    System.get_env("MAIL_FROM_ADDRESS") ||
      raise """
      environment variable MAIL_FROM_ADDRESS is missing.
      For example: hello@your-domain.example
      """

  config :veejr,
    mail_from: {System.get_env("MAIL_FROM_NAME") || "Veejr", mail_from_address}

  fcm_service_account_json =
    case System.get_env("FCM_SERVICE_ACCOUNT_JSON_FILE") do
      nil -> System.get_env("FCM_SERVICE_ACCOUNT_JSON")
      path -> File.read!(path)
    end

  case fcm_service_account_json do
    nil -> :ok
    json -> config :veejr, :fcm_service_account, Jason.decode!(json)
  end

  smtp_host =
    System.get_env("SMTP_HOST") ||
      raise """
      environment variable SMTP_HOST is missing.
      For example: smtp.sendgrid.net
      """

  smtp_port = String.to_integer(System.get_env("SMTP_PORT") || "587")

  smtp_auth =
    case System.get_env("SMTP_AUTH") || "always" do
      "never" -> :never
      _ -> :always
    end

  smtp_tls =
    case System.get_env("SMTP_TLS") || "always" do
      "never" -> :never
      "if_available" -> :if_available
      _ -> :always
    end

  config :veejr, Veejr.Mailer,
    adapter: Swoosh.Adapters.SMTP,
    relay: smtp_host,
    username: System.get_env("SMTP_USERNAME"),
    password: System.get_env("SMTP_PASSWORD"),
    port: smtp_port,
    ssl: System.get_env("SMTP_SSL") in ["1", "true", "TRUE"],
    tls: smtp_tls,
    tls_options: [
      versions: [:"tlsv1.3", :"tlsv1.2"],
      verify: :verify_peer,
      cacertfile: "/etc/ssl/certs/ca-certificates.crt",
      depth: 4,
      server_name_indication: String.to_charlist(smtp_host)
    ],
    auth: smtp_auth,
    retries: 2,
    no_mx_lookups: false

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :veejr, VeejrWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :veejr, VeejrWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :veejr, Veejr.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://swoosh.hexdocs.pm/Swoosh.html#module-installation for details.
end
