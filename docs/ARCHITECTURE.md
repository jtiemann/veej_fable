# veejr architecture

## Goals

1. **Security & data ownership.** Content is end-to-end encrypted; the server
   is an untrusted ciphertext store. Personal instances keep all data local.
2. **Consent-based delivery.** No content moves to a recipient until they ask
   for it after being notified.
3. **Simple self-hosting.** One BEAM release + one SQLite file + one uploads
   directory.

## Cryptography

All primitives come from TweetNaCl in the browser
(`assets/js/veejr/crypto.js`). The server (Elixir) does no content crypto at
all.

### Identity keys

- On first login the browser generates an X25519 keypair (`nacl.box.keyPair`).
- The secret key is wrapped with XSalsa20-Poly1305 (`nacl.secretbox`) under a
  key derived from the user's **encryption passphrase** via PBKDF2-SHA256
  (310k iterations, WebCrypto).
- The server stores: `public_key`, `enc_secret_key`, `key_salt`, `key_nonce`.
  This gives roaming (log in elsewhere, unlock with the passphrase) without
  the server ever holding usable key material.
- The unlocked secret key is cached in `sessionStorage` only (dropped when the
  tab closes). "Lock this session" wipes it.
- The login password/magic-link and the encryption passphrase are deliberately
  independent: compromising the account (e.g. email takeover) does not reveal
  content.

### Envelopes

Sending anything (message / location / note) to N recipients produces N+1
envelopes, all created client-side:

```
payload  = {v, kind, text, attachments[], sent_at, lat?, lng?, ...}
envelope = nacl.box(payload, nonce, recipient_pub, sender_secret)   # per recipient
self_copy = nacl.box(payload, nonce, sender_pub, sender_secret)     # history
```

`box` is authenticated: recipients verify the ciphertext came from the sender.
Rows share a `batch_id` so the sender's history can display "To @a, @b".

### Attachments

Encrypted **once** per file with a random `nacl.secretbox` key, uploaded as an
opaque blob; the `{blob_id, key, nonce, name, mime, size}` descriptor rides
inside each envelope payload. Blob ids are 128-bit unguessable capabilities
and downloads require an authenticated session; content is ciphertext anyway.

## Pull-based delivery

```
sender's browser ── encrypts ──▶ envelopes ──▶ server stores ciphertext
                                              └─ notification (pending) ─▶ PubSub ─▶ recipient's
                                                                                     browser/OS notification
recipient clicks "Request it"  ──▶ notification: accepted
recipient's browser ◀── ciphertext served, decrypted locally, delivered_at set
(or "Decline": the ciphertext is never served to them)
```

The notification row carries only metadata the server already knows: sender,
kind, timestamp. States: `pending → accepted | declined`.

**Authorization for ciphertext:** the sender (their self-copies) or the
recipient *after* accepting. `Veejr.Messaging.fetch_envelope/2` +
the history query in `list_history/2` enforce this.

## Data model

```
users        id, email, username, display_name, hashed_password?,
             public_key, enc_secret_key, key_salt, key_nonce
friendships  requester_id, addressee_id, status(pending|accepted)   # one row per pair
groups       owner_id, name          # personal labels over your friends
group_members group_id, user_id      # friend can be in many groups
envelopes    public_id, batch_id, sender_id, recipient_id, kind(message|location|note),
             ciphertext, nonce, delivered_at
notifications envelope_id, user_id, state(pending|accepted|declined)
blobs        public_id, owner_id, size, path                        # encrypted at rest
```

Sending requires an accepted friendship for every recipient
(`Veejr.Messaging.send_batch/3` verifies inside the transaction).

## Client/server split

| Concern | Where |
|---|---|
| Key generation, wrap/unwrap, encrypt/decrypt | Browser (hooks in `assets/js/veejr/`) |
| Passphrases, plaintext, coordinates | Browser only — never in a LiveView form or socket |
| Recipient resolution (groups → users + public keys) | Server (`VeejrWeb.RecipientResolver`) |
| Friend graph, notification states, storage | Server |
| Live badge + browser notifications | Phoenix PubSub → `VeejrWeb.LiveNotify` → Notification API |

The composer is intentionally **not** a LiveView form: the `Composer` hook
reads inputs from the DOM, encrypts, and pushes only ciphertext. Decryption
happens in the `Decrypt` hook, which writes plaintext with `textContent`
(no HTML injection). The map (`VeejrMap` hook) decrypts location envelopes
locally and feeds outgoing coordinates to composers through
`window.veejrPayloadProviders`, bypassing the server entirely.

## What the server can still see (honest limits)

- Metadata: who is friends with whom, who sent what kind of item to whom, and
  when; attachment sizes.
- A malicious *server operator* could serve modified JavaScript. This is the
  classic web-E2E caveat; mitigations (subresource integrity, signed releases,
  native clients) are future work. Running your own personal instance is the
  strongest answer and is a first-class mode.

## Account portability (implemented)

Leaving an instance is a supported, tested flow:

- `GET /export` (Settings → "Export my account") builds a zip in memory:
  `export.json` (profile, wrapped keys, friends with public keys, groups,
  full decryptable envelope history with sender public keys inlined) plus
  `blobs/` with the user's own encrypted attachments. Everything sensitive is
  still ciphertext; the zip does reveal social metadata, so treat it as a
  private backup. Received attachments can't be included — the server doesn't
  know which blobs an envelope references (ids travel inside encrypted
  payloads, by design).
