defmodule Veejr.OutboxTest do
  use Veejr.DataCase, async: false

  alias Veejr.Federation.Outbox
  alias Veejr.Federation.Outbox.Delivery
  alias Veejr.Repo

  @authority "flaky.example"
  @payload %{"hello" => "world"}

  defp stub_down do
    Req.Test.stub(Veejr.FederationStub, fn conn ->
      Plug.Conn.send_resp(conn, 503, "down")
    end)
  end

  defp stub_up do
    Req.Test.stub(Veejr.FederationStub, fn conn ->
      Req.Test.json(conn, %{ok: true})
    end)
  end

  test "enqueue parks a delivery due immediately, without any network I/O" do
    # no stub installed: an HTTP attempt here would crash
    assert :ok = Outbox.enqueue(@authority, "/api/federation/notify", @payload)
    assert Outbox.pending_count() == 1

    [delivery] = Repo.all(Delivery)
    assert delivery.attempts == 0
    assert DateTime.compare(delivery.next_attempt_at, DateTime.utc_now()) != :gt
  end

  test "a due delivery is processed to success and removed" do
    stub_up()
    assert :ok = Outbox.enqueue(@authority, "/api/federation/notify", @payload)

    assert {1, 0} = Outbox.process_due()
    assert Outbox.pending_count() == 0
  end

  test "failed delivery is parked and later retried to success" do
    stub_down()
    assert :ok = Outbox.enqueue(@authority, "/api/federation/notify", @payload)

    assert {0, 1} = Outbox.process_due()
    assert Outbox.pending_count() == 1

    [delivery] = Repo.all(Delivery)
    assert delivery.attempts == 1
    assert delivery.last_error =~ "503"

    # not due yet — backoff pushed it into the future
    assert {0, 0} = Outbox.process_due()

    # the peer comes back; force the delivery due and process
    stub_up()

    delivery
    |> Ecto.Changeset.change(next_attempt_at: DateTime.utc_now(:second))
    |> Repo.update!()

    assert {1, 0} = Outbox.process_due()
    assert Outbox.pending_count() == 0
  end

  test "still-failing deliveries back off exponentially" do
    stub_down()
    Outbox.enqueue(@authority, "/api/federation/notify", @payload)
    assert {0, 1} = Outbox.process_due()

    [delivery] = Repo.all(Delivery)

    delivery
    |> Ecto.Changeset.change(next_attempt_at: DateTime.utc_now(:second))
    |> Repo.update!()

    assert {0, 1} = Outbox.process_due()

    [delivery] = Repo.all(Delivery)
    assert delivery.attempts == 2
    # backoff for attempt 2 is 60s: due strictly in the future
    assert DateTime.compare(delivery.next_attempt_at, DateTime.utc_now()) == :gt
  end

  test "a definitive rejection from the peer drops the delivery" do
    Outbox.enqueue(@authority, "/api/federation/notify", @payload)

    Req.Test.stub(Veejr.FederationStub, fn conn ->
      Plug.Conn.send_resp(conn, 403, "not friends")
    end)

    assert {0, 1} = Outbox.process_due()
    assert Outbox.pending_count() == 0
  end

  test "gives up after max attempts" do
    stub_down()
    Outbox.enqueue(@authority, "/api/federation/notify", @payload)

    [delivery] = Repo.all(Delivery)

    delivery
    |> Ecto.Changeset.change(attempts: 24, next_attempt_at: DateTime.utc_now(:second))
    |> Repo.update!()

    assert {0, 1} = Outbox.process_due()
    assert Outbox.pending_count() == 0
  end
end
