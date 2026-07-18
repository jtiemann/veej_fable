defmodule Veejr.UpdatesTest do
  use ExUnit.Case, async: false

  alias Veejr.Updates

  defp stub_release(tag, extra \\ %{}) do
    Req.Test.stub(Veejr.UpdatesStub, fn conn ->
      Req.Test.json(
        conn,
        Map.merge(
          %{
            "tag_name" => tag,
            "name" => "Release #{tag}",
            "body" => "notes for #{tag}",
            "html_url" => "https://github.com/veejr/veejr-server/releases/tag/#{tag}"
          },
          extra
        )
      )
    end)
  end

  test "parses the latest release and strips the tag prefix" do
    stub_release("v9.9.9")

    assert {:ok, release} = Updates.latest_release(force: true)
    assert release.tag == "v9.9.9"
    assert release.version == "9.9.9"
    assert release.name == "Release v9.9.9"
    assert release.notes == "notes for v9.9.9"
    assert %DateTime{} = release.checked_at
  end

  test "a newer release is reported as an available update" do
    stub_release("v9.9.9")
    assert Updates.update_available?(Updates.latest_release(force: true))
  end

  test "the running version and older releases are not updates" do
    stub_release("v" <> Updates.current_version())
    refute Updates.update_available?(Updates.latest_release(force: true))

    stub_release("v0.0.1")
    refute Updates.update_available?(Updates.latest_release(force: true))
  end

  test "unparseable tags are never offered as updates" do
    stub_release("nightly-build")
    refute Updates.update_available?(Updates.latest_release(force: true))
  end

  test "an upstream without releases is reported distinctly" do
    Req.Test.stub(Veejr.UpdatesStub, fn conn ->
      Plug.Conn.send_resp(conn, 404, "{}")
    end)

    assert {:error, :no_releases} = Updates.latest_release(force: true)
    refute Updates.update_available?({:error, :no_releases})
  end

  test "the current version comes from the compiled application" do
    assert Updates.current_version() == to_string(Application.spec(:veejr, :vsn))
  end
end
