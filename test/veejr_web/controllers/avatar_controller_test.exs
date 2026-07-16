defmodule VeejrWeb.AvatarControllerTest do
  use VeejrWeb.ConnCase

  import Veejr.AccountsFixtures

  alias Veejr.Accounts

  test "uploads and serves a normalized avatar", %{conn: conn} do
    user = user_fixture()

    upload_conn =
      conn
      |> log_in_user(user)
      |> put_req_header("content-type", "image/jpeg")
      |> post(~p"/account/avatar", jpeg(512, 512))

    assert %{"avatar_url" => avatar_url, "version" => 1} = json_response(upload_conn, 200)
    assert avatar_url == "/avatars/#{user.username}?v=1"

    response_conn = get(recycle(upload_conn), avatar_url)
    assert response(response_conn, 200) == jpeg(512, 512)
    assert get_resp_header(response_conn, "content-type") == ["image/jpeg; charset=utf-8"]
    assert get_resp_header(response_conn, "content-disposition") == ["inline"]
  end

  test "rejects images that were not normalized to 512 pixels", %{conn: conn} do
    user = user_fixture()

    conn =
      conn
      |> log_in_user(user)
      |> put_req_header("content-type", "image/jpeg")
      |> post(~p"/account/avatar", jpeg(640, 480))

    assert %{"error" => "Please choose a valid image."} = json_response(conn, 422)
    refute Accounts.get_user!(user.id).has_avatar
  end

  test "requires authentication to replace an avatar", %{conn: conn} do
    conn =
      conn
      |> put_req_header("content-type", "image/jpeg")
      |> post(~p"/account/avatar", jpeg(512, 512))

    assert redirected_to(conn) == ~p"/users/log-in"
  end

  defp jpeg(width, height) do
    component_data = :binary.copy(<<0>>, 12)

    <<
      0xFF,
      0xD8,
      0xFF,
      0xC0,
      0x00,
      0x11,
      0x08,
      height::16,
      width::16,
      component_data::binary,
      0xFF,
      0xD9
    >>
  end
end
