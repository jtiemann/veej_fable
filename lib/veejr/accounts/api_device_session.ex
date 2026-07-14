defmodule Veejr.Accounts.ApiDeviceSession do
  use Ecto.Schema
  import Ecto.Changeset

  @access_lifetime_seconds 15 * 60
  @refresh_lifetime_seconds 30 * 24 * 60 * 60
  @absolute_lifetime_seconds 90 * 24 * 60 * 60
  @token_bytes 32

  schema "api_device_sessions" do
    field :device_name, :string
    field :platform, :string
    field :app_version, :string
    field :access_token_hash, :binary, redact: true
    field :access_expires_at, :utc_datetime
    field :refresh_token_hash, :binary, redact: true
    field :refresh_expires_at, :utc_datetime
    field :authenticated_at, :utc_datetime
    field :last_used_at, :utc_datetime
    field :push_token, :string, redact: true
    field :push_token_updated_at, :utc_datetime

    belongs_to :user, Veejr.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def create_changeset(session, user, attrs, now \\ DateTime.utc_now(:second)) do
    {access_token, access_hash} = build_token()
    {refresh_token, refresh_hash} = build_token()
    attrs = normalize_device_name(attrs)

    changeset =
      session
      |> cast(attrs, [:device_name, :platform, :app_version])
      |> validate_required([:device_name, :platform])
      |> validate_inclusion(:platform, ["android"])
      |> validate_length(:device_name, min: 1, max: 120)
      |> validate_length(:app_version, max: 40)
      |> put_change(:user_id, user.id)
      |> put_change(:access_token_hash, access_hash)
      |> put_change(:access_expires_at, DateTime.add(now, @access_lifetime_seconds, :second))
      |> put_change(:refresh_token_hash, refresh_hash)
      |> put_change(:refresh_expires_at, DateTime.add(now, @refresh_lifetime_seconds, :second))
      |> put_change(:authenticated_at, now)
      |> put_change(:last_used_at, now)
      |> unique_constraint(:access_token_hash)
      |> unique_constraint(:refresh_token_hash)

    {changeset, tokens(access_token, refresh_token, changeset)}
  end

  def rotate_changeset(session, now \\ DateTime.utc_now(:second)) do
    {access_token, access_hash} = build_token()
    {refresh_token, refresh_hash} = build_token()
    absolute_expiry = DateTime.add(session.inserted_at, @absolute_lifetime_seconds, :second)
    rolling_expiry = DateTime.add(now, @refresh_lifetime_seconds, :second)
    refresh_expiry = earlier(absolute_expiry, rolling_expiry)

    changeset =
      change(session,
        access_token_hash: access_hash,
        access_expires_at: DateTime.add(now, @access_lifetime_seconds, :second),
        refresh_token_hash: refresh_hash,
        refresh_expires_at: refresh_expiry,
        last_used_at: now
      )
      |> unique_constraint(:access_token_hash)
      |> unique_constraint(:refresh_token_hash)

    {changeset, tokens(access_token, refresh_token, changeset)}
  end

  def hash_token(token) when is_binary(token) do
    with {:ok, decoded} <- Base.url_decode64(token, padding: false),
         true <- byte_size(decoded) == @token_bytes do
      {:ok, :crypto.hash(:sha256, decoded)}
    else
      _ -> :error
    end
  end

  defp build_token do
    raw = :crypto.strong_rand_bytes(@token_bytes)
    {Base.url_encode64(raw, padding: false), :crypto.hash(:sha256, raw)}
  end

  defp normalize_device_name(%{"name" => name} = attrs),
    do: Map.put(attrs, "device_name", name)

  defp normalize_device_name(%{name: name} = attrs),
    do: Map.put(attrs, :device_name, name)

  defp normalize_device_name(attrs), do: attrs

  defp tokens(access_token, refresh_token, changeset) do
    %{
      access_token: access_token,
      access_token_expires_at: get_field(changeset, :access_expires_at),
      refresh_token: refresh_token,
      refresh_token_expires_at: get_field(changeset, :refresh_expires_at)
    }
  end

  defp earlier(left, right) do
    if DateTime.compare(left, right) == :gt, do: right, else: left
  end
end
