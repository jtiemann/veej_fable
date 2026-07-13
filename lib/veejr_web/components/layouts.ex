defmodule VeejrWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use VeejrWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  attr :pending_count, :integer,
    default: nil,
    doc: "number of pending encrypted-item notifications, shown on the Contacts link"

  attr :container_class, :string,
    default: "mx-auto max-w-3xl space-y-4",
    doc: "classes applied to the inner page container"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="sticky top-0 z-40 flex min-h-16 flex-wrap items-center gap-2 border-b border-base-300 bg-base-100/95 px-4 py-2 shadow-sm backdrop-blur sm:flex-nowrap sm:px-6 lg:px-8">
      <.link
        navigate={~p"/"}
        class="order-1 text-lg font-bold tracking-tight whitespace-nowrap"
      >
        🔐 veejr
      </.link>
      <details :if={@current_scope} class="dropdown order-2 md:hidden">
        <summary class="btn btn-ghost btn-sm" aria-label="Open navigation menu">
          <.icon name="hero-bars-3" class="size-5" />
        </summary>
        <ul class="menu dropdown-content z-50 mt-2 w-48 rounded-box bg-base-100 p-2 shadow">
          <li>
            <.link navigate={~p"/contacts"}>
              Contacts
              <span :if={@pending_count && @pending_count > 0} class="badge badge-primary badge-sm">
                {@pending_count}
              </span>
            </.link>
          </li>
          <li><.link navigate={~p"/map"}>Map</.link></li>
          <li><.link navigate={~p"/history"}>History</.link></li>
        </ul>
      </details>
      <nav
        :if={@current_scope}
        class="order-3 hidden w-full min-w-0 items-center gap-1 overflow-x-auto md:order-2 md:flex md:w-auto md:flex-1"
      >
        <.link navigate={~p"/contacts"} class="btn btn-ghost btn-sm">
          Contacts
          <span :if={@pending_count && @pending_count > 0} class="badge badge-primary badge-sm">
            {@pending_count}
          </span>
        </.link>
        <.link navigate={~p"/map"} class="btn btn-ghost btn-sm">Map</.link>
        <.link navigate={~p"/history"} class="btn btn-ghost btn-sm">History</.link>
      </nav>
      <div class="order-3 ml-auto shrink-0">
        <ul class="flex px-1 space-x-2 items-center">
          <li><.theme_toggle /></li>
          <%= if @current_scope do %>
            <li class="hidden sm:block text-sm opacity-70">@{@current_scope.user.username}</li>
            <li>
              <.link navigate={~p"/keys"} class="btn btn-ghost btn-sm" title="Encryption keys">
                🔑
              </.link>
            </li>
            <li>
              <.link navigate={~p"/users/settings"} class="btn btn-ghost btn-sm">Settings</.link>
            </li>
            <li>
              <.link href={~p"/users/log-out"} method="delete" class="btn btn-ghost btn-sm">
                Log out
              </.link>
            </li>
          <% else %>
            <li>
              <.link navigate={~p"/users/register"} class="btn btn-ghost btn-sm">Register</.link>
            </li>
            <li><.link navigate={~p"/users/log-in"} class="btn btn-primary btn-sm">Log in</.link></li>
          <% end %>
        </ul>
      </div>
    </header>

    <main class="px-4 py-10 sm:px-6 lg:px-8">
      <div class={@container_class}>
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        auto_dismiss={false}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        auto_dismiss={false}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 [[data-theme-source=system]_&]:!left-0 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