- `mix veejr.import export.zip` restores the account on a fresh (typically
  personal) instance: owner recreated and confirmed, envelopes with original
  ids/timestamps, received items pre-`accepted`, blobs rewritten to disk.
  Senders of received envelopes become **ghost contacts**: local user rows
  with only a username + public key, on a reserved `.invalid` email domain so
  they can never log in. Ghosts keep old ciphertext decryptable and are the
  seed of the remote-contact model federation will need.
- `Accounts.delete_user/1` (Settings → danger zone) purges blob files and
  lets FK cascades remove everything else — including envelopes the user
  *sent*. That is deliberate: the sender owns the data, and deletion
  withdraws it from recipients.

## Federation (implemented)

Instances are peers — the community server and a personal instance speak the
same protocol, and neither has a special role. An instance is identified by
its **authority** (`veejr.example.com`, `localhost:4001`), and people by
`username@authority`.

### Remote contacts

A remote person is an ordinary row in `users` with `host` set to their home
authority and their public key pinned. Because they are regular user rows,
friendships, groups, envelope addressing, and client-side encryption all work
on them **unchanged** — the composer encrypts to a remote friend exactly as
to a local one. Remote users can never log in (no credentials, `.invalid`
email) and local lookups (login, the public directory) explicitly exclude
them.

### Protocol

All under `/api` (JSON, unauthenticated — see trust model):

| Endpoint | Purpose |
|---|---|
| `GET /instance` | who this server is |
| `GET /directory/:username` | public-key discovery for local users |
| `POST /federation/friend_request` | `{from: {username, authority}, to}` |
| `POST /federation/friend_response` | accept/decline of a request we sent |
| `POST /federation/notify` | content-free announce: `{from, to, kind, public_id}` |
| `GET /envelopes/:public_id` | capability fetch of ciphertext |

**Friendship**: A creates a pending friendship + remote-user row, POSTs
`friend_request` to B (rolled back if unreachable). B mirrors it; when the
addressee accepts, B POSTs `friend_response` back and both sides converge on
`accepted`.

**Delivery** stays pull-based across instances, in the strongest sense:

```
alice@A sends to carol@B:
  A: envelope stored locally (ciphertext never leaves yet)
  A → B: POST notify {from, to, kind, public_id}          (content-free)
  B: stub envelope (empty ciphertext) + pending notification → live badge
  carol clicks "Request it":
  B → A: GET /api/envelopes/:public_id                    (capability URL)
  B: stub filled, carol's browser decrypts with alice's pinned key
  carol declines → the ciphertext never left A at all
```

Notifies to unreachable instances are reported to the sender ("could not be
notified — resend later"); the envelope stays safely at home. Duplicate
notifies are absorbed by the envelope `public_id` uniqueness.

### Trust model

- **Signed requests**: every instance has an Ed25519 signing keypair
  (generated on first use, published via `/api/instance`). Federation POSTs
  carry `x-veejr-authority` / `x-veejr-timestamp` / `x-veejr-signature`
  headers; the signature covers the path, the timestamp (±5 min window), and
  a SHA-256 of the raw body, so a signature can't be replayed onto a
  different endpoint or payload. `VeejrWeb.FederationAuth` verifies against
  the sender's **pinned instance key** (trust-on-first-use via the `peers`
  table); a peer later presenting a different key is rejected outright.
- **Origin binding**: handlers only accept payload origin claims that match
  the authority whose signature was verified — a signed request from B can
  never speak for users of C.
- **User-key pinning**: user public keys are still resolved from the claimed
  instance's directory and pinned; a changed key is a hard error
  (`key_changed`), never a silent swap.
- **Constructed URLs**: envelope fetches go to a URL built from the pinned
  sender host + public id — URLs in payloads are never followed (no SSRF).
- **Spam control**: `notify` requires an accepted friendship.
- Loopback authorities use http (dev); everything else https.

### Delivery reliability

Notifies and friend responses go through `Veejr.Federation.Outbox`: tried
immediately, and parked in `outbound_deliveries` if the peer is unreachable.
A supervised worker retries with exponential backoff (30s doubling, capped at
6h) for up to ~a week; definitive rejections (4xx) are dropped rather than
retried. The sender sees "queued, will be retried automatically", and the
envelope itself is never at risk — it lives on the sender's instance
regardless. Friend *requests* stay synchronous on purpose: the sender should
know immediately whether the address worked.

### Web Push

Closed-tab notifications via the Push API, implemented directly on OTP
`:crypto` (no extra dependencies):

- payload encryption per **RFC 8291** (`aes128gcm`), unit-tested byte-for-byte
  against the RFC's Appendix A test vector
- **VAPID** (RFC 8292) ES256 JWTs signed with a per-instance P-256 key
- per-device subscriptions (Settings → "Enable push on this device"),
  pruned automatically when the push service reports them gone (404/410)

Push payloads carry only what the in-app notification shows — sender handle
and kind — and are encrypted to the browser anyway, so the push relay
(Google/Mozilla/Apple) learns nothing.

### Multi-user instances

A personal instance can host more than one person: any existing user can
generate a signed **invite link** (Settings, 7-day expiry) that admits one
registration despite closed registration. A family server federating with
friends' servers and the community server is the intended shape.

## Notification transport roadmap

Today: Phoenix PubSub over the LiveView websocket + the browser Notification
API. Next: Web Push (VAPID) with a service worker so notifications arrive with
the tab closed — the payload stays content-free, matching the pull model.
