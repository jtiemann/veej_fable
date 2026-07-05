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

## Federation groundwork (implemented) and roadmap

Already in place:

- **Addressing**: `Veejr.Social.Address` parses `username` / `username@host`;
  the friends page accepts full addresses and refuses foreign hosts with a
  clear message until delivery exists.
- **Public instance API**: `GET /api/instance` (software, version, mode,
  host, registration_open) and `GET /api/directory/:username` (public-key
  discovery). These are the endpoints a sending instance will hit first.

The remaining design, enabled by envelopes having URL-safe `public_id`s:

1. Friend graph learns remote contacts (ghost contacts generalized: username,
   host, pinned public key).
2. A sender's instance stores the envelopes (data stays home) and POSTs a
   signed, content-free notification to the recipient's instance:
   `{from, kind, envelope_url}`.
3. The recipient accepts → their browser fetches the ciphertext **from the
   sender's instance** and decrypts locally. Declined? The data never left
   the sender's server — the strongest possible reading of "no data is sent
   unless the receiver has requested it".
4. Keys resolved via the already-live `/api/directory/:username`, pinned on
   first use.

## Notification transport roadmap

Today: Phoenix PubSub over the LiveView websocket + the browser Notification
API. Next: Web Push (VAPID) with a service worker so notifications arrive with
the tab closed — the payload stays content-free, matching the pull model.
