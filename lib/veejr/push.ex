defmodule Veejr.Push do
  @moduledoc """
  Browser push subscriptions and delivery.

  Each device/browser that opts in registers a `PushSubscription`; when an
  encrypted item arrives, every subscription of the recipient gets a
  content-free push ("@bob sent you an encrypted message") so the pull model
  survives even with the tab closed. Dead subscriptions (404/410 from the
  push service) are pruned automatically.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Veejr.Accounts.User
  alias Veejr.Push.WebPush
  alias Veejr.Repo
  alias Veejr.Social.Address

  defmodule Subscription do
    use Ecto.Schema

    schema "push_subscriptions" do
      belongs_to :user, Veejr.Accounts.User
      field :endpoint, :string
      field :p256dh, :string
      field :auth, :string

      timestamps(type: :utc_datetime)
    end
  end

  @doc "Registers (or refreshes) a browser subscription for the user."
  def subscribe(%User{} = user, %{
        "endpoint" => endpoint,
        "keys" => %{"p256dh" => p256dh, "auth" => auth}
      })
      when is_binary(endpoint) and is_binary(p256dh) and is_binary(auth) do
    %Subscription{}
    |> Ecto.Changeset.change(user_id: user.id, endpoint: endpoint, p256dh: p256dh, auth: auth)
    |> Ecto.Changeset.unique_constraint(:endpoint)
    |> Repo.insert(
      on_conflict: {:replace, [:user_id, :p256dh, :auth, :updated_at]},
      conflict_target: :endpoint
    )
  end

  def subscribe(_user, _params), do: {:error, :invalid_subscription}

  def unsubscribe(%User{id: user_id}, endpoint) do
    from(s in Subscription, where: s.user_id == ^user_id and s.endpoint == ^endpoint)
    |> Repo.delete_all()

    :ok
  end

  def subscription_count(%User{id: user_id}) do
    from(s in Subscription, where: s.user_id == ^user_id) |> Repo.aggregate(:count)
  end

  @doc """
  Pushes a content-free alert for a new notification to all of the
  recipient's devices. Called async from the messaging path.
  """
  def notify(notification) do
    subscriptions =
      from(s in Subscription, where: s.user_id == ^notification.user_id) |> Repo.all()

    payload = %{
      title: "veejr",
      body:
        "#{Address.handle(notification.envelope.sender)} sent you an encrypted " <>
          "#{notification.envelope.kind}. Open veejr to request it.",
      url: "/messages"
    }

    for subscription <- subscriptions do
      case WebPush.send_push(subscription, payload) do
        {:ok, _status} ->
          :ok

        {:error, {:http, status}} when status in [404, 410] ->
          Repo.delete(subscription)
          Logger.info("push: pruned dead subscription for user #{notification.user_id}")

        {:error, reason} ->
          Logger.warning("push: delivery failed: #{inspect(reason)}")
      end
    end

    :ok
  end

  @doc "Fire-and-forget `notify/1`; disabled via config in tests."
  def notify_async(notification) do
    if Application.get_env(:veejr, :push_enabled, true) do
      Task.Supervisor.start_child(Veejr.TaskSupervisor, fn -> notify(notification) end)
    end

    :ok
  end
end
