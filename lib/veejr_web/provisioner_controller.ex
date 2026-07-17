defmodule VeejrWeb.ProvisionerController do
  use VeejrWeb, :controller

  alias Veejr.AccountMoves

  def claim(conn, _params) do
    case AccountMoves.claim() do
      {:ok, nil} -> send_resp(conn, 204, "")
      {:ok, job} -> json(conn, %{job: job})
      {:error, _reason} -> conn |> put_status(:conflict) |> json(%{error: "claim_conflict"})
    end
  end

  def package(conn, %{"public_id" => public_id}) do
    case AccountMoves.package_path(public_id) do
      {:ok, path} ->
        if File.regular?(path) do
          conn
          |> put_resp_header("cache-control", "no-store")
          |> send_download({:file, path}, filename: "veejr-account-move.zip")
        else
          conn |> put_status(:not_found) |> json(%{error: "package_not_found"})
        end

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})

      {:error, _reason} ->
        conn |> put_status(:conflict) |> json(%{error: "invalid_state"})
    end
  end

  def result(conn, %{"public_id" => public_id} = params) do
    case AccountMoves.record_result(public_id, params) do
      {:ok, move} ->
        json(conn, %{status: move.status})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})

      {:error, reason} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: to_string(reason)})
    end
  end
end
