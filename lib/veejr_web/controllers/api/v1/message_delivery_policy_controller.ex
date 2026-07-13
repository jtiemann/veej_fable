defmodule VeejrWeb.Api.V1.MessageDeliveryPolicyController do
  use VeejrWeb, :controller

  alias Veejr.Messaging
  alias VeejrWeb.Api.V1.Response

  def index(conn, _params) do
    policies =
      conn.assigns.current_scope.user
      |> Messaging.list_delivery_policies()
      |> Enum.map(&render_policy/1)

    json(conn, %{policies: policies})
  end

  def contact(conn, params), do: put_policy(conn, "contact", params)
  def group(conn, params), do: put_policy(conn, "group", params)
  def conversation(conn, params), do: put_policy(conn, "conversation", params)

  def delete_contact(conn, params), do: delete_policy(conn, "contact", params)
  def delete_group(conn, params), do: delete_policy(conn, "group", params)
  def delete_conversation(conn, params), do: delete_policy(conn, "conversation", params)

  defp put_policy(conn, subject_type, %{"subject_id" => subject_id} = params) do
    attrs = Map.take(params, ["acceptance", "notification"])

    case Messaging.put_delivery_policy(
           conn.assigns.current_scope.user,
           subject_type,
           subject_id,
           attrs
         ) do
      {:ok, policy} -> json(conn, %{policy: render_policy(policy)})
      {:error, :not_found} -> not_found(conn)
      {:error, %Ecto.Changeset{} = changeset} -> invalid_policy(conn, changeset)
    end
  end

  defp delete_policy(conn, subject_type, %{"subject_id" => subject_id}) do
    case Messaging.delete_delivery_policy(
           conn.assigns.current_scope.user,
           subject_type,
           subject_id
         ) do
      :ok -> send_resp(conn, :no_content, "")
      {:error, :not_found} -> not_found(conn)
    end
  end

  defp render_policy(policy) do
    %{
      subject_type: policy.subject_type,
      subject_id: to_string(policy.subject_id),
      acceptance: policy.acceptance,
      notification: policy.notification
    }
  end

  defp invalid_policy(conn, changeset) do
    details =
      Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)

    Response.error(
      conn,
      :unprocessable_entity,
      "invalid_policy",
      "The policy is not valid.",
      details
    )
  end

  defp not_found(conn) do
    Response.error(conn, :not_found, "not_found", "The policy subject was not found.")
  end
end
