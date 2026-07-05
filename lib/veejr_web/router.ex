defmodule VeejrWeb.Router do
  use VeejrWeb, :router

  import VeejrWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {VeejrWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :federation do
    plug :accepts, ["json"]
    plug VeejrWeb.FederationAuth
  end

  scope "/", VeejrWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  # Public instance API: the surface other veejr instances (and curious
  # humans) can query without authentication.
  scope "/api", VeejrWeb do
    pipe_through :api

    get "/instance", InstanceController, :instance
    get "/directory/:username", InstanceController, :directory

    # Capability URL: the unguessable id (delivered only to the recipient's
    # instance) is the credential, and the content is E2E ciphertext.
    get "/envelopes/:public_id", FederationController, :envelope
  end

  # Public attachment capability. No pipeline: serves opaque octet-stream
  # bytes (not JSON) to a recipient's browser, which may be on another
  # instance. The blob id is an unguessable capability and the content is
  # E2E-encrypted; see BlobController.public_show/2.
  scope "/api", VeejrWeb do
    get "/blobs/:id", BlobController, :public_show
  end

  # Instance-to-instance writes require a valid signature from a pinned peer.
  scope "/api/federation", VeejrWeb do
    pipe_through :federation

    post "/friend_request", FederationController, :friend_request
    post "/friend_response", FederationController, :friend_response
    post "/notify", FederationController, :notify
    post "/key_update", FederationController, :key_update
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:veejr, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: VeejrWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## Authentication routes

  scope "/", VeejrWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [{VeejrWeb.UserAuth, :require_authenticated}] do
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email
      live "/keys", KeysLive
    end

    live_session :app,
      on_mount: [
        {VeejrWeb.UserAuth, :require_authenticated},
        {VeejrWeb.KeyGate, :ensure_keys},
        VeejrWeb.LiveNotify
      ] do
      live "/friends", FriendsLive
      live "/groups", GroupsLive
      live "/messages", MessagesLive
      live "/map", MapLive
      live "/history", HistoryLive
    end

    post "/users/update-password", UserSessionController, :update_password
    post "/blobs", BlobController, :create
    get "/blobs/:id", BlobController, :show
    get "/export", ExportController, :download
    post "/push/subscriptions", PushController, :create
    delete "/push/subscriptions", PushController, :delete
  end

  scope "/", VeejrWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [{VeejrWeb.UserAuth, :mount_current_scope}] do
      live "/users/register", UserLive.Registration, :new
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end
end
