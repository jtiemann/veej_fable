# veejr architecture

## System goals

veejr is designed around three goals:

1. Encrypt shared content in the browser and keep server-side content storage
   opaque.
2. Make delivery consent-based: notification precedes ciphertext retrieval.
3. Keep self-hosting small: one BEAM application, one SQLite database, and one
   blob directory.

It does not hide traffic metadata, and its browser client is delivered by the
server it is meant to distrust for content. The consequences of that boundary
are described under [Security boundaries](#security-boundaries).

## Runtime structure

`Veejr.Application` starts a `:one_for_one` supervision tree:

```text
Veejr.Supervisor
├── VeejrWeb.Telemetry
├── Veejr.Repo (SQLite)
├── Ecto.Migrator (release and prod startup — boot-time migrations)
├── DNSCluster
├── Phoenix.PubSub (Veejr.PubSub)
├── Veejr.Federation.Outbox
├── Veejr.Push.Outbox
├── Veejr.Janitor
├── Veejr.TaskSupervisor
└── VeejrWeb.Endpoint (Bandit)
```

The main domain contexts are:

| Context | Responsibility |
| --- | --- |
| `Veejr.Accounts` | Registration, authentication, profiles, invites, and identity-key lifecycle. |
| `Veejr.Social` | Friendships, remote contacts, groups, and personal contact/group notes. |
| `Veejr.Messaging` | Envelopes, consent notifications, conversation windows, edits, expiry/display limits, and blobs. |
| `Veejr.Federation` | Remote discovery, friendship and delivery protocol, signed requests, peers, and retry outbox. |
| `Veejr.Push` | Push subscriptions and RFC 8291/8292 Web Push delivery. |
| `Veejr.Export` / `Veejr.Import` | Account portability. |

Phoenix LiveViews coordinate UI state and send only ciphertext-related data for
encrypted content. JavaScript hooks in `assets/js/veejr/` own key access,
encryption, decryption, attachment crypto, and map plaintext.

## Authentication and route boundaries

- The public browser route serves the landing page.
- Registration and login LiveViews use the optional-current-user session.
- Settings and key setup require authentication.
- Contacts, friends, groups, messages, map, and history require authentication
  plus configured identity keys; `VeejrWeb.LiveNotify` subscribes them to user
  notifications.
- Authenticated controller routes handle private blob upload/download, export,
  and push subscriptions.
- `/api/instance`, `/api/directory/:username`, envelope capability fetches, and
  blob capability fetches are public federation surfaces.
- Federation write endpoints pass through `VeejrWeb.FederationAuth`.

Authentication (email magic link and optional password) is independent of the
encryption passphrase.

## Browser cryptography

All content cryptography is implemented with TweetNaCl and WebCrypto in
`assets/js/veejr/crypto.js`.

### Identity key storage

On key setup the browser generates an X25519 keypair with
`nacl.box.keyPair()`. It derives a 256-bit wrapping key from the encryption
passphrase using PBKDF2-SHA256 with 310,000 iterations and a random 16-byte
salt. The X25519 secret key is wrapped using XSalsa20-Poly1305
(`nacl.secretbox`) with a random nonce.

The server stores `public_key`, `enc_secret_key`, `key_salt`, and `key_nonce`.
The unlocked secret key is cached in `sessionStorage`, scoped to the browser
tab session. A user can therefore roam with the wrapped key, but must supply
the passphrase on each new browser session.

### Envelope encryption

For N recipients, the browser creates N recipient envelopes plus a self-copy:

```text
payload  = {v, kind, text, attachments, sent_at, lat?, lng?, ...}
envelope = nacl.box(payload, nonce, recipient_public_key, sender_secret_key)
self     = nacl.box(payload, nonce, sender_public_key, sender_secret_key)
```

Each envelope has an unguessable `public_id`; copies share a `batch_id`.
`sender_public_key` snapshots the key used at send time. `resealed` marks an
envelope re-encrypted to its owner's current key during rotation.

Optional `expires_at` and `max_displays` constraints are stored as metadata and
enforced by server queries/fetches. They remove normal application access after
the limit; they cannot revoke plaintext or ciphertext a recipient already
copied. Sender edits replace every ciphertext copy in the owned batch after the
browser re-encrypts the revised payload for each recipient. Sender deletion
removes the owned envelope batch and its no-longer-referenced attachment bytes.

### Attachments

The browser encrypts each file once with a random `nacl.secretbox` key. The
opaque blob is uploaded separately; its `{blob_id, key, nonce, name, mime,
size}` descriptor is included inside every encrypted envelope payload.
The send request also carries only the opaque blob IDs outside the ciphertext.
The server validates that the sender owns them and records batch references in
the same transaction as the envelopes. Sender deletion removes a blob after
its final batch reference disappears; recipient hide does not. Uploads created
after reference tracking was introduced are reclaimed if still unattached
after 24 hours. Legacy blobs remain untracked and protected from automatic
deletion because their references cannot be recovered from ciphertext.

Authenticated blob routes serve local application users. `/api/blobs/:id` is
an unauthenticated capability endpoint used for federation: possession of the
128-bit unguessable identifier authorizes access to already-encrypted bytes.
Consequently, blob IDs must be treated as secrets even though the content also
has cryptographic protection.

## Consent and delivery

```text
sender browser -> encrypt -> sender instance stores envelope
                              |
                              +-> pending metadata notification
                                   -> PubSub / Web Push

recipient accepts -> ciphertext becomes fetchable -> browser decrypts
recipient declines -> ciphertext is not served to that recipient
```

Notifications contain metadata only and move from `pending` to `accepted` or
`declined`. `Veejr.Messaging.fetch_envelope/2` permits a sender to fetch their
self-copy and a recipient to fetch only after acceptance.

Acceptance opens a rolling five-minute `conversation_windows` entry for the
user/peer pair. Sends and accepted receives extend it. New messages from that
peer are auto-accepted while the window is active, avoiding a consent click for
every message in an active conversation.

## Federation

An instance is identified by its authority (`host` or `host:port`), and a user
by `username@authority`. Remote contacts are rows in `users` with `host` set;
they have no usable local credentials. Directory lookups synchronize public
display names and avatar metadata; avatar images remain hosted by the user's
home instance.

### API

| Method and path | Purpose |
| --- | --- |
| `GET /api/instance` | Instance identity and signing key discovery. |
| `GET /api/directory/:username` | Local-user public key, display name, and avatar discovery. |
| `POST /api/federation/friend_request` | Mirror a remote friend request. |
| `POST /api/federation/friend_response` | Accept or decline a request. |
| `POST /api/federation/notify` | Announce an available envelope without sending its ciphertext. |
| `POST /api/federation/key_update` | Announce a rotated user key for manual confirmation. |
| `GET /api/envelopes/:public_id` | Fetch envelope ciphertext by capability. |
| `GET /api/blobs/:id` | Fetch encrypted blob bytes by capability. |

### Pull flow across instances

When Alice on A sends to Carol on B, A retains the ciphertext and sends B a
content-free notify. B creates a stub envelope and pending notification. Only
after Carol accepts does B fetch `/api/envelopes/:public_id` from A and fill the
stub. Declining means the ciphertext never leaves A.

### Instance authentication and pinning

Each instance generates an Ed25519 signing keypair. Federation POST signatures
cover the request path, timestamp, and SHA-256 hash of the raw body. Requests
include authority, timestamp, and signature headers; timestamps have a
five-minute acceptance window.

Peer signing keys use trust on first use and are stored in `peers`. A later key
change is rejected. Handlers bind user-origin claims to the authenticated
instance authority. Remote user encryption keys are also pinned; a key update
is held in `pending_public_key` until a local user confirms it. Envelope fetch
URLs are constructed from the pinned sender authority rather than accepted
from payload input.

TOFU protects continuity after first contact but does not authenticate that
first contact against an external source such as DNSSEC or a transparency log.

### Reliability

Friend requests are synchronous so the initiator immediately learns whether an
address resolves. Envelope notifies, friend responses, key updates, and
account-move notices go through `Veejr.Federation.Outbox` enqueue-first: the
delivery row is written in the same database transaction as the local state it
announces (no network I/O inside the transaction, and a crash cannot lose the
announcement), then the outbox process is kicked after commit to attempt
delivery immediately. Failures are retried with exponential backoff (30
seconds to six hours) for roughly a week. Definitive 4xx responses are not
retried.

## Web Push

Each browser/device can register a Push API subscription. Push payloads are
encrypted with RFC 8291 `aes128gcm`; VAPID authentication uses RFC 8292 ES256
and a per-instance P-256 key. Gone subscriptions (HTTP 404/410) are pruned.
Payloads contain notification metadata such as sender handle and kind, not
message plaintext. Push services still observe endpoint and timing metadata.

## Key lifecycle

- **Passphrase change:** unwrap and rewrap the same secret key in the browser.
  The public key and existing envelopes do not change.
- **Rotation:** decrypt local history with the old key, generate a new keypair,
  reseal relevant envelopes, atomically replace stored key material, and send
  signed key-update announcements. Friends must manually confirm the new key.
- **Reset:** generate a new keypair and purge received envelopes that are no
  longer decryptable. Copies owned by other senders or recipients are not
  cryptographically revoked.

## Data model

| Table | Important fields / role |
| --- | --- |
| `users` | Local accounts and remote-contact stubs; profile, host, wrapped identity key, current/pending public keys. |
| `user_tokens` | Session, login, confirmation, and email-change tokens. |
| `friendships` | Canonical user pair and `pending`/`accepted` state. |
| `groups`, `group_members` | Owner-local organization of accepted friends. |
| `contact_notes`, `group_notes` | Owner-private but server-readable plaintext notes. |
| `envelopes` | Per-recipient ciphertext, nonce, sender-key snapshot, delivery/edit/expiry/display metadata, and a materialized per-viewer thread key so conversation lists and pages are index queries that load no ciphertext. |
| `conversation_archives` | Archived/preserved conversation instances; archiving stamps member envelopes with the instance key. |
| `notifications` | Per-envelope consent state. |
| `conversation_windows` | Rolling user/peer auto-accept expiry. |
| `blobs` | Opaque encrypted file location, owner, size, and public capability ID. |
| `instance_credentials` | Server-side Ed25519 federation and P-256 VAPID keypairs. |
| `peers` | TOFU-pinned remote instance signing keys. |
| `outbound_deliveries` | Retriable signed federation operations. |
| `push_subscriptions` | Per-device Push API endpoint and public subscription keys. |

SQLite foreign keys and ownership-scoped context queries enforce most local
relationships. Sending validates accepted friendship for every recipient
inside the database transaction.

## Account portability

`GET /export` builds an in-memory zip containing `export.json`, the user's
normalized profile image when present, and owned encrypted blobs. The manifest
includes profile and wrapped keys, friends, groups, and decryptable encrypted
history with sender-key snapshots. It exposes social metadata despite retaining
content encryption.

`mix veejr.import export.zip` creates the owner, restores their profile image,
accepted remote friendships, remote ghost contacts needed to identify
historical senders, envelopes with
original IDs/timestamps, and owned blobs. Received envelopes are imported as
accepted. During a managed move, source finalization verifies that the target
directory publishes the same user key, replaces local address-book references
with the new remote contact, and sends signed move notices to other federated
servers. Import does not include received attachments because the server cannot
discover blob IDs inside encrypted payloads. Contact/group notes and newer
envelope expiry/edit metadata are not currently part of export format version 1.

Account deletion removes owned blob files and the user row; foreign-key
cascades remove associated rows, including envelopes sent by that user.

## Security boundaries

The server can observe or control:

- account identifiers, friend graph, groups, contact/group notes, and login
  activity;
- sender/recipient relationships, item kinds, timestamps, expiry/display
  policy, attachment sizes, notification decisions, and delivery timing;
- ciphertext and capability identifiers;
- instance signing/VAPID private keys stored in SQLite;
- the JavaScript delivered to browsers.

The intended honest-server design keeps message text, decrypted attachments,
and coordinates out of LiveView payloads and persistent server storage.
Decrypted UI is written with `textContent` by client hooks.

A malicious or compromised server can alter the JavaScript client and capture
passphrases, keys, or plaintext. E2E encryption also cannot prevent recipients
from retaining content they have decrypted, and capability URLs may leak via
logs or clients. Operational security therefore depends on TLS, restricted
database/blob access, protected backups, prompt updates, and verification of
the deployed client build.
