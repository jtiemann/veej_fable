# 🔐 veejr

Private sharing with the people you choose. veejr lets you send end-to-end
encrypted messages (with attachments), share your location, and pin notes to a
map — visible only to the friends and groups you pick. Built for security and
ownership of your data.

## What makes it different

- **Your keys, your data.** Encryption keys are generated in your browser.
  The server stores only your public key and ciphertext; your secret key is
  wrapped with a passphrase-derived key before it ever leaves your device.
- **Pull-based delivery.** Recipients are notified that something awaits and
  nothing is transferred until they explicitly request it.
- **Personal instances.** Run veejr on your own machine (`VEEJR_MODE=personal`)
  and all your account data lives locally in a single SQLite file. The
  community server exists for people who don't have their own instance yet.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full security model
and data flows.

## Stack

Elixir / Phoenix LiveView, SQLite (via `ecto_sqlite3`), TweetNaCl in the
browser (X25519 + XSalsa20-Poly1305), Leaflet + OpenStreetMap for maps,
Phoenix PubSub + the browser Notification API for real-time notifications.

## Running it

Requires Elixir 1.15+ / OTP 26+.

```sh
mix setup          # deps, database, assets
mix phx.server     # http://localhost:4000
```

In development, login links (magic links) land in the local mailbox at
[`/dev/mailbox`](http://localhost:4000/dev/mailbox).

### First steps

1. Register at `/users/register` (email + username), then follow the login
   link from the mailbox.
2. Create your encryption keys at `/keys` — pick a passphrase and write it
   down. Losing it means losing access to your encrypted history; that's the
   point.
3. Add friends by username on the **Friends** page; organize them into
   **Groups** (a friend can be in many groups).
4. Send encrypted messages (attachments welcome) from **Messages**, share your
   location or drop geo-notes from **Map**, and browse everything in
   **History**.

### Instance modes

| Mode | Behavior |
|------|----------|
| `community` (default) | Open registration; hosts accounts for people without their own instance. |
| `personal` | Registration closes after the first account; your data stays on your machine. |

In production set `VEEJR_MODE=personal` (and optionally `VEEJR_BLOB_DIR` for
attachment storage). In dev, change `instance_mode` in `config/config.exs`.

### Moving to your own instance

Data ownership is the point, so leaving the community server is a first-class
flow:

1. **Export** — Settings → "Export my account" downloads a zip: profile,
   wrapped key material, friends (with public keys), groups, your full
   still-encrypted history, and your uploaded attachments.
2. **Import** — on your fresh personal instance:
   `mix veejr.import veejr-you-export.zip`, then log in with your email and
   unlock with the same passphrase. Your history decrypts exactly as before;
   senders of old messages are restored as *ghost contacts* (public keys
   only) so everything stays readable.
3. **Delete** — Settings → danger zone removes your community-server account
   and withdraws every message you ever sent. Sender owns the data.

### Federation

Instances talk to each other — the community server is just another peer.
Add a friend as `carol@her-server.example`, and messages, locations, and
notes flow between instances with the same pull-based rule: the encrypted
envelope stays on the sender's server until the recipient explicitly
requests it. Declined messages never leave home at all.

A personal instance can host several people (family, a group): generate an
invite link from Settings to admit someone despite closed registration.

Try it locally with two instances:

```sh
mix phx.server                                        # instance A on :4000
PORT=4001 VEEJR_DB=veejr_dev2.db mix ecto.setup       # one-time DB for B
PORT=4001 VEEJR_DB=veejr_dev2.db mix phx.server       # instance B on :4001
```

Register on both, then friend `someone@localhost:4001` from instance A. See
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the protocol and trust
model.

## Security model in one paragraph

Every message, location share, and geo-note is encrypted in the sender's
browser once per recipient (NaCl `box`: X25519 + XSalsa20-Poly1305), plus a
self-copy so your own history stays readable. Attachments are encrypted once
with a random symmetric key that travels inside the envelopes. The server
authenticates users, stores ciphertext, enforces the friend graph, and relays
notifications — it can see who talks to whom and when (metadata), but never
what is said, nor where you are: coordinates only exist decrypted in the
browser.
